"""
Reminder model — maps to the `reminders` table (master outreach log).
Replaces the old NotificationLog model.
"""

import uuid

from sqlalchemy import (
    Column, String, SmallInteger, Integer, Boolean, DateTime, Text, ForeignKey,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.sql import func

from app.database import Base


class Reminder(Base):
    __tablename__ = "reminders"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    campaign_id = Column(UUID(as_uuid=True), ForeignKey("campaigns.id"))
    policy_id = Column(UUID(as_uuid=True), ForeignKey("policies.id", ondelete="CASCADE"), nullable=False)
    customer_id = Column(UUID(as_uuid=True), ForeignKey("customers.id", ondelete="CASCADE"), nullable=False)
    token_id = Column(UUID(as_uuid=True))
    channel_id = Column(SmallInteger, ForeignKey("channels.id"), nullable=False)
    template_id = Column(Integer)
    reminder_window = Column(String(10), nullable=False)  # 30DAY, 15DAY, 7DAY, 3DAY
    attempt_number = Column(SmallInteger, nullable=False, default=1)
    is_fallback = Column(Boolean, nullable=False, default=False)
    parent_reminder_id = Column(UUID(as_uuid=True))
    scheduled_at = Column(DateTime(timezone=True), nullable=False)
    sent_at = Column(DateTime(timezone=True))
    delivery_status = Column(String(20), nullable=False, default="PENDING", index=True)
    link_clicked = Column(Boolean, nullable=False, default=False)
    clicked_at = Column(DateTime(timezone=True))
    renewed_after_click = Column(Boolean, nullable=False, default=False)
    fallback_triggered = Column(Boolean, nullable=False, default=False)
    fallback_reminder_id = Column(UUID(as_uuid=True))
    agent_notes = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)


# Keep a backward-compatible alias so existing imports don't break immediately
NotificationLog = Reminder
