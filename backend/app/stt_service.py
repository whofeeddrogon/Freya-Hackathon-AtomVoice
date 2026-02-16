"""
STT Service — Freya Speech-to-Text API entegrasyonu.
Doğrudan HTTP POST ile en düşük latency sağlanır (queue overhead yok).
Connection pooling ile her istekte TCP+TLS handshake tekrarlanmaz.
"""

import os
import time
import logging
import httpx

logger = logging.getLogger(__name__)

# Config — modül yüklenirken bir kez okunur
STT_ENDPOINT = os.getenv("STT_ENDPOINT", "freya-mypsdi253hbk/freya-stt")
STT_MODEL = os.getenv("STT_MODEL", "freya-stt-v1")
BASE_URL = f"https://fal.run/{STT_ENDPOINT}"
FAL_KEY = os.getenv("FAL_KEY", "")

_AUTH_HEADERS = {"Authorization": f"Key {FAL_KEY}"}

# Module-level persistent HTTP client — connection pooling
_http_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    """Tekil (singleton) HTTP client döner."""
    global _http_client
    if _http_client is None or _http_client.is_closed:
        _http_client = httpx.AsyncClient(
            timeout=60.0,
            limits=httpx.Limits(
                max_connections=5,
                max_keepalive_connections=2,
                keepalive_expiry=30,
            ),
        )
    return _http_client


async def transcribe_audio(
    audio_bytes: bytes,
    language: str = "tr",
    filename: str = "audio.wav",
) -> dict:
    """
    Ses dosyasını metne çevirir.

    Returns:
        {"text": "transkript metni", "stt_time_ms": 123.4}
    """
    url = f"{BASE_URL}/audio/transcriptions"
    files = {"file": (filename, audio_bytes, "audio/wav")}
    data = {
        "language": language,
        "model": STT_MODEL,
        "response_format": "json",
    }

    logger.info(f"STT isteği gönderiliyor ({len(audio_bytes)} bytes)...")
    start_time = time.perf_counter()

    client = _get_client()
    response = await client.post(url, headers=_AUTH_HEADERS, files=files, data=data)
    if response.status_code != 200:
        logger.error(f"STT hata ({response.status_code}): {response.text}")
    response.raise_for_status()

    elapsed_ms = (time.perf_counter() - start_time) * 1000
    result = response.json()
    text = result.get("text", "")

    logger.info(f"STT tamamlandı: {elapsed_ms:.0f}ms — \"{text[:80]}\"")

    return {
        "text": text,
        "stt_time_ms": round(elapsed_ms, 1),
    }

