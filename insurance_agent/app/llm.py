"""
LLM factory — returns the correct ChatOpenAI / AzureChatOpenAI instance
depending on which credentials are configured in .env.
"""

from app.config import settings


def get_llm(temperature: float = 0.7, model: str = "gpt-4o-mini"):
    """
    Returns a LangChain chat model instance.
    - If Azure OpenAI credentials are set → AzureChatOpenAI
    - Else falls back to standard ChatOpenAI with OPENAI_API_KEY
    """
    if settings.is_azure:
        from langchain_openai import AzureChatOpenAI
        return AzureChatOpenAI(
            azure_deployment=settings.AZURE_OPENAI_DEPLOYMENT_NAME,
            azure_endpoint=settings.AZURE_OPENAI_ENDPOINT,
            api_key=settings.AZURE_OPENAI_API_KEY,
            api_version=settings.AZURE_OPENAI_API_VERSION,
            temperature=temperature,
        )
    else:
        from langchain_openai import ChatOpenAI
        return ChatOpenAI(
            model=model,
            temperature=temperature,
            api_key=settings.OPENAI_API_KEY,
        )
