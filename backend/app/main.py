"""
Atom Voice — NPC Voice Conversation Backend
FastAPI uygulaması: Godot Engine'den gelen ses dosyasını alıp,
STT → LLM → TTS pipeline'ı ile NPC yanıtını sese çevirip döner.
"""

import os
import time
import json
import asyncio
import logging
import queue as thread_queue
from pathlib import Path
from urllib.parse import quote

from dotenv import load_dotenv

# .env dosyasını yükle (FAL_KEY vb.)
load_dotenv()

from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import Response, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware

from pydantic import BaseModel
from app.conversation_store import store
from app.npc_registry import registry
from app.stt_service import transcribe_audio
from app.tts_service import text_to_speech_wav, text_to_speech_stream, SAMPLE_RATE
from app.llm_service import (
    generate_response, generate_starter_response,
    generate_response_stream, generate_starter_response_stream,
)

# ─── Modeller ──────────────────────────────────────────────────

class StartConvoRequest(BaseModel):
    npc_id: str
    instruction: str

class KnowledgeBaseRequest(BaseModel):
    main_story: str = ""
    npcs: list[dict]

# Logging ayarları
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("atom-voice")

# Debug logging flag — .env'den okunur, prod'da false yapılır
DEBUG_LOGGING = os.getenv("DEBUG_LOGGING", "true").lower() in ("true", "1", "yes")


def debug_print(msg: str) -> None:
    """DEBUG_LOGGING açıksa print eder, kapalıysa hiçbir şey yapmaz."""
    if DEBUG_LOGGING:
        print(msg)


def _log_pipeline(endpoint: str, *, stt_ms=None, final_chunk_stt_ms=None, llm_ms=0,
                  llm_first_sentence_ms=None, sentence_count=None,
                  tts_first_chunk_ms=None, tts_total_ms=0,
                  first_audio_ms=None, total_ms=0,
                  chunks=None, user_text="", npc_text="",
                  action="", price=0, mood="", note=""):
    """Pipeline özet log'ı — tüm endpoint'ler için ortak."""
    debug_print(f"\n🏁" + "─" * 68)
    debug_print(f"✅ {endpoint}")
    debug_print("─" * 70)
    if stt_ms is not None:
        debug_print(f"   🎙️  STT Total:      {stt_ms:7.1f} ms")
    if final_chunk_stt_ms is not None:
        debug_print(f"   🎙️  STT Final Chunk:{final_chunk_stt_ms:7.1f} ms")
    debug_print(f"   🧠  LLM toplam:     {llm_ms:7.1f} ms")
    if llm_first_sentence_ms is not None:
        debug_print(f"   🧠  LLM ilk cümle:  {llm_first_sentence_ms:7.1f} ms")
    if sentence_count is not None:
        debug_print(f"   📝  Cümle sayısı:   {sentence_count:7}")
    if tts_first_chunk_ms is not None:
        debug_print(f"   🔊  TTS ilk chunk:  {tts_first_chunk_ms:7.1f} ms")
    debug_print(f"   🔊  TTS toplam:     {tts_total_ms:7.1f} ms")
    fa = first_audio_ms if first_audio_ms else total_ms
    debug_print(f"   ⚡  İLK SES:        {fa:7.1f} ms  ← kullanıcının duyduğu")
    debug_print(f"   ⌛  TOPLAM:         {total_ms:7.1f} ms")
    if chunks is not None:
        debug_print(f"   📦  Chunks:         {chunks:7}")
    debug_print("─" * 70)
    if user_text:
        debug_print(f"   👤 \"{user_text}\"")
    debug_print(f"   🤖 \"{npc_text}\"")
    if action or price or mood or note:
        debug_print("─" * 70)
        debug_print(f"   🎬  Action:    {action}")
        debug_print(f"   💰  Price:     {price}")
        debug_print(f"   😊  Mood:      {mood}")
        debug_print(f"   📝  Note:      {note}")
    debug_print("─" * 70 + "\n")

# FastAPI uygulaması
app = FastAPI(
    title="Atom Voice — NPC Voice Conversation API",
    description="Godot Engine NPC'leriyle sesli konuşma için backend API",
    version="0.2.0",
)

