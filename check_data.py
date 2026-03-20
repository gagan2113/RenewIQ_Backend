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
    print("----- CUSTOMERS -----")
    res = conn.execute(text("SELECT id, first_name, last_name FROM customers LIMIT 20"))
    for row in res:
        print(row)
