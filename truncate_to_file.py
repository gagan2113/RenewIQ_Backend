import sys
import os

repo_dir = os.path.dirname(os.path.abspath(__file__))
app_dir = os.path.join(repo_dir, "insurance_agent")

os.chdir(app_dir)
sys.path.insert(0, app_dir)

from app.config import settings
from sqlalchemy import create_engine, text

engine = create_engine(settings.DATABASE_URL)

with open(r"d:\RenewIQ_Backend\db_result.txt", "w") as f:
    f.write("Connecting...\n")
    try:
        with engine.begin() as conn:
            f.write("Truncating...\n")
            conn.execute(text("""
                TRUNCATE TABLE 
                    customers, policies, 
                    campaigns, reminders, 
                    whatsapp_logs, sms_logs, email_logs, call_logs,
                    payments, notification_logs,
                    il_health_details, il_motor_details, il_travel_details,
                    il_agents, il_relationship_managers, il_sales_managers, il_territory_managers,
                    il_branches, il_regions, il_zones
                RESTART IDENTITY CASCADE;
            """))
            f.write("Truncated.\n")
    except Exception as e:
        f.write(f"Err: {e}\n")
    
    with engine.connect() as conn:
        for table in ["customers", "policies"]:
            res = conn.execute(text(f"SELECT COUNT(*) FROM {table}")).scalar()
            f.write(f"{table}: {res}\n")

print("Done")
