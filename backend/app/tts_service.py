"""
TTS Service — Freya Text-to-Speech Streaming API entegrasyonu.
SSE üzerinden PCM16 chunk'ları alır, WAV formatına dönüştürür.
Streaming sayesinde ilk ses chunk'ı hızlıca elde edilir.
"""

import os
import io
import wave
import time
import base64
import logging
import fal_client

logger = logging.getLogger(__name__)

# Config
TTS_ENDPOINT = os.getenv("TTS_ENDPOINT", "freya-mypsdi253hbk/freya-tts")
SAMPLE_RATE = 16000  # PCM16 at 16kHz


def _pcm_to_wav(pcm_bytes: bytes, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Ham PCM16 verisini WAV formatına çevirir."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wf:
        wf.setnchannels(1)        # Mono
        wf.setsampwidth(2)        # 16-bit (2 bytes)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_bytes)
    return buffer.getvalue()


async def text_to_speech_wav(
    text: str,
    voice: str = "alloy",
    speed: float = 1.0,
) -> dict:
    """
    Metni sese çevirir (streaming ile PCM16 chunk'ları alıp WAV olarak birleştirir).

    Args:
        text: Seslendirmek istenen Türkçe metin
        voice: Ses seçimi ("alloy", "zeynep", "ali")
        speed: Oynatma hızı (0.25 - 4.0)

    Returns:
        {
            "audio_bytes": bytes (WAV formatında),
            "tts_time_ms": float,
            "audio_duration_sec": float,
            "chunk_count": int
        }
    """
    logger.info(f"TTS başlatılıyor: \"{text[:60]}...\" ses={voice} hız={speed}")
    start_time = time.perf_counter()

    audio_chunks: list[bytes] = []
    chunk_count = 0
    metadata: dict = {}

    try:
        stream = fal_client.stream(
            TTS_ENDPOINT,
            arguments={"input": text, "voice": voice, "speed": speed},
            path="/stream",
        )

        for event in stream:
            if "audio" in event:
                chunk_count += 1
                pcm_bytes = base64.b64decode(event["audio"])
                audio_chunks.append(pcm_bytes)

                if chunk_count == 1:
                    first_chunk_ms = (time.perf_counter() - start_time) * 1000
                    logger.info(f"TTS ilk chunk alındı: {first_chunk_ms:.0f}ms")

            if "error" in event:
                is_recoverable = event.get("recoverable", False)
                error_msg = event.get("error", {}).get("message", "Bilinmeyen hata")
                if not is_recoverable:
                    raise RuntimeError(f"TTS hatası: {error_msg}")
                logger.warning(f"TTS uyarı (kurtarılabilir): {error_msg}")

            if event.get("done"):
                metadata = {
                    "inference_time_ms": event.get("inference_time_ms"),
                    "audio_duration_sec": event.get("audio_duration_sec"),
                }

    except Exception as e:
        logger.error(f"TTS stream hatası: {e}")
        if not audio_chunks:
            raise

    elapsed_ms = (time.perf_counter() - start_time) * 1000

    if not audio_chunks:
        raise RuntimeError("TTS'den hiç ses chunk'ı alınamadı")

    # PCM chunk'larını birleştir ve WAV'a dönüştür
    all_pcm = b"".join(audio_chunks)
    wav_bytes = _pcm_to_wav(all_pcm)

    # Gerçek ses süresini hesapla
    total_samples = len(all_pcm) // 2  # 16-bit = 2 bytes per sample
    actual_duration_sec = total_samples / SAMPLE_RATE

    logger.info(
        f"TTS tamamlandı: {elapsed_ms:.0f}ms, {chunk_count} chunk, "
        f"{actual_duration_sec:.1f}s ses"
    )

    return {
        "audio_bytes": wav_bytes,
        "tts_time_ms": round(elapsed_ms, 1),
        "audio_duration_sec": round(actual_duration_sec, 3),
        "chunk_count": chunk_count,
    }


def text_to_speech_stream(
    text: str,
    voice: str = "alloy",
    speed: float = 1.0,
):
    """
    TTS streaming generator — fal.ai'den gelen PCM16 chunk'larını
    base64 olarak olduğu gibi yield eder. WAV'a dönüştürme YAPMAZ.

    Godot tarafında AudioStreamGenerator ile doğrudan çalınabilir.

    Yields:
        dict: Her biri aşağıdaki tiplerden biri:
            - {"type": "audio", "audio": "<base64 PCM16>", "chunk_index": int, "first_chunk_ms": float}
              (sadece ilk chunk'ta first_chunk_ms bulunur)
            - {"type": "audio", "audio": "<base64 PCM16>", "chunk_index": int}
            - {"type": "done", "tts_total_ms": float, "tts_first_chunk_ms": float, "chunk_count": int, ...}
            - {"type": "error", "error": str}
    """
    logger.info(f"TTS stream başlatılıyor: \"{text[:60]}...\" ses={voice} hız={speed}")
    start_time = time.perf_counter()

    chunk_count = 0
    first_chunk_ms = None

    try:
        stream = fal_client.stream(
            TTS_ENDPOINT,
            arguments={"input": text, "voice": voice, "speed": speed},
            path="/stream",
        )

        for event in stream:
            if "audio" in event:
                chunk_count += 1

                if chunk_count == 1:
                    first_chunk_ms = (time.perf_counter() - start_time) * 1000
                    logger.info(f"TTS ilk chunk alındı: {first_chunk_ms:.0f}ms")
                    yield {
                        "type": "audio",
                        "audio": event["audio"],  # zaten base64
                        "chunk_index": chunk_count,
                        "first_chunk_ms": round(first_chunk_ms, 1),
                    }
                else:
                    yield {
                        "type": "audio",
                        "audio": event["audio"],
                        "chunk_index": chunk_count,
                    }

            if "error" in event:
                is_recoverable = event.get("recoverable", False)
                error_msg = event.get("error", {}).get("message", "Bilinmeyen hata")
                if not is_recoverable:
                    logger.error(f"TTS stream hatası (kurtarılamaz): {error_msg}")
                    yield {"type": "error", "error": error_msg}
                    return
                logger.warning(f"TTS uyarı (kurtarılabilir): {error_msg}")

            if event.get("done"):
                total_ms = (time.perf_counter() - start_time) * 1000
                logger.info(
                    f"TTS stream tamamlandı: {total_ms:.0f}ms, {chunk_count} chunk, "
                    f"ilk chunk: {first_chunk_ms:.0f}ms" if first_chunk_ms else
                    f"TTS stream tamamlandı: {total_ms:.0f}ms, {chunk_count} chunk"
                )
                yield {
                    "type": "done",
                    "tts_total_ms": round(total_ms, 1),
                    "tts_first_chunk_ms": round(first_chunk_ms, 1) if first_chunk_ms else None,
                    "chunk_count": chunk_count,
                    "inference_time_ms": event.get("inference_time_ms"),
                    "audio_duration_sec": event.get("audio_duration_sec"),
                }

    except Exception as e:
        logger.error(f"TTS stream hatası: {e}")
        if chunk_count == 0:
            yield {"type": "error", "error": str(e)}
        else:
            # Kısmi veri geldi, hata ile sonlandır
            yield {
                "type": "done",
                "tts_total_ms": round((time.perf_counter() - start_time) * 1000, 1),
                "tts_first_chunk_ms": round(first_chunk_ms, 1) if first_chunk_ms else None,
                "chunk_count": chunk_count,
                "error": str(e),
                "partial": True,
            }