# CORS — Godot HTTP istekleri için
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─── Başlangıç: NPC'leri yükle ─────────────────────────────────

@app.on_event("startup")
async def startup_event():
    """
    Uygulama başladığında:
    1. NPC'leri yükler
    2. STT/LLM/TTS servislerini ısıtır (cold-start yok etmek için)
    """
    kb_path = Path(__file__).parent.parent / "knowledgebase.json"
    npcs_path = Path(__file__).parent.parent / "npcs.json"

    if kb_path.exists():
        count = registry.load_from_file(kb_path)
        logger.info(f"Knowledge Base yüklendi: {kb_path} ({count} NPC)")
    elif npcs_path.exists():
        count = registry.load_from_file(npcs_path)
        logger.info(f"Varsayılan NPC'ler yüklendi: {npcs_path} ({count} NPC)")
    else:
        logger.warning("Hiçbir NPC dosyası bulunamadı!")

    # ── Pipeline Warmup (sunucu warmup bitene kadar istek almaz) ──
    await _warmup_pipeline()

    # ── Keep-alive ping iptal edildi (istek üzerine) ──
    # asyncio.create_task(_keep_alive_loop())


async def _warmup_pipeline():
    """STT, LLM ve TTS servislerine dummy istek atarak bağlantıları ve
    serverless instance'ları ısıtır. Sonuçlar kullanılmaz."""
    logger.info("🔥 Pipeline warmup başlatılıyor...")
    t0 = time.perf_counter()

    warmup_wav = _load_warmup_wav()
    if warmup_wav is None:
        logger.warning("  ⚠️ warmup.wav bulunamadı — STT warmup atlanıyor")

    async def warmup_stt():
        if warmup_wav is None:
            return
        # Çift warmup: 1) instance uyandır + model yükle  2) inference cache ısıt
        try:
            r1 = await transcribe_audio(warmup_wav, language="tr")
            logger.info(f"  ✅ STT warm #1 ({r1['stt_time_ms']:.0f}ms)")
            r2 = await transcribe_audio(warmup_wav, language="tr")
            logger.info(f"  ✅ STT warm #2 ({r2['stt_time_ms']:.0f}ms)")
        except Exception as e:
            logger.warning(f"  ⚠️ STT warmup başarısız (sorun değil): {e}")

    async def warmup_llm():
        try:
            from app.llm_service import _call_llm, LLM_MODEL, LLM_TEMPERATURE
            await _call_llm({
                "model": LLM_MODEL,
                "prompt": "Merhaba",
                "system_prompt": "Sen bir NPC'sin.",
                "max_tokens": 5,
                "temperature": LLM_TEMPERATURE,
                "reasoning": False,
            })
            logger.info("  ✅ LLM warm")
        except Exception as e:
            logger.warning(f"  ⚠️ LLM warmup başarısız (sorun değil): {e}")

    async def warmup_tts():
        try:
            await text_to_speech_wav("Merhaba dünya", voice="ali", speed=1.0)
            logger.info("  ✅ TTS warm")
        except Exception as e:
            logger.warning(f"  ⚠️ TTS warmup başarısız (sorun değil): {e}")

    # Hepsini paralel çalıştır — sunucu BİTENE KADAR BEKLER
    await asyncio.gather(warmup_stt(), warmup_llm(), warmup_tts())

    elapsed = (time.perf_counter() - t0) * 1000
    logger.info(f"🔥 Pipeline warmup tamamlandı: {elapsed:.0f}ms")


def _load_warmup_wav() -> bytes | None:
    """backend/warmup.wav dosyasını diskten okur.
    Dosya yoksa None döner."""
    warmup_path = Path(__file__).parent.parent / "warmup.wav"
    if warmup_path.exists():
        data = warmup_path.read_bytes()
        logger.info(f"  📁 warmup.wav yüklendi: {len(data)} bytes ({warmup_path})")
        return data
    return None


# ─── Ana Pipeline (Non-Streaming) ──────────────────────────────

