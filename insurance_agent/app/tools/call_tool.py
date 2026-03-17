"""
Voice call tool — ElevenLabs TTS + Twilio Programmable Voice
LangChain @tool + standalone callable, with tenacity retries.

Flow:
  1. GPT-4o-mini generates a conversational call script
  2. ElevenLabs converts the script to an MP3 (returned as bytes)
  3. MP3 is uploaded to a temporary URL accessible by Twilio
     (in production, store in S3/GCS; here we save to a local temp file
      and serve via a pre-configured media endpoint)
  4. Twilio makes the call and plays the MP3 via TwiML
"""

import logging
import os
import tempfile
import uuid
from typing import Annotated

import requests
from langchain_core.tools import tool
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
    before_sleep_log,
)
from twilio.base.exceptions import TwilioRestException
from twilio.rest import Client
from twilio.twiml.voice_response import VoiceResponse, Play

from app.config import settings
from app.llm import get_llm

logger = logging.getLogger(__name__)

_llm = get_llm(temperature=0.5)

ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
DEFAULT_VOICE_ID = "21m00Tcm4TlvDq8ikWAM"  # ElevenLabs "Rachel" – replace as needed

# ---------------------------------------------------------------------------
# Step 1 – Generate call script via GPT-4o-mini
# ---------------------------------------------------------------------------

def _generate_call_script(customer_name: str, expiry_date: str, renewal_link: str) -> str:
    # Build a spoken-friendly version of the URL
    spoken_link = (
        renewal_link
        .replace("https://", "")
        .replace("http://", "")
        .replace("/", " slash ")
        .replace("-", " dash ")
        .replace("_", " underscore ")
    )

    prompt = (
        f"Write a warm, professional insurance renewal reminder phone call script.\n"
        f"Customer name: {customer_name}\n"
        f"Policy expiry date: {expiry_date}\n"
        f"Renewal link (spoken form): {spoken_link}\n\n"
        f"Requirements:\n"
        f"- The script should take under 45 seconds to read aloud at a natural pace.\n"
        f"- Start with a friendly greeting, mention the expiry date clearly, "
        f"and guide the customer to renew online.\n"
        f"- End with a polite sign-off.\n"
        f"- Do NOT include stage directions, speaker labels, or brackets.\n"
        f"- Output only the spoken words."
    )
    response = _llm.invoke(prompt)
    return response.content.strip()


# ---------------------------------------------------------------------------
# Step 2 – ElevenLabs TTS → MP3 bytes (with retries)
# ---------------------------------------------------------------------------

@retry(
    retry=retry_if_exception_type(Exception),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=30),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _elevenlabs_tts(script: str, voice_id: str = DEFAULT_VOICE_ID) -> bytes:
    url = ELEVENLABS_TTS_URL.format(voice_id=voice_id)
    headers = {
        "xi-api-key": settings.ELEVENLABS_API_KEY,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
    }
    payload = {
        "text": script,
        "model_id": "eleven_monolingual_v1",
        "voice_settings": {"stability": 0.5, "similarity_boost": 0.8},
    }
    response = requests.post(url, headers=headers, json=payload, timeout=60)
    response.raise_for_status()
    return response.content  # raw MP3 bytes


# ---------------------------------------------------------------------------
# Step 3 – Save MP3 and return a public URL
#
# In production, upload to S3/GCS and return the signed URL.
# Here we save to a temp directory and return a placeholder URL pattern.
# Replace `_store_mp3` with your cloud upload logic.
# ---------------------------------------------------------------------------

def _store_mp3(audio_bytes: bytes) -> str:
    """
    Save MP3 to a temp file and return its public URL.
    Replace this function with S3/GCS upload in production.
    """
    filename = f"call_{uuid.uuid4().hex}.mp3"
    tmp_dir = tempfile.gettempdir()
    filepath = os.path.join(tmp_dir, filename)

    with open(filepath, "wb") as f:
        f.write(audio_bytes)

    logger.info("MP3 saved to %s (%d bytes)", filepath, len(audio_bytes))

    # TODO: Replace with your media CDN base URL
    base_url = os.getenv("MEDIA_BASE_URL", "https://media.renewiq.app/calls")
    return f"{base_url}/{filename}"


# ---------------------------------------------------------------------------
# Step 4 – Twilio voice call (with retries)
# ---------------------------------------------------------------------------

@retry(
    retry=retry_if_exception_type((TwilioRestException, Exception)),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=30),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _dispatch_call(to: str, mp3_url: str) -> dict:
    client = Client(settings.TWILIO_ACCOUNT_SID, settings.TWILIO_AUTH_TOKEN)

    # Build TwiML to play the MP3
    twiml = VoiceResponse()
    twiml.append(Play(mp3_url))

    call = client.calls.create(
        twiml=str(twiml),
        to=to,
        from_=settings.TWILIO_PHONE_NUMBER,
    )
    return {"call_sid": call.sid, "status": call.status}


# ---------------------------------------------------------------------------
# LangChain tool
# ---------------------------------------------------------------------------

@tool
def send_call(
    to: Annotated[str, "Recipient phone number in E.164 format, e.g. +919876543210"],
    customer_name: Annotated[str, "Customer full name for personalised script"],
    expiry_date: Annotated[str, "Policy expiry date (YYYY-MM-DD) mentioned in script"],
    renewal_link: Annotated[str, "Renewal URL — converted to a spoken form in the script"],
    voice_id: Annotated[str, "ElevenLabs voice ID (optional, defaults to Rachel)"] = DEFAULT_VOICE_ID,
) -> dict:
    """
    Make a personalised AI voice renewal reminder call.

    Steps:
      1. GPT-4o-mini generates a conversational call script.
      2. ElevenLabs TTS synthesises the script into an MP3.
      3. MP3 is stored and a public URL is retrieved.
      4. Twilio Programmable Voice calls the customer and plays the MP3.

    Returns a dict with keys:
      - call_sid (str): Twilio call SID
      - status (str): Twilio call status ('queued', 'initiated', etc.)
      - script (str): The generated script for logging/auditing
    """
    try:
        # 1. Generate script
        script = _generate_call_script(customer_name, expiry_date, renewal_link)
        logger.info("Call script generated (%d chars) for %s", len(script), to)

        # 2. TTS → MP3
        audio_bytes = _elevenlabs_tts(script=script, voice_id=voice_id)

        # 3. Store MP3
        mp3_url = _store_mp3(audio_bytes)
        logger.info("MP3 stored at %s", mp3_url)

        # 4. Make Twilio call
        result = _dispatch_call(to=to, mp3_url=mp3_url)
        logger.info("Call initiated to %s | SID=%s | status=%s", to, result["call_sid"], result["status"])
        return {**result, "script": script}

    except Exception as exc:
        logger.error("Call failed to %s after retries: %s", to, exc)
        return {"call_sid": None, "status": "failed", "error": str(exc), "script": ""}
