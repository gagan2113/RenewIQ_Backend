"""
Customer model (policyholder) — matches the `customers` table.
UUID primary key, full ICICI Lombard customer fields.
"""

import uuid

from sqlalchemy import (
    Column, String, Date, Boolean, SmallInteger, DateTime, Text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.sql import func

from app.database import Base


class Customer(Base):
    __tablename__ = "customers"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    il_customer_id = Column(String(30), unique=True)
    first_name = Column(String(80), nullable=False)
    last_name = Column(String(80), nullable=False)
    date_of_birth = Column(Date)
    gender = Column(String(1))
    pan_number = Column(String(10))
    aadhaar_last4 = Column(String(4))
    email = Column(String(150), index=True)
    phone = Column(String(20), nullable=False, index=True)
    whatsapp_number = Column(String(20))
    alternate_phone = Column(String(20))
    address_line1 = Column(Text)
    address_line2 = Column(Text)
    city = Column(String(80))
    state = Column(String(80))
    pincode = Column(String(10))
    preferred_channel_id = Column(SmallInteger)
    preferred_language_id = Column(SmallInteger)
    customer_segment = Column(String(20))
    kyc_status = Column(String(20), nullable=False, default="PENDING")
    kyc_verified_at = Column(DateTime(timezone=True))
    is_nri = Column(Boolean, nullable=False, default=False)
    is_opted_out = Column(Boolean, nullable=False, default=False)
    opted_out_at = Column(DateTime(timezone=True))
    opted_out_channel_id = Column(SmallInteger)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    @property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}"