@app.post("/start_convo")
async def start_convo(request: StartConvoRequest):
    """NPC'nin diyaloğu başlatmasını sağlar."""
    npc_id = request.npc_id
    instruction = request.instruction

    if not npc_id or not instruction:
        raise HTTPException(status_code=400, detail="npc_id ve instruction gerekli.")

    npc_config = registry.get_npc(npc_id)
    if not npc_config:
        raise HTTPException(status_code=404, detail=f"NPC bulunamadı: {npc_id}")

    logger.info(f"Diyalog başlatılıyor: NPC={npc_id}")

    try:
        main_story = registry.get_main_story()
        llm_result = await generate_starter_response(
            npc_config=npc_config, instruction=instruction, main_story=main_story
        )
        npc_text = llm_result["text"]
        store.add_assistant_message(npc_id, npc_text)

        voice = npc_config.get("voice", "alloy")
        tts_result = await text_to_speech_wav(npc_text, voice=voice)
        audio_content = tts_result["audio_bytes"]
        tts_time_ms = tts_result["tts_time_ms"]
        pipeline_ms = round(llm_result["llm_time_ms"] + tts_time_ms, 1)

        _log_pipeline("start_convo", llm_ms=llm_result["llm_time_ms"],
                      tts_total_ms=tts_time_ms, total_ms=pipeline_ms, npc_text=npc_text,
                      action=llm_result.get("action", ""), price=llm_result.get("price", 0),
                      mood=llm_result.get("mood", ""), note=llm_result.get("note", ""))

        return Response(
            content=audio_content, media_type="audio/wav",
            headers={
                "X-NPC-Response-Text": quote(npc_text),
                "X-NPC-Action": llm_result.get("action", ""),
                "X-NPC-Price": str(llm_result.get("price", 0)),
                "X-NPC-Mood": llm_result.get("mood", ""),
                "X-NPC-Note": quote(llm_result.get("note", ""), safe=""),
                "X-Pipeline-Time-Ms": str(pipeline_ms),
                "Access-Control-Expose-Headers": "*",
            },
        )
    except Exception as e:
        logger.error(f"Diyalog başlatma hatası: {e}")
        raise HTTPException(status_code=500, detail=str(e))



# ─── Hallüsinasyon Filtresi ────────────────────────────────────
# STT modelleri bazen boş seste bu tarz çıktılar uydurur.
IGNORE_PHRASES = {
    "İyi günler.", "Teşekkürler.", "Altyazı M.K.", "MBC", "Lütfen abone olun.", 
    "İzlediğiniz için teşekkürler.", "Sadece altyazı.", "Altyazı", 
    "Görüşürüz.", "Hoşça kalın.", "...", ".", "", "altyazı"
}

def _is_hallucination(text: str) -> bool:
    if not text:
        return True
    t = text.strip()
    if t in IGNORE_PHRASES:
        return True
    # Çok kısa ve anlamsız
    if len(t) < 2:
        return True
    # Kendi kendine konuşan altyazı pattern'ları
    t_lower = t.lower()
    if "altyazı" in t_lower or "subtitle" in t_lower:
        return True
    return False

async def _wait_for_missing_chunks(session_id: str, timeout: float = 2.0):
    """
    Session içinde aradaki eksik chunk'ları (örneğin 0, 2 geldi ama 1 yok) bekler.
    Son chunk'ın gelip gelmediğini bilemeyiz, sadece ARADAKİ boşlukları doldurmaya çalışırız.
    """
    start_time = time.perf_counter()
    while (time.perf_counter() - start_time) < timeout:
        indices = store.get_session_indices(session_id)
        if not indices:
            break
            
        min_idx = min(indices)
        max_idx = max(indices)
        
        # Beklenen: [min_idx, min_idx+1, ... max_idx]
        current_set = set(indices)
        expected_set = set(range(min_idx, max_idx + 1))
        missing = expected_set - current_set
        
        if not missing:
            return  # Eksik yok, devam et
            
        # Eksik var, biraz bekle
        await asyncio.sleep(0.1)
    
    # Timeout oldu, ne varsa onunla devam et
    logger.warning(f"Session {session_id} için eksik chunk bekleme süresi doldu.")


