import argparse
import logging
import sys
import requests

from sqlalchemy import select, update
from app.database import SessionLocal
from app.models.customer import Customer
from app.models.policy import Policy

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
logger = logging.getLogger(__name__)

BASE_URL = "http://localhost:8000"

def get_first_policy(db):
    policy = db.execute(select(Policy).limit(1)).scalar_one_or_none()
    return policy

def update_customer_contact(db, customer_id, phone, email):
    stmt = (
        update(Customer)
        .where(Customer.id == customer_id)
        .values(phone=phone, whatsapp_number=phone, email=email)
    )
    db.execute(stmt)
    db.commit()

def test_trigger(policy_id):
    url = f"{BASE_URL}/agent/trigger/{policy_id}"
    logger.info(f"Triggering policy {policy_id} on {url} ...")
    try:
        response = requests.post(url)
        response.raise_for_status()
        logger.info(f"Trigger Response [{response.status_code}]: {response.json()}")
    except requests.exceptions.HTTPError as e:
        logger.error(f"Trigger Failed [{e.response.status_code}]: {e.response.text}")
    except Exception as e:
        logger.error(f"Error communicating with backend: {e}")

def main():
    parser = argparse.ArgumentParser(description="Test Backend API with custom WhatsApp number and Email")
    parser.add_argument("--phone", required=True, help="WhatsApp or phone number (e.g. +919876543210)")
    parser.add_argument("--email", required=True, help="Email address")
    parser.add_argument("--policy-id", required=False, help="Specific Policy ID to test against")
    args = parser.parse_args()

    phone = args.phone
    email = args.email

    try:
        db = SessionLocal()
        
        # Determine the policy to use
        if args.policy_id:
            policy = db.query(Policy).filter(Policy.id == args.policy_id).first()
            if not policy:
                logger.error(f"Policy {args.policy_id} not found in DB.")
                sys.exit(1)
        else:
            policy = get_first_policy(db)
            if not policy:
                logger.error("No policies found in the database. Please seed the DB first.")
                sys.exit(1)

        customer_id = policy.customer_id
        
        # Update the customer locally
        logger.info(f"Updating customer {customer_id} with Phone: {phone}, Email: {email}")
        update_customer_contact(db, customer_id, phone, email)
        
        # Check backend readiness
        try:
            health = requests.get(f"{BASE_URL}/")
            health.raise_for_status()
        except requests.exceptions.RequestException as e:
            logger.error(f"Backend does not appear to be running at {BASE_URL}. Ensure you have 'fastapi dev app/main.py' running. Error: {e}")
            sys.exit(1)

        # Trigger the agent
        test_trigger(policy.id)

    finally:
        db.close()

if __name__ == "__main__":
    main()
