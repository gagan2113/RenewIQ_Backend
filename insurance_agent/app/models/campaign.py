"""
Campaign model — maps to the `campaigns` table.
"""

import uuid

from sqlalchemy import (
    Column, String, SmallInteger, Integer, Boolean, DateTime, Text, ForeignKey,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.sql import func

from app.database import Base


class Campaign(Base):
    __tablename__ = "campaigns"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String(150), nullable=False)
    description = Column(Text)
    product_line = Column(String(20))
    target_segment = Column(String(20))
    reminder_window = Column(String(10), nullable=False)
    branch_id = Column(Integer)
    zone_id = Column(SmallInteger)
    status = Column(String(20), nullable=False, default="DRAFT")
    scheduled_start = Column(DateTime(timezone=True))
    scheduled_end = Column(DateTime(timezone=True))
    created_by = Column(UUID(as_uuid=True))
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
