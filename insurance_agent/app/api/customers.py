"""
GET/POST /customers/
CRUD router for Customer model (ICICI Lombard schema).
"""

import logging
from typing import List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, EmailStr
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.customer import Customer
from app.api.responses import success_response

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/customers", tags=["Customers"])


# ── Pydantic schemas ────────────────────────────────────────────────

class CustomerCreate(BaseModel):
    first_name: str
    last_name: str
    email: Optional[EmailStr] = None
    phone: str
    whatsapp_number: Optional[str] = None
    city: Optional[str] = None
    state: Optional[str] = None
    pincode: Optional[str] = None
    customer_segment: Optional[str] = "STANDARD"
    preferred_language_id: Optional[int] = None


class CustomerUpdate(BaseModel):
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    email: Optional[EmailStr] = None
    phone: Optional[str] = None
    whatsapp_number: Optional[str] = None
    city: Optional[str] = None
    state: Optional[str] = None
    pincode: Optional[str] = None
    customer_segment: Optional[str] = None
    is_opted_out: Optional[bool] = None


class CustomerOut(BaseModel):
    id: UUID
    il_customer_id: Optional[str]
    first_name: str
    last_name: str
    full_name: str
    email: Optional[str]
    phone: str
    whatsapp_number: Optional[str]
    city: Optional[str]
    state: Optional[str]
    pincode: Optional[str]
    customer_segment: Optional[str]
    kyc_status: str
    is_opted_out: bool

    model_config = {"from_attributes": True}


# ── Routes ──────────────────────────────────────────────────────────

@router.post("/", status_code=201)
def create_customer(payload: CustomerCreate, db: Session = Depends(get_db)):
    existing = db.query(Customer).filter(Customer.phone == payload.phone).first()
    if existing:
        raise HTTPException(status_code=409, detail="A customer with this phone already exists.")
    customer = Customer(**payload.model_dump())
    db.add(customer)
    db.commit()
    db.refresh(customer)
    return success_response(data=CustomerOut.model_validate(customer).model_dump(), message="Customer created")


@router.get("/")
def list_customers(
    skip: int = 0,
    limit: int = 100,
    segment: Optional[str] = Query(default=None),
    city: Optional[str] = Query(default=None),
    db: Session = Depends(get_db),
):
    q = db.query(Customer).filter(Customer.is_opted_out == False)
    if segment:
        q = q.filter(Customer.customer_segment == segment)
    if city:
        q = q.filter(Customer.city == city)
    customers = q.offset(skip).limit(limit).all()
    return success_response(
        data=[CustomerOut.model_validate(c).model_dump() for c in customers],
        message="Customers fetched",
    )


@router.get("/{customer_id}")
def get_customer(customer_id: UUID, db: Session = Depends(get_db)):
    customer = db.query(Customer).filter(Customer.id == customer_id).first()
    if not customer:
        raise HTTPException(status_code=404, detail="Customer not found")
    return success_response(data=CustomerOut.model_validate(customer).model_dump(), message="Customer fetched")


@router.put("/{customer_id}")
def update_customer(customer_id: UUID, payload: CustomerUpdate, db: Session = Depends(get_db)):
    customer = db.query(Customer).filter(Customer.id == customer_id).first()
    if not customer:
        raise HTTPException(status_code=404, detail="Customer not found")

    updates = payload.model_dump(exclude_none=True)
    if "phone" in updates and updates["phone"] != customer.phone:
        duplicate = db.query(Customer).filter(Customer.phone == updates["phone"]).first()
        if duplicate:
            raise HTTPException(status_code=409, detail="A customer with this phone already exists.")

    for field, value in updates.items():
        setattr(customer, field, value)
    db.commit()
    db.refresh(customer)
    return success_response(data=CustomerOut.model_validate(customer).model_dump(), message="Customer updated")


@router.delete("/{customer_id}")
def delete_customer(customer_id: UUID, db: Session = Depends(get_db)):
    customer = db.query(Customer).filter(Customer.id == customer_id).first()
    if not customer:
        raise HTTPException(status_code=404, detail="Customer not found")
    db.delete(customer)
    db.commit()
    return success_response(data=None, message="Customer deleted")
