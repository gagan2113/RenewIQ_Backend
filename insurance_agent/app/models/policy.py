"""
Policy model — matches the `policies` table.
UUID primary key, full financial columns, product / branch / agent FKs.
"""

import uuid

from sqlalchemy import (
    Column, String, Date, Boolean, SmallInteger, Integer, Numeric,
    DateTime, Text, ForeignKey,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.sql import func

from app.database import Base


class Policy(Base):
    __tablename__ = "policies"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id = Column(UUID(as_uuid=True), ForeignKey("customers.id", ondelete="CASCADE"), nullable=False)
    product_id = Column(SmallInteger, ForeignKey("il_products.id"), nullable=False)
    branch_id = Column(Integer, ForeignKey("il_branches.id"), nullable=False)
    agent_id = Column(UUID(as_uuid=True))
    rm_id = Column(UUID(as_uuid=True))

    # IL policy identifiers
    il_policy_number = Column(String(30), nullable=False, unique=True, index=True)
    policy_prefix = Column(String(10), nullable=False)
    endorsement_number = Column(String(20))

    # Coverage period
    risk_start_date = Column(Date, nullable=False)
    risk_end_date = Column(Date, nullable=False)
    issue_date = Column(Date, nullable=False)
    # expiry_date is generated in Postgres; we read it via a column property
    expiry_date = Column(Date)

    # Financials
    sum_insured = Column(Numeric(14, 2), nullable=False)
    basic_premium = Column(Numeric(12, 2), nullable=False)
    net_premium = Column(Numeric(12, 2), nullable=False)
    gst_rate = Column(Numeric(5, 2), nullable=False, default=18.00)
    gst_amount = Column(Numeric(10, 2))  # generated column in PG
    total_premium = Column(Numeric(12, 2))  # generated column in PG

    # Payment
    payment_mode = Column(String(20))
    payment_frequency = Column(SmallInteger, default=1)

    # Status
    policy_status = Column(String(20), nullable=False, default="ACTIVE", index=True)
    is_first_policy = Column(Boolean, nullable=False, default=True)
    last_renewed_at = Column(DateTime(timezone=True))
    renewal_count = Column(SmallInteger, nullable=False, default=0)
    cancellation_reason = Column(Text)
    cancelled_at = Column(DateTime(timezone=True))

    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
