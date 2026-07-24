from app.core.database import SessionLocal
from sqlalchemy import text
db = SessionLocal()
res = db.execute(text("SELECT trigger_name FROM information_schema.triggers WHERE event_object_table = 'detections';")).fetchall()
print('Triggers on detections:', res)
