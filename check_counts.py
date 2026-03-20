import sys
import os

repo_dir = os.path.dirname(os.path.abspath(__file__))
app_dir = os.path.join(repo_dir, "insurance_agent")

os.chdir(app_dir)
sys.path.insert(0, app_dir)

from app.config import settings
from sqlalchemy import create_engine, text

engine = create_engine(settings.DATABASE_URL)
with engine.connect() as conn:
    print("----- DATABASE COUNTS -----")
    for table in ["customers", "policies"]:
        try:
            res = conn.execute(text(f"SELECT COUNT(*) FROM {table}")).scalar()
            print(f"{table}: {res}")
        except Exception as e:
            print(f"{table}: ERROR {e}")
    print("---------------------------")