@app.post("/upload_audio_chunk")
async def upload_audio_chunk(
    audio: UploadFile = File(..., description="WAV formatında ses dosyası"),
    session_id: str = Form(..., description="Unique session ID for this utterance"),
    chunk_index: int = Form(..., description="Index of the chunk (0-based)"),
):
    """
    Sessizlik anında gönderilen ses parçasını alır, STT yapar ve hafızada tutar.
    Push-to-talk bitince /talk veya /talk_stream çağrılır.
    """
    audio_bytes = await audio.read()
    if len(audio_bytes) == 0:
        return {"status": "empty", "text": ""}

    try:
        # Hızlıca STT yap
        stt_result = await transcribe_audio(audio_bytes, language="tr")
        text = stt_result["text"].strip()
        
        if _is_hallucination(text):
            logger.info(f"Chunk IGNORED (Hallucination): session={session_id}, index={chunk_index}, text='{text}'")
            return {"status": "ignored", "text": text, "reason": "hallucination"}
        
        if text:
            store.add_chunk_text(session_id, chunk_index, text, stt_ms=stt_result["stt_time_ms"])
            logger.info(f"Chunk yüklendi: session={session_id}, index={chunk_index}, text='{text}', stt={stt_result['stt_time_ms']:.0f}ms")
        
        return {
            "status": "ok",
            "session_id": session_id,
            "chunk_index": chunk_index,
            "text": text,
            "stt_ms": stt_result["stt_time_ms"]
        }
    except Exception as e:
        logger.error(f"Chunk upload hatası: {e}")
        # Hata olsa bile client kopmamalı, sadece bu chunk işlenemedi deriz
        return {"status": "error", "detail": str(e)}


