"""
IL Product catalogue — HEALTH, MOTOR, TRAVEL, HOME, COMMERCIAL, LIFE
Maps to: il_products (from icici_lombard_schema.sql)
"""

from sqlalchemy import Column, SmallInteger, String, Boolean, Numeric, Date, DateTime
from sqlalchemy.sql import func

from app.database import Base


class ILProduct(Base):
    __tablename__ = "il_products"

    id = Column(SmallInteger, primary_key=True, autoincrement=True)
    product_code = Column(String(30), nullable=False, unique=True)
    product_name = Column(String(150), nullable=False)
    product_line = Column(String(20), nullable=False)
    policy_prefix = Column(String(10), nullable=False)
    sub_type = Column(String(50))
    min_tenure_days = Column(SmallInteger, nullable=False, default=365)
    max_tenure_days = Column(SmallInteger, nullable=False, default=365)
    gst_rate = Column(Numeric(5, 2), nullable=False, default=18.00)
    is_active = Column(Boolean, nullable=False, default=True)
    launch_date = Column(Date)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
