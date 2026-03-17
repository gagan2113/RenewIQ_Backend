"""
GET/POST /policies/
CRUD router for Policy model (ICICI Lombard schema).
"""

import logging
from datetime import date
from typing import List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.api.responses import success_response
from app.database import get_db
from app.models.customer import Customer
from app.models.policy import Policy
from app.models.product import ILProduct

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/policies", tags=["Policies"])


# ── Pydantic schemas ────────────────────────────────────────────────

class PolicyCreate(BaseModel):
    customer_id: UUID
    product_id: int
    branch_id: int
    il_policy_number: str
    policy_prefix: str
    risk_start_date: date
    risk_end_date: date
    issue_date: Optional[date] = None
    sum_insured: float
    basic_premium: float
    net_premium: float
    payment_mode: Optional[str] = "ANNUAL"
    policy_status: str = "ACTIVE"


class PolicyUpdate(BaseModel):
    policy_status: Optional[str] = None
    risk_end_date: Optional[date] = None
    payment_mode: Optional[str] = None
    net_premium: Optional[float] = None
    sum_insured: Optional[float] = None


class PolicyOut(BaseModel):
    id: UUID
    customer_id: UUID
    product_id: int
    il_policy_number: str
    policy_prefix: str
    risk_start_date: date
    risk_end_date: date
    issue_date: Optional[date]
    expiry_date: Optional[date]
    sum_insured: float
    basic_premium: float
    net_premium: float
    gst_amount: Optional[float]
    total_premium: Optional[float]
    payment_mode: Optional[str]
    policy_status: str
    renewal_count: int
    is_first_policy: bool
    product_line: Optional[str] = None

    model_config = {"from_attributes": True}


# ── Routes ──────────────────────────────────────────────────────────

@router.post("/", status_code=201)
def create_policy(payload: PolicyCreate, db: Session = Depends(get_db)):
    customer = db.query(Customer).filter(Customer.id == payload.customer_id).first()
    if not customer:
        raise HTTPException(status_code=404, detail="Customer not found")

    product = db.query(ILProduct).filter(ILProduct.id == payload.product_id).first()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")

    policy = Policy(
        **payload.model_dump(),
        issue_date=payload.issue_date or date.today(),
    )
    db.add(policy)
    db.commit()
    db.refresh(policy)
    return success_response(data=_enrich(db, policy), message="Policy created")


@router.get("/")
def list_policies(
    status: Optional[str] = Query(default=None),
    customer_id: Optional[UUID] = Query(default=None),
    product_line: Optional[str] = Query(default=None),
    expiring_within_days: Optional[int] = Query(default=None),
    db: Session = Depends(get_db),
):
    q = db.query(Policy)
    if status:
        q = q.filter(Policy.policy_status == status)
    if customer_id:
        q = q.filter(Policy.customer_id == customer_id)
    if product_line:
        q = q.join(ILProduct, Policy.product_id == ILProduct.id).filter(ILProduct.product_line == product_line)
    if expiring_within_days is not None:
        from datetime import timedelta
        cutoff = date.today() + timedelta(days=expiring_within_days)
        q = q.filter(Policy.risk_end_date >= date.today(), Policy.risk_end_date <= cutoff)
    policies = q.order_by(Policy.risk_end_date.asc()).all()
    return success_response(data=[_enrich(db, p) for p in policies], message="Policies fetched")


@router.get("/{policy_id}")
def get_policy(policy_id: UUID, db: Session = Depends(get_db)):
    policy = db.query(Policy).filter(Policy.id == policy_id).first()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")
    return success_response(data=_enrich(db, policy), message="Policy fetched")


@router.put("/{policy_id}")
def update_policy(policy_id: UUID, payload: PolicyUpdate, db: Session = Depends(get_db)):
    policy = db.query(Policy).filter(Policy.id == policy_id).first()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")
    for field, value in payload.model_dump(exclude_none=True).items():
        setattr(policy, field, value)
    db.commit()
    db.refresh(policy)
    return success_response(data=_enrich(db, policy), message="Policy updated")


@router.put("/{policy_id}/mark-renewed")
def mark_renewed(policy_id: UUID, db: Session = Depends(get_db)):
    from datetime import datetime, timezone
    policy = db.query(Policy).filter(Policy.id == policy_id).first()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")
    policy.policy_status = "RENEWED"
    policy.last_renewed_at = datetime.now(timezone.utc)
    policy.renewal_count = (policy.renewal_count or 0) + 1
    db.commit()
    db.refresh(policy)
    return success_response(data=_enrich(db, policy), message="Policy marked as renewed")


@router.delete("/{policy_id}")
def delete_policy(policy_id: UUID, db: Session = Depends(get_db)):
    policy = db.query(Policy).filter(Policy.id == policy_id).first()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")
    policy.policy_status = "CANCELLED"
    db.commit()
    return success_response(data=None, message="Policy cancelled")


# ── Helpers ─────────────────────────────────────────────────────────

def _enrich(db: Session, policy: Policy) -> dict:
    """Add product_line from the il_products join."""
    product = db.query(ILProduct).filter(ILProduct.id == policy.product_id).first()
    d = {c.name: getattr(policy, c.name) for c in policy.__table__.columns}
    d["product_line"] = product.product_line if product else None
    return d