@app.post("/talk")
async def talk(
    audio: UploadFile = File(None, description="Opsiyonel son ses dosyası"),
    npc_id: str = Form(..., description="Konuşulan NPC'nin UUID'si"),
    session_id: str = Form(None, description="Varsa, önceki chunk'ları birleştirmek için ID"),
):
    """
    Ana pipeline endpoint'i (non-streaming).
    session_id varsa, önceki yüklenen chunk'ları alır ve (varsa) bu audio ile birleştirir.
    """
    pipeline_start = time.perf_counter()
    npc_config = registry.get_npc(npc_id)
    if npc_config is None:
        raise HTTPException(status_code=404, detail=f"NPC bulunamadı: {npc_id}")

    # 1. Metni belirle (Stored chunks + Current audio)
    final_user_text = ""
    stt_time_ms = 0.0

    # A) Stored Chunks
    if session_id:
        # Eksik chunk'ları bekle
        await _wait_for_missing_chunks(session_id)
        stored_text, last_chunk_stt_ms = store.finalize_session(session_id)
        if stored_text:
            final_user_text += stored_text + " "
            # Eğer şu anki audio yoksa, son chunk stt süresi stored olandır
            if not audio:
                # Burada stt_time_ms'i son chunk süresi olarak set etmek tartışmalı ama istenen bu
                # stt_time_ms = last_chunk_stt_ms 
                pass

    # B) Current Audio (Final Chunk)
    if audio:
        audio_bytes = await audio.read()
        if len(audio_bytes) > 0:
            try:
                stt_result = await transcribe_audio(audio_bytes, language="tr")
                current_text = stt_result["text"].strip()
                if current_text:
                    final_user_text += current_text
                # stt_time_ms burada sadece son parçanın süresi olurdu,
                # ama biz toplam 'metin hazırlama' süresini ölçmek istiyoruz.
            except Exception as e:
                # Eğer stored text varsa ve bu patladıysa, stored ile devam etmeye çalışalım mı?
                # Şimdilik hata dönüyoruz ama loglayıp devam edilebilir.
                logger.error(f"Final audio STT hatası: {e}")
                if not final_user_text:
                    raise HTTPException(status_code=502, detail=f"STT hatası: {e}")

    final_user_text = final_user_text.strip()
    if not final_user_text:
        raise HTTPException(status_code=400, detail="Hiçbir metin elde edilemedi (ne chunk ne audio).")

    user_text = final_user_text
    
    # ── STT Bitiş Zamanı (Effective Latency) ──
    # Kullanıcı için STT süresi = Request başlama anından metnin hazır olduğu ana kadar geçen süre
    stt_end_time = time.perf_counter()
    stt_time_ms = (stt_end_time - pipeline_start) * 1000
    
    # ... Pipeline devamı (Store, LLM, TTS) ...
    store.add_user_message(npc_id, user_text)
    history_for_llm = store.get_messages(npc_id)[:-1]
    cross_context = store.get_summary_for_context(exclude_npc_id=npc_id)

    try:
        main_story = registry.get_main_story()
        llm_result = await generate_response(
            npc_config=npc_config,
            conversation_history=history_for_llm,
            user_message=user_text,
            main_story=main_story,
            cross_npc_context=cross_context,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"LLM hatası: {e}")

    npc_response_text = llm_result["text"]
    llm_time_ms = llm_result["llm_time_ms"]
    store.add_assistant_message(npc_id, npc_response_text)

    npc_voice = npc_config.get("voice", "alloy")
    try:
        tts_result = await text_to_speech_wav(text=npc_response_text, voice=npc_voice)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"TTS hatası: {e}")

    wav_bytes = tts_result["audio_bytes"]
    tts_time_ms = tts_result["tts_time_ms"]
    pipeline_ms = (time.perf_counter() - pipeline_start) * 1000

    _log_pipeline("talk", stt_ms=stt_time_ms, llm_ms=llm_time_ms,
                  tts_total_ms=tts_time_ms, total_ms=pipeline_ms,
                  user_text=user_text, npc_text=npc_response_text,
                  action=llm_result.get("action", ""), price=llm_result.get("price", 0),
                  mood=llm_result.get("mood", ""), note=llm_result.get("note", ""))

    return Response(
        content=wav_bytes, media_type="audio/wav",
        headers={
            "X-NPC-Id": npc_id,
            "X-NPC-Response-Text": quote(npc_response_text, safe=""),
            "X-NPC-Action": llm_result.get("action", ""),
            "X-NPC-Price": str(llm_result.get("price", 0)),
            "X-NPC-Mood": llm_result.get("mood", ""),
            "X-NPC-Note": quote(llm_result.get("note", ""), safe=""),
            "X-User-Text": quote(user_text, safe=""),
            "X-Pipeline-Time-Ms": str(round(pipeline_ms, 1)),
            "X-STT-Time-Ms": str(round(stt_time_ms, 1)),
            "X-LLM-Time-Ms": str(round(llm_time_ms, 1)),
            "X-TTS-Time-Ms": str(round(tts_time_ms, 1)),
            "Access-Control-Expose-Headers": "*",
        },
    )


# ─── Streaming Endpoint'ler (LLM Streaming + TTS Overlap) ──────

