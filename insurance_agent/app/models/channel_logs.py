"""
Channel-specific log models — WhatsApp, SMS, Email, Voice.
Maps to: whatsapp_logs, sms_logs, email_logs, voice_logs
"""

import uuid

from sqlalchemy import (
    Column, String, SmallInteger, Integer, Boolean, DateTime, Text,
    Numeric, ForeignKey,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.sql import func

from app.database import Base


class WhatsAppLog(Base):
    __tablename__ = "whatsapp_logs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    reminder_id = Column(UUID(as_uuid=True), ForeignKey("reminders.id", ondelete="CASCADE"), nullable=False)
    meta_message_id = Column(String(100), unique=True)
    wa_number = Column(String(20), nullable=False)
    template_name = Column(String(100))
    message_preview = Column(Text)
    sent_at = Column(DateTime(timezone=True))
    delivered_at = Column(DateTime(timezone=True))
    read_at = Column(DateTime(timezone=True))
    delivery_status = Column(String(20), nullable=False, default="SENT")
    button_clicked = Column(String(50))
    reply_received = Column(Boolean, nullable=False, default=False)
    reply_text = Column(Text)
    replied_at = Column(DateTime(timezone=True))
    error_code = Column(String(20))
    error_message = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class SMSLog(Base):
    __tablename__ = "sms_logs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    reminder_id = Column(UUID(as_uuid=True), ForeignKey("reminders.id", ondelete="CASCADE"), nullable=False)
    provider = Column(String(30), nullable=False)
    provider_msg_id = Column(String(100), unique=True)
    phone_number = Column(String(20), nullable=False, index=True)
    sender_id = Column(String(20))
    message_text = Column(Text, nullable=False)
    dlt_template_id = Column(String(50))
    sent_at = Column(DateTime(timezone=True))
    delivered_at = Column(DateTime(timezone=True))
    delivery_status = Column(String(20), nullable=False, default="SENT")
    is_opted_out = Column(Boolean, nullable=False, default=False)
    opted_out_at = Column(DateTime(timezone=True))
    cost_inr = Column(Numeric(6, 4))
    error_code = Column(String(20))
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class EmailLog(Base):
    __tablename__ = "email_logs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    reminder_id = Column(UUID(as_uuid=True), ForeignKey("reminders.id", ondelete="CASCADE"), nullable=False)
    provider = Column(String(30), nullable=False)
    provider_msg_id = Column(String(150), unique=True)
    to_email = Column(String(150), nullable=False)
    from_email = Column(String(150), nullable=False)
    subject = Column(String(250), nullable=False)
    template_name = Column(String(100))
    sent_at = Column(DateTime(timezone=True))
    opened_at = Column(DateTime(timezone=True))
    clicked_at = Column(DateTime(timezone=True))
    delivery_status = Column(String(20), nullable=False, default="SENT")
    bounce_type = Column(String(10))
    is_unsubscribed = Column(Boolean, nullable=False, default=False)
    unsubscribed_at = Column(DateTime(timezone=True))
    open_count = Column(SmallInteger, nullable=False, default=0)
    click_count = Column(SmallInteger, nullable=False, default=0)
    error_code = Column(String(20))
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class VoiceLog(Base):
    __tablename__ = "voice_logs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    reminder_id = Column(UUID(as_uuid=True), ForeignKey("reminders.id", ondelete="CASCADE"), nullable=False)
    phone_number = Column(String(20), nullable=False)
    trigger_endpoint = Column(Text)
    script_version = Column(String(30))
    initiated_at = Column(DateTime(timezone=True), nullable=False)
    answered_at = Column(DateTime(timezone=True))
    ended_at = Column(DateTime(timezone=True))
    duration_seconds = Column(Integer)
    call_outcome = Column(String(30), nullable=False, default="PENDING")
    ivr_key_pressed = Column(String(5))
    is_interested = Column(Boolean)
    callback_requested = Column(Boolean, nullable=False, default=False)
    callback_time = Column(DateTime(timezone=True))
    retry_number = Column(SmallInteger, nullable=False, default=1)
    error_reason = Column(String(100))
    recording_url = Column(Text)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
