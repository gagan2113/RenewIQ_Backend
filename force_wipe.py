import sys
import os

repo_dir = os.path.dirname(os.path.abspath(__file__))
app_dir = os.path.join(repo_dir, "insurance_agent")
os.chdir(app_dir)
sys.path.insert(0, app_dir)

from app.config import settings
from sqlalchemy import create_engine, text

engine = create_engine(settings.DATABASE_URL, connect_args={"connect_timeout": 15})

print("Starting delete process...")
with open(r"d:\RenewIQ_Backend\db_result.txt", "w") as f:
    f.write("Connecting...\n")
    f.flush()
    try:
        with engine.begin() as conn:
            f.write("Deleting...\n")
            f.flush()
            # Delete policies first, then customers to respect foreign keys
            conn.execute(text("DELETE FROM il_health_details"))
            conn.execute(text("DELETE FROM il_motor_details"))
            conn.execute(text("DELETE FROM il_travel_details"))
            conn.execute(text("DELETE FROM reminders"))
            conn.execute(text("DELETE FROM campaigns"))
            conn.execute(text("DELETE FROM payments"))
            conn.execute(text("DELETE FROM policies"))
            conn.execute(text("DELETE FROM customers"))
            f.write("Deleted.\n")
            f.flush()
    except Exception as e:
        f.write(f"Err: {e}\n")
        f.flush()

print("Done")
