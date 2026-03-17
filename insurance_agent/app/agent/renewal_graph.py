"""
LangGraph-based Insurance Renewal Reminder Agent

Graph flow:
    check_renewal_status
        → END (if renewed)
        → decide_channel
            → generate_message
                → send_notification
                    → log_notification
                        → wait_for_response
                            → check_renewal_status (if response received)
                            → decide_channel (if no response, escalate channel)
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Literal, TypedDict

from langgraph.graph import END, START, StateGraph
from sqlalchemy.orm import Session

from app.config import settings
from app.llm import get_llm
from app.database import SessionLocal
from app.models.notification_log import Reminder
from app.models.policy import Policy
from app.tools.sms_tool import send_sms
from app.tools.whatsapp_tool import send_whatsapp
from app.tools.email_tool import send_email
from app.tools.call_tool import send_call

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# State definition
# ---------------------------------------------------------------------------

class RenewalState(TypedDict):
    customer_id: str
    policy_id: str
    customer_name: str
    policy_type: str          # e.g. "Motor Insurance", "Health Insurance"
    expiry_date: str
    renewal_link: str
    days_until_expiry: int
    current_channel: str          # sms | whatsapp | email | call
    notification_history: list[dict]
    is_renewed: bool
    last_sent_at: str
    next_scheduled_channel: str
    llm_message: str


# ---------------------------------------------------------------------------
# Channel escalation order & thresholds (days until expiry)
# ---------------------------------------------------------------------------

CHANNEL_ORDER: list[str] = ["sms", "whatsapp", "email", "call"]

CHANNEL_THRESHOLDS: dict[str, int] = {
    "sms": 30,       # first touch – any time before expiry
    "whatsapp": 7,   # escalate after 7 days
    "email": 14,     # escalate after 14 days (counted from initial contact)
    "call": 21,      # final escalation after 21 days
}


# ---------------------------------------------------------------------------
# Shared LLM instance
# ---------------------------------------------------------------------------

_llm = get_llm(temperature=0.7)


# ---------------------------------------------------------------------------
# Helper: get a DB session
# ---------------------------------------------------------------------------

def _get_db() -> Session:
    return SessionLocal()


# ---------------------------------------------------------------------------
# Node 1 – check_renewal_status
# ---------------------------------------------------------------------------

def check_renewal_status(state: RenewalState) -> RenewalState:
    """
    Query the DB for the current policy status.
    If the policy has already been renewed set is_renewed=True so the
    conditional edge can route to END.
    """
    db = _get_db()
    try:
        from uuid import UUID as _UUID
        pid = state["policy_id"]
        policy = db.query(Policy).filter(Policy.id == pid).first()
        if policy is None:
            logger.warning("Policy %s not found in DB.", pid)
            return {**state, "is_renewed": False}

        is_renewed = policy.policy_status == "RENEWED"
        logger.info(
            "Policy %s policy_status=%s is_renewed=%s",
            pid,
            policy.policy_status,
            is_renewed,
        )
        return {**state, "is_renewed": is_renewed}
    finally:
        db.close()


def _route_after_check(state: RenewalState) -> Literal["decide_channel", "__end__"]:
    """Conditional edge from check_renewal_status."""
    if state.get("is_renewed"):
        logger.info("Policy %s is renewed – ending graph.", state["policy_id"])
        return END
    return "decide_channel"


# ---------------------------------------------------------------------------
# Node 2 – decide_channel (LLM-assisted)
# ---------------------------------------------------------------------------

def decide_channel(state: RenewalState) -> RenewalState:
    """
    Use GPT-4o-mini to decide, given the notification history and
    days_until_expiry, which channel to use next.

    The LLM confirms or adjusts the rule-based escalation logic:
      Day 0–6   → sms
      Day 7–13  → whatsapp
      Day 14–20 → email
      Day 21+   → call
    """
    days = state["days_until_expiry"]
    history_json = json.dumps(state["notification_history"], indent=2, default=str)

    prompt = f"""You are an insurance renewal coordinator AI.

Policy expiry is in {days} days.
Notification history so far:
{history_json}

Channel escalation rules:
- Start with SMS
- Switch to WhatsApp if no renewal after 7+ days of attempts
- Switch to Email if no renewal after 14+ days
- Switch to Phone Call if no renewal after 21+ days

