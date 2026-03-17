from app.api.policies import router as policies_router
from app.api.customers import router as customers_router
from app.api.notifications import router as notifications_router
from app.api.agent import router as agent_router

__all__ = ["policies_router", "customers_router", "notifications_router", "agent_router"]