def _create_streaming_sse_generator(
    pipeline_start: float,
    llm_stream_gen,
    npc_id: str,
    npc_voice: str,
    stt_time_ms: float | None = None,
    final_chunk_stt_ms: float | None = None,
    user_text: str = "",
):
    """
    LLM streaming → cümle bazlı TTS → SSE audio chunks.
    LLM ilk cümleyi ürettiği an TTS başlar; LLM devam ederken ses akar.
    """
    async def sse_generator():
        # ── Hemen metadata gönder (npc_text henüz bilinmiyor) ──
        metadata = {
            "type": "metadata",
            "npc_id": npc_id,
            "npc_text": "",  # Tam metin done event'inde gelecek
            "action": "",
            "price": 0,
            "mood": "",
            "note": "",
            "sample_rate": SAMPLE_RATE,
            "channels": 1,
            "bits_per_sample": 16,
        }
        if stt_time_ms is not None:
            metadata["stt_time_ms"] = round(stt_time_ms, 1)
            metadata["user_text"] = user_text
        if final_chunk_stt_ms is not None:
            metadata["final_chunk_stt_ms"] = round(final_chunk_stt_ms, 1)
        yield f"data: {json.dumps(metadata, ensure_ascii=False)}\n\n"

        # ── Queue'lar ──
        sentence_q = thread_queue.Queue()       # LLM → TTS (thread-safe)
        audio_q: asyncio.Queue = asyncio.Queue() # TTS → SSE (async)
        llm_done_info = {}

        # ── LLM Producer (async) — cümleleri sentence_q'ya atar ──
        async def llm_producer():
            try:
                async for item in llm_stream_gen:
                    if item["type"] == "sentence":
                        sentence_q.put(item["text"])
                    elif item["type"] == "done":
                        llm_done_info.update(item)
                        sentence_q.put(None)  # Bitti sinyali
            except Exception as e:
                logger.error(f"LLM producer hatası: {e}")
                llm_done_info["error"] = str(e)
                sentence_q.put(None)

        # ── TTS Worker (thread) — cümleleri alır, TTS yapar, audio_q'ya atar ──
        tts_timings = {"first_sentence_received": None}  # thread-safe dict

        def tts_worker():
            is_first = True
            while True:
                sentence = sentence_q.get()  # Blocking — LLM cümle üretene kadar bekle
                if sentence is None:
                    audio_q.put_nowait(None)
                    break
                if is_first:
                    tts_timings["first_sentence_received"] = time.perf_counter()
                    is_first = False
                try:
                    for chunk in text_to_speech_stream(sentence, voice=npc_voice):
                        if chunk["type"] == "audio":
                            audio_q.put_nowait(chunk)
                        # Bireysel TTS "done" event'lerini atla
                except Exception as e:
                    logger.error(f"TTS worker hatası (cümle: '{sentence[:30]}...'): {e}")

        # ── Her ikisini başlat ──
        llm_task = asyncio.create_task(llm_producer())
        loop = asyncio.get_event_loop()
        tts_future = loop.run_in_executor(None, tts_worker)

        # ── Audio chunk'ları SSE olarak yield et ──
        global_chunk_index = 0
        first_audio_pipeline_ms = None
        tts_first_chunk_ms = None  # TTS'in kendi ilk chunk süresi (TTS başlangıcından)
        tts_start_time = None

        while True:
            chunk = await audio_q.get()
            if chunk is None:
                break

            global_chunk_index += 1
            chunk["chunk_index"] = global_chunk_index

            # İlk audio chunk — pipeline first audio latency
            if global_chunk_index == 1:
                now = time.perf_counter()
                first_audio_pipeline_ms = round(
                    (now - pipeline_start) * 1000, 1
                )
                # TTS ilk chunk süresi = ilk audio chunk - TTS'in ilk cümleyi aldığı an
                t_recv = tts_timings.get("first_sentence_received")
                if t_recv:
                    tts_first_chunk_ms = round((now - t_recv) * 1000, 1)
                tts_start_time = now
                chunk["pipeline_first_audio_ms"] = first_audio_pipeline_ms
                chunk["first_chunk_ms"] = first_audio_pipeline_ms

            yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"

        # ── Bitmesini bekle ──
        await llm_task
        await tts_future

        # ── Store'a kaydet ──
        npc_text = llm_done_info.get("full_text", "")
        novoice = llm_done_info.get("novoice", {})
        llm_time_ms = llm_done_info.get("llm_time_ms", 0)

        if npc_text:
            store.add_assistant_message(npc_id, npc_text)

        # ── Done event ──
        pipeline_total_ms = round((time.perf_counter() - pipeline_start) * 1000, 1)
        tts_total_ms = round(
            (time.perf_counter() - tts_start_time) * 1000, 1
        ) if tts_start_time else 0

        done_event = {
            "type": "done",
            "npc_text": npc_text,
            "action": novoice.get("action", ""),
            "price": novoice.get("price", 0),
            "mood": novoice.get("mood", ""),
            "note": novoice.get("note", ""),
            "llm_time_ms": llm_time_ms,
            "first_sentence_ms": llm_done_info.get("first_sentence_ms"),
            "sentence_count": llm_done_info.get("sentence_count", 0),
            "tts_total_ms": tts_total_ms,
            "chunk_count": global_chunk_index,
            "pipeline_total_ms": pipeline_total_ms,
            "pipeline_first_audio_ms": first_audio_pipeline_ms,
        }
        yield f"data: {json.dumps(done_event, ensure_ascii=False)}\n\n"

        # ── Log ──
        _log_pipeline(
            "streaming_pipeline",
            stt_ms=stt_time_ms,
            final_chunk_stt_ms=final_chunk_stt_ms,
            llm_ms=llm_time_ms,
            llm_first_sentence_ms=llm_done_info.get("first_sentence_ms"),
            sentence_count=llm_done_info.get("sentence_count", 0),
            tts_first_chunk_ms=tts_first_chunk_ms,
            tts_total_ms=tts_total_ms,
            first_audio_ms=first_audio_pipeline_ms,
            total_ms=pipeline_total_ms,
            chunks=global_chunk_index,
            user_text=user_text,
            npc_text=npc_text,
            action=novoice.get("action", ""),
            price=novoice.get("price", 0),
            mood=novoice.get("mood", ""),
            note=novoice.get("note", ""),
        )

    return sse_generator()