Based on the history and the days_until_expiry, decide the SINGLE best channel
to use for the NEXT notification attempt.
Reply with ONLY one of: sms, whatsapp, email, call (lowercase, no punctuation)."""

    response = _llm.invoke(prompt)
    raw = response.content.strip().lower()

    # Guard – make sure we received a valid channel
    chosen_channel = raw if raw in CHANNEL_ORDER else _rule_based_channel(days, state["notification_history"])

    logger.info("decide_channel: LLM chose '%s' (days_until_expiry=%s)", chosen_channel, days)
    return {
        **state,
        "current_channel": chosen_channel,
        "next_scheduled_channel": chosen_channel,
    }


def _rule_based_channel(days_until_expiry: int, history: list[dict]) -> str:
    """Fallback rule-based channel selection."""
    channels_used = {h.get("channel") for h in history}
    for channel in reversed(CHANNEL_ORDER):
        threshold = CHANNEL_THRESHOLDS[channel]
        if days_until_expiry <= threshold and channel not in channels_used:
            return channel
    # Default to repeating the last channel used or sms
    if history:
        return history[-1].get("channel", "sms")
    return "sms"


# ---------------------------------------------------------------------------
# Node 3 – generate_message  (delegates to message_generator chains)
# ---------------------------------------------------------------------------

def generate_message(state: RenewalState) -> RenewalState:
    """
    Generate a personalised, empathetic renewal reminder message for the
    chosen channel using the channel-specific LangChain chains in
    app.agent.message_generator.
    """
    from app.agent.message_generator import generate_message as _gen  # deferred to avoid cycles

    channel = state["current_channel"]
    previous_count = len(state.get("notification_history", []))

    # Derive policy_type — may not be in state yet; fall back gracefully
    policy_type = state.get("policy_type", "Insurance Policy")

    message = _gen(
        channel=channel,
        customer_name=state["customer_name"],
        policy_type=policy_type,
        expiry_date=state["expiry_date"],
        days_until_expiry=state["days_until_expiry"],
        renewal_link=state["renewal_link"],
        previous_channel_count=previous_count,
    )

    logger.info("generate_message: %d-char message for channel=%s (attempt=%d)", len(message), channel, previous_count)
    return {**state, "llm_message": message}


# ---------------------------------------------------------------------------
# Node 4 – send_notification  (uses real tool implementations)
# ---------------------------------------------------------------------------

def send_notification(state: RenewalState) -> RenewalState:
    """
    Dispatch a notification on the current_channel using the real
    LangChain tool implementations (Twilio SMS/WhatsApp, SendGrid, ElevenLabs).
    """
    channel = state["current_channel"]
    msg = state["llm_message"]
    link = state["renewal_link"]
    now_iso = datetime.now(timezone.utc).isoformat()

    # These fields may not be in state if not populated upstream;
    # use .get() with sensible defaults so the node is fault-tolerant.
    phone = state.get("phone_number", "")
    email_addr = state.get("email", "")
    name = state["customer_name"]
    expiry = state["expiry_date"]
    policy_num = state.get("policy_number", state["policy_id"])
    days = state["days_until_expiry"]

    try:
        if channel == "sms":
            result = send_sms.invoke({"to": phone, "message": msg, "renewal_link": link})

        elif channel == "whatsapp":
            result = send_whatsapp.invoke({"to": phone, "message": msg, "renewal_link": link})

        elif channel == "email":
            result = send_email.invoke({
                "to_email": email_addr,
                "customer_name": name,
                "message": msg,
                "renewal_link": link,
                "policy_number": policy_num,
                "days_until_expiry": days,
            })

        elif channel == "call":
            result = send_call.invoke({
                "to": phone,
                "customer_name": name,
                "expiry_date": expiry,
                "renewal_link": link,
            })

        else:
            logger.error("Unknown channel '%s' – skipping dispatch.", channel)
            return state

        dispatched = result.get("status") not in ("failed", None)
        if dispatched:
            logger.info("Notification dispatched via %s at %s | result=%s", channel, now_iso, result)
            return {**state, "last_sent_at": now_iso}
        else:
            logger.warning("Notification via %s returned failure: %s", channel, result)
            return state

    except Exception as exc:
        logger.error("send_notification raised an exception on channel %s: %s", channel, exc)
        return state


# ---------------------------------------------------------------------------
# Node 5 – log_notification
# ---------------------------------------------------------------------------

def log_notification(state: RenewalState) -> RenewalState:
    """Persist a Reminder record to the database."""
    db = _get_db()
    try:
        from app.models.channel import Channel
        ch = db.query(Channel).filter(Channel.code == state["current_channel"].upper()).first()
        ch_id = ch.id if ch else 1

        sent_at = datetime.fromisoformat(state["last_sent_at"]) if state.get("last_sent_at") else datetime.now(timezone.utc)
        days = state.get("days_until_expiry", 30)
        if days <= 3:
            window = "3DAY"
        elif days <= 7:
            window = "7DAY"
        elif days <= 15:
            window = "15DAY"
        else:
            window = "30DAY"

        reminder = Reminder(
            policy_id=state["policy_id"],
            customer_id=state["customer_id"],
            channel_id=ch_id,
            reminder_window=window,
            attempt_number=len(state.get("notification_history", [])) + 1,
            scheduled_at=sent_at,
            sent_at=sent_at,
            delivery_status="SENT",
        )
        db.add(reminder)
        db.commit()
        db.refresh(reminder)
        logger.info("Reminder saved (id=%s).", reminder.id)

        updated_history = list(state["notification_history"]) + [
            {
                "log_id": str(reminder.id),
                "channel": state["current_channel"],
                "sent_at": state.get("last_sent_at"),
                "status": "SENT",
            }
        ]
        return {**state, "notification_history": updated_history}
    except Exception as exc:
        db.rollback()
        logger.error("Failed to log notification: %s", exc)
        return state
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Node 6 – wait_for_response
# ---------------------------------------------------------------------------

# Response window per channel (hours) – how long to wait before escalating
RESPONSE_WINDOW_HOURS: dict[str, int] = {
    "sms": 24,
    "whatsapp": 24,
    "email": 48,
    "call": 72,
}


def wait_for_response(state: RenewalState) -> RenewalState:
    """
    Check whether a response has been received within the expected window.
    Inspects the latest Reminder record for delivery status.
    """
    db = _get_db()
    try:
        from app.models.channel import Channel
        ch = db.query(Channel).filter(Channel.code == state["current_channel"].upper()).first()

        q = db.query(Reminder).filter(Reminder.policy_id == state["policy_id"])
        if ch:
            q = q.filter(Reminder.channel_id == ch.id)
        latest_reminder = q.order_by(Reminder.scheduled_at.desc()).first()

        if latest_reminder and latest_reminder.delivery_status in ("READ", "CLICKED", "DELIVERED"):
            logger.info("Response received for policy %s – re-checking renewal status.", state["policy_id"])
            return {**state, "is_renewed": False}

        current_idx = CHANNEL_ORDER.index(state["current_channel"]) if state["current_channel"] in CHANNEL_ORDER else 0
        next_idx = min(current_idx + 1, len(CHANNEL_ORDER) - 1)
        next_channel = CHANNEL_ORDER[next_idx]

        logger.info(
            "No response for policy %s. Scheduling next channel: %s",
            state["policy_id"],
            next_channel,
        )
        return {**state, "next_scheduled_channel": next_channel}
    finally:
        db.close()


def _route_after_wait(state: RenewalState) -> Literal["check_renewal_status", "decide_channel"]:
    """
    Conditional edge from wait_for_response:
    - If a response was received  → check_renewal_status
    - If no response (escalate)   → decide_channel
    """
    history = state.get("notification_history", [])
    if history:
        latest = history[-1]
        if latest.get("status") in ("delivered", "read", "responded"):
            return "check_renewal_status"

    # No meaningful response – escalate channel
    return "decide_channel"


# ---------------------------------------------------------------------------
# Build & compile the StateGraph
# ---------------------------------------------------------------------------

def build_renewal_graph() -> StateGraph:
    graph = StateGraph(RenewalState)

    # Register nodes
    graph.add_node("check_renewal_status", check_renewal_status)
    graph.add_node("decide_channel", decide_channel)
    graph.add_node("generate_message", generate_message)
    graph.add_node("send_notification", send_notification)
    graph.add_node("log_notification", log_notification)
    graph.add_node("wait_for_response", wait_for_response)

    # Entry point
    graph.add_edge(START, "check_renewal_status")

    # Conditional edge: check_renewal_status → END or decide_channel
    graph.add_conditional_edges(
        "check_renewal_status",
        _route_after_check,
        {
            END: END,
            "decide_channel": "decide_channel",
        },
    )

    # Linear pipeline after decide_channel
    graph.add_edge("decide_channel", "generate_message")
    graph.add_edge("generate_message", "send_notification")
    graph.add_edge("send_notification", "log_notification")
    graph.add_edge("log_notification", "wait_for_response")

    # Conditional edge: wait_for_response → check_renewal_status or decide_channel
    graph.add_conditional_edges(
        "wait_for_response",
        _route_after_wait,
        {
            "check_renewal_status": "check_renewal_status",
            "decide_channel": "decide_channel",
        },
    )

    return graph


# Compiled agent – import this in your API routes or Celery tasks
renewal_agent = build_renewal_graph().compile()
