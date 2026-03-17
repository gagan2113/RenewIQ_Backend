from app.webhooks.sms_webhook import router as sms_router
from app.webhooks.whatsapp_webhook import router as whatsapp_router
from app.webhooks.email_webhook import router as email_router
from app.webhooks.call_webhook import router as call_router

__all__ = ["sms_router", "whatsapp_router", "email_router", "call_router"]