@app.post("/talk_stream")
async def talk_stream(
    audio: UploadFile = File(None, description="Opsiyonel son ses dosyası"),
    npc_id: str = Form(..., description="Konuşulan NPC'nin UUID'si"),
    session_id: str = Form(None, description="Varsa, önceki chunk'ları birleştirmek için ID"),
):
    """
    Streaming pipeline: STT (stored + final) → LLM streaming → TTS overlap → SSE.
    """
    pipeline_start = time.perf_counter()
    npc_config = registry.get_npc(npc_id)
    if npc_config is None:
        raise HTTPException(status_code=404, detail=f"NPC bulunamadı: {npc_id}")

    # 1. Metni belirle
    final_user_text = ""
    stt_time_ms = 0.0
    final_chunk_stt_ms = None

    # A) Stored Chunks
    if session_id:
        # Eksik chunk'ları bekle
        await _wait_for_missing_chunks(session_id)
        stored_text, last_chunk_stt = store.finalize_session(session_id)
        if stored_text:
            final_user_text += stored_text + " "
            # Eğer audio yoksa, final_chunk_stt_ms olarak son store edilen chunk süresini kullan
            if not audio and last_chunk_stt is not None:
                final_chunk_stt_ms = last_chunk_stt

    # B) Current Audio
    if audio:
        audio_bytes = await audio.read()
        logger.info(f"🎤 STREAM Talk Final Audio: {len(audio_bytes)} bytes, session={session_id}")
        if len(audio_bytes) > 0:
            try:
                stt_result = await transcribe_audio(audio_bytes, language="tr")
                current_text = stt_result["text"].strip()
                if current_text:
                    final_user_text += current_text
                
                # Son parçanın STT süresini sakla
                final_chunk_stt_ms = stt_result.get("stt_time_ms")
            except Exception as e:
                logger.error(f"Final audio STT hatası: {e}")
                if not final_user_text:
                    raise HTTPException(status_code=502, detail=f"STT hatası: {e}")

    final_user_text = final_user_text.strip()
    if not final_user_text:
        raise HTTPException(status_code=400, detail="Hiçbir metin elde edilemedi.")

    user_text = final_user_text

    # ── STT Bitiş Zamanı (Effective Latency) ──
    stt_end_time = time.perf_counter()
    stt_time_ms = (stt_end_time - pipeline_start) * 1000
    
    # ... Pipeline devamı ...
    store.add_user_message(npc_id, user_text)
    history_for_llm = store.get_messages(npc_id)[:-1]
    cross_context = store.get_summary_for_context(exclude_npc_id=npc_id)

    main_story = registry.get_main_story()
    llm_stream = generate_response_stream(
        npc_config=npc_config,
        conversation_history=history_for_llm,
        user_message=user_text,
        main_story=main_story,
        cross_npc_context=cross_context,
    )

    npc_voice = npc_config.get("voice", "alloy")

    return StreamingResponse(
        _create_streaming_sse_generator(
            pipeline_start=pipeline_start,
            llm_stream_gen=llm_stream,
            npc_id=npc_id,
            npc_voice=npc_voice,
            stt_time_ms=stt_time_ms,
            final_chunk_stt_ms=final_chunk_stt_ms,
            user_text=user_text,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "*",
        },
    )


