import os
import sys

# Add current path
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))

from app.config import settings
from sqlalchemy import create_engine, text

# Using autocommit to avoid table locks deadlocks
engine = create_engine(settings.DATABASE_URL, pool_pre_ping=True)

try:
    with engine.connect().execution_options(isolation_level='AUTOCOMMIT') as conn:
        print("Dropping schema public...")
        conn.execute(text("DROP SCHEMA IF EXISTS public CASCADE;"))
        print("Recreating schema public...")
        conn.execute(text("CREATE SCHEMA public;"))
        conn.execute(text("GRANT ALL ON SCHEMA public TO public;"))
        print("Database wiped successfully!")
except Exception as e:
    print(f"Error: {e}")
