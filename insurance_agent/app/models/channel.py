"""
Channel lookup table — WHATSAPP, SMS, EMAIL, VOICE
Maps to: channels (from icici_lombard_schema.sql)
"""

from sqlalchemy import Column, SmallInteger, String, Boolean, Integer, DateTime
from sqlalchemy.sql import func

from app.database import Base


class Channel(Base):
    __tablename__ = "channels"

    id = Column(SmallInteger, primary_key=True, autoincrement=True)
    code = Column(String(20), nullable=False, unique=True)
    label = Column(String(50), nullable=False)
    is_active = Column(Boolean, nullable=False, default=True)
    default_wait_hrs = Column(SmallInteger, nullable=False, default=24)
    daily_limit = Column(Integer, nullable=False, default=10000)
    rate_limit_per_sec = Column(SmallInteger, nullable=False, default=100)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