@app.post("/start_convo_stream")
async def start_convo_stream(request: StartConvoRequest):
    """NPC diyalog başlatma — LLM streaming + TTS overlap ile SSE."""
    npc_id = request.npc_id
    instruction = request.instruction

    if not npc_id or not instruction:
        raise HTTPException(status_code=400, detail="npc_id ve instruction gerekli.")

    npc_config = registry.get_npc(npc_id)
    if not npc_config:
        raise HTTPException(status_code=404, detail=f"NPC bulunamadı: {npc_id}")

    pipeline_start = time.perf_counter()
    logger.info(f"Streaming diyalog başlatılıyor: NPC={npc_id}")

    main_story = registry.get_main_story()
    llm_stream = generate_starter_response_stream(
        npc_config=npc_config,
        instruction=instruction,
        main_story=main_story,
    )

    voice = npc_config.get("voice", "alloy")

    return StreamingResponse(
        _create_streaming_sse_generator(
            pipeline_start=pipeline_start,
            llm_stream_gen=llm_stream,
            npc_id=npc_id,
            npc_voice=voice,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "*",
        },
    )


# ─── NPC Yönetimi ───────────────────────────────────────────────

@app.post("/enter_knowledgebase")
async def enter_knowledgebase(request: KnowledgeBaseRequest):
    """
    Godot client'ından gelen TAM knowledge base verisini alır.
    Mevcut registry'yi siler, yeni veriyi 'knowledgebase.json' olarak kaydeder.
    """
    kb_path = Path(__file__).parent.parent / "knowledgebase.json"
    count = registry.overwrite_and_save(request.model_dump(), kb_path)
    
    logger.info(f"Knowledge Base güncellendi ve kaydedildi: {kb_path} ({count} NPC)")
    return {
        "status": "ok",
        "message": "Knowledge base başarıyla güncellendi ve kaydedildi",
        "registered_count": count
    }


@app.get("/npcs")
async def list_npcs():
    """Tüm kayıtlı NPC'leri listeler."""
    return {"npcs": registry.list_npcs()}


@app.get("/npcs/{npc_id}")
async def get_npc(npc_id: str):
    """Belirli bir NPC'nin bilgilerini döner."""
    npc = registry.get_npc(npc_id)
    if npc is None:
        raise HTTPException(status_code=404, detail=f"NPC bulunamadı: {npc_id}")
    return npc


# ─── Konuşma Yönetimi ───────────────────────────────────────────

@app.get("/conversations")
async def get_all_conversations():
    """Tüm NPC konuşmalarını döner (debug/admin)."""
    return store.get_all_conversations()


@app.get("/conversations/{npc_id}")
async def get_conversation(npc_id: str):
    """Bir NPC'nin konuşma geçmişini döner."""
    conv = store.get_conversation(npc_id)
    if conv is None:
        return {"npc_id": npc_id, "messages": []}
    return conv


@app.delete("/conversations/{npc_id}")
async def clear_conversation(npc_id: str):
    """Bir NPC'nin konuşma geçmişini temizler."""
    cleared = store.clear_conversation(npc_id)
    return {"status": "cleared" if cleared else "not_found", "npc_id": npc_id}


@app.delete("/conversations")
async def clear_all_conversations():
    """Tüm konuşmaları temizler."""
    store.clear_all()
    return {"status": "all_cleared"}


# ─── Sağlık Kontrolü ────────────────────────────────────────────

@app.get("/health")
async def health_check():
    """Sunucu sağlık kontrolü."""
    fal_key = os.getenv("FAL_KEY", "")
    return {
        "status": "ok",
        "fal_key_configured": len(fal_key) > 0,
        "npc_count": len(registry.list_npcs()),
        "active_conversations": len(store.get_all_conversations()),
    }


# ─── Doğrudan çalıştırma ────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    logger.info(f"Atom Voice Backend başlatılıyor: {host}:{port}")
    uvicorn.run(app, host=host, port=port, log_level="info")
