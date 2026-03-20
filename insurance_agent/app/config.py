from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import Optional


class Settings(BaseSettings):
    DATABASE_URL: str
    TWILIO_ACCOUNT_SID: str = ""
    TWILIO_AUTH_TOKEN: str = ""
    TWILIO_PHONE_NUMBER: str = ""
    SENDGRID_API_KEY: str = ""
    SENDGRID_FROM_EMAIL: str = "noreply@renewiq.app"
    SENDGRID_FROM_NAME: str = "RenewIQ"
    SENDGRID_TEMPLATE_ID: str = ""
    SENDGRID_DATA_RESIDENCY: str = ""
    ELEVENLABS_API_KEY: str = ""
    SENDGRID_WEBHOOK_SIGNING_KEY: str = ""
    CORS_ALLOWED_ORIGINS: str = "http://localhost:3000,http://localhost:8000"
    LOG_DIR: str = "logs"
    MEDIA_BASE_URL: str = "https://media.renewiq.app/calls"

    # Azure OpenAI (primary)
    AZURE_OPENAI_API_KEY: str = ""
    AZURE_OPENAI_ENDPOINT: str = ""
    AZURE_OPENAI_API_VERSION: str = "2024-12-01-preview"
    AZURE_OPENAI_DEPLOYMENT_NAME: str = "gpt-4o"

    # Standard OpenAI (optional fallback)
    OPENAI_API_KEY: Optional[str] = None

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    @property
    def is_azure(self) -> bool:
        return bool(self.AZURE_OPENAI_API_KEY and self.AZURE_OPENAI_ENDPOINT)


settings = Settings()
