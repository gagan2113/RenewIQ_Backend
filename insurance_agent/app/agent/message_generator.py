"""
Personalized message generator for each notification channel.

Uses LangChain ChatOpenAI (gpt-4o-mini) with channel-specific PromptTemplates.
Each chain returns a plain string message ready to hand to the sender tools.

Usage:
    from app.agent.message_generator import generate_message

    msg = generate_message(
        channel="sms",
        customer_name="Ravi Kumar",
        policy_type="Motor Insurance",
        expiry_date="2026-04-01",
        days_until_expiry=18,
        renewal_link="https://renewiq.app/renew/42",
        previous_channel_count=0,
    )
"""

from __future__ import annotations

import logging
from typing import Literal

from langchain_core.output_parsers import StrOutputParser
from langchain_core.prompts import ChatPromptTemplate, SystemMessagePromptTemplate, HumanMessagePromptTemplate

from app.llm import get_llm

logger = logging.getLogger(__name__)

Channel = Literal["sms", "whatsapp", "email", "call"]

# ---------------------------------------------------------------------------
# Shared LLM
# ---------------------------------------------------------------------------

_llm = get_llm(temperature=0.7)

_parser = StrOutputParser()

# ---------------------------------------------------------------------------
# System prompt (shared across all channels)
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = (
    "You are a helpful, warm, non-pushy AI assistant for an insurance company. "
    "Your job is to remind customers to renew their insurance before it expires. "
    "Always be empathetic, clear, and concise. Never be aggressive or spam-like."
)

# ---------------------------------------------------------------------------
# Channel-specific PromptTemplates
# ---------------------------------------------------------------------------

_SMS_HUMAN = """\
Write a single SMS reminder (STRICT maximum 160 characters including spaces and the link).
Use 1–2 friendly emojis. Be urgent but warm.

Customer name: {customer_name}
Policy type: {policy_type}
Expiry date: {expiry_date}
Days until expiry: {days_until_expiry}
Renewal link: {renewal_link}
Times already contacted: {previous_channel_count}

Rules:
- MUST be ≤ 160 characters total (count every character)
- Include the renewal_link verbatim
- Urgency should increase if previous_channel_count > 0
- Output ONLY the SMS text, nothing else"""

_WHATSAPP_HUMAN = """\
Write a WhatsApp renewal reminder (max 300 characters).
You can use *bold* for important words and line breaks for readability.
Keep it conversational, like a helpful friend texting the customer.

Customer name: {customer_name}
Policy type: {policy_type}
Expiry date: {expiry_date}
Days until expiry: {days_until_expiry}
Renewal link: {renewal_link}
Times already contacted: {previous_channel_count}

Rules:
- Max 300 characters
- Use *bold* sparingly (policy type, expiry date)
- Include the renewal link on its own line
- Escalate urgency gently if previous_channel_count > 1
- Output ONLY the WhatsApp message text"""

_EMAIL_HUMAN = """\
Write a renewal reminder email.

Return your response in EXACTLY this format (no extra text outside it):

SUBJECT: <subject line here>
BODY_HTML: <full HTML body here>

Requirements for the subject line:
- Max 60 characters
- Urgency increases with days_until_expiry (≤3 → "URGENT: ", ≤7 → "Important: ")

Requirements for the HTML body:
- Professional layout with a white card on a light-grey background
- Header gradient: #1a73e8 → #0d47a1
- Customer greeting using customer_name
- One-paragraph summary mentioning policy_type and expiry_date
- A styled CTA button (background #1a73e8, white text "Renew Now →") linking to renewal_link
- Footer: "© 2026 RenewIQ. All rights reserved."
- Use inline CSS only (no <style> blocks)
- Escalate the urgency language if previous_channel_count > 1

Customer name: {customer_name}
Policy type: {policy_type}
Expiry date: {expiry_date}
Days until expiry: {days_until_expiry}
Renewal link: {renewal_link}
Times already contacted: {previous_channel_count}"""

_CALL_HUMAN = """\
Write a spoken phone call script for an insurance renewal reminder.
It must read naturally when spoken aloud and take 30–45 seconds at a normal pace.

Customer name: {customer_name}
Policy type: {policy_type}
Expiry date: {expiry_date}
Days until expiry: {days_until_expiry}
Times already contacted: {previous_channel_count}

Rules:
- Warm, natural greeting (e.g. "Hello {customer_name}, this is a friendly reminder from RenewIQ…")
- Mention the policy type and exact expiry date clearly
- End with: "We'll send you a renewal link by SMS right after this call — it takes just two minutes to renew online."
- If previous_channel_count > 0, acknowledge this is a follow-up call
- Do NOT include stage directions, speaker labels, or brackets
- Output ONLY the spoken words"""

# ---------------------------------------------------------------------------
# Build chains
# ---------------------------------------------------------------------------

def _build_chain(human_template: str):
    prompt = ChatPromptTemplate.from_messages([
        SystemMessagePromptTemplate.from_template(SYSTEM_PROMPT),
        HumanMessagePromptTemplate.from_template(human_template),
    ])
    return prompt | _llm | _parser


_CHAINS: dict[Channel, object] = {
    "sms":       _build_chain(_SMS_HUMAN),
    "whatsapp":  _build_chain(_WHATSAPP_HUMAN),
    "email":     _build_chain(_EMAIL_HUMAN),
    "call":      _build_chain(_CALL_HUMAN),
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_message(
    channel: Channel,
    customer_name: str,
    policy_type: str,
    expiry_date: str,
    days_until_expiry: int,
    renewal_link: str,
    previous_channel_count: int = 0,
) -> str:
    """
    Generate a personalized renewal reminder message for the given channel.

    Returns the raw LLM output string:
    - SMS / WhatsApp / Call → ready-to-send text
    - Email → "SUBJECT: ...\nBODY_HTML: ..." (parse with parse_email_output())
    """
    chain = _CHAINS.get(channel)
    if chain is None:
        raise ValueError(f"Unknown channel: {channel!r}. Must be one of {list(_CHAINS)}")

    inputs = {
        "customer_name": customer_name,
        "policy_type": policy_type,
        "expiry_date": expiry_date,
        "days_until_expiry": days_until_expiry,
        "renewal_link": renewal_link,
        "previous_channel_count": previous_channel_count,
    }

    logger.info(
        "Generating %s message for customer=%s (days_left=%d, attempt=%d)",
        channel, customer_name, days_until_expiry, previous_channel_count,
    )
    result: str = chain.invoke(inputs)  # type: ignore[union-attr]
    logger.debug("Generated %s message (%d chars).", channel, len(result))
    return result


def parse_email_output(raw: str) -> tuple[str, str]:
    """
    Parse the email chain output into (subject, html_body).
    Returns ("", raw) if the expected format is not present.
    """
    subject = ""
    body_html = raw

    for line in raw.splitlines():
        if line.startswith("SUBJECT:"):
            subject = line.removeprefix("SUBJECT:").strip()
        elif line.startswith("BODY_HTML:"):
            body_html = line.removeprefix("BODY_HTML:").strip()
            # Everything after BODY_HTML: including newlines
            idx = raw.find("BODY_HTML:")
            if idx != -1:
                body_html = raw[idx + len("BODY_HTML:"):].strip()
            break

    return subject, body_html
