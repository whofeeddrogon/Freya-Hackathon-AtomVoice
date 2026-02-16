"""
LLM Service — fal.ai/OpenRouter veya doğrudan Gemini API üzerinden LLM çağrısı.
USE_GEMINI_API=true olduğunda fal.ai bypass edilip direkt Gemini REST API kullanılır.
Streaming modu: Gemini streamGenerateContent ile cümle bazlı streaming.
"""

import os
import re
import time
import json as _json
import logging
import httpx

logger = logging.getLogger(__name__)

# Config — modül yüklenirken bir kez okunur
LLM_MODEL = os.getenv("LLM_MODEL", "google/gemini-2.0-flash")
LLM_SEED = int(os.getenv("LLM_SEED", "42"))
LLM_TEMPERATURE = float(os.getenv("LLM_TEMPERATURE", "0.0"))

# --- Gemini API vs fal/OpenRouter seçimi ---
USE_GEMINI_API = os.getenv("USE_GEMINI_API", "false").lower() == "true"
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")

# fal/OpenRouter ayarları
LLM_ENDPOINT = "https://fal.run/openrouter/router"
FAL_KEY = os.getenv("FAL_KEY", "")

_AUTH_HEADERS_FAL = {
    "Authorization": f"Key {FAL_KEY}",
    "Content-Type": "application/json",
}

# Gemini model haritası: OpenRouter formatını Gemini model adına çevirir
_GEMINI_MODEL_MAP = {
    "google/gemini-2.5-flash": "gemini-2.5-flash",
    "google/gemini-2.5-flash-lite": "gemini-2.5-flash-lite",
    "google/gemini-2.0-flash": "gemini-2.0-flash",
    "google/gemini-2.5-pro": "gemini-2.5-pro-preview-06-05",
    "google/gemini-1.5-flash": "gemini-1.5-flash",
}

# --- Global Stil ve Davranış Kuralları ---
# Modellerin tekrar ettiği veya istenmeyen kalıpları buraya ekleyebiliriz.
GLOBAL_CONSTRAINTS = """
STİL VE YANIT KURALLARI (KRİTİK):
1. İLK CÜMLE ÇOK KISA OLMALI: Vereceğin yanıtın İLK cümlesi en fazla 2-4 kelime olmalıdır. 
   ÖRN: "Tabii, bakalım.", "Sen de haklısın", "Hoş geldin!", "Elli akçe olur.", "Güzel bir parça."
   Daha uzun açıklamaları her zaman İKİNCİ cümleden itibaren yap. Bu kural ses hızı için çok kritiktir.
2. YASAKLI ÖDEKLER: Kesinlikle "gel beri", "gel hele", "bak hele", "hey gidi" gibi köylü/avvam ağzı veya aşırı yerel şiveler kullanma. 
3. AKICILIK: Cümlelerin doğal ve karakterinin kişiliğine uygun olsun.
4. TEKRAR: Gereksiz kelime ve fikir tekrarlarından kaçın.
"""



# Module-level persistent HTTP clients
_http_client: httpx.AsyncClient | None = None
_gemini_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    """fal/OpenRouter için tekil HTTP client döner."""
    global _http_client
    if _http_client is None or _http_client.is_closed:
        _http_client = httpx.AsyncClient(
            timeout=60.0,
            limits=httpx.Limits(
                max_connections=5,
                max_keepalive_connections=2,
                keepalive_expiry=60,
            ),
        )
    return _http_client


def _get_gemini_client() -> httpx.AsyncClient:
    """Gemini API için tekil HTTP client döner."""
    global _gemini_client
    if _gemini_client is None or _gemini_client.is_closed:
        _gemini_client = httpx.AsyncClient(
            timeout=60.0,
            limits=httpx.Limits(
                max_connections=5,
                max_keepalive_connections=2,
                keepalive_expiry=60,
            ),
        )
    return _gemini_client

if USE_GEMINI_API:
    logger.info(f"🔑 Gemini API modu aktif — model={LLM_MODEL}")
else:
    logger.info(f"🌐 fal/OpenRouter modu aktif — model={LLM_MODEL}")


def _build_prompt(
    npc_config: dict,
    conversation_history: list[dict],
    user_message: str,
    main_story: str = "",
    cross_npc_context: str = "",
) -> tuple[str, str]:
    """LLM'e gönderilecek system_prompt ve user prompt'u oluşturur."""
    # NPC bilgilerinden system prompt oluştur
    npc_name = npc_config.get("name", "NPC")
    personality = npc_config.get("personality", "")
    backstory = npc_config.get("backstory", "")
    system_prompt = npc_config.get("system_prompt", "")
    actions = npc_config.get("actions", [])

    # System prompt'u zenginleştir
    full_system = f"{system_prompt}\n\n"
    if personality:
        full_system += f"Kişiliğin: {personality}\n"

    # Knowledge Base / Lore
    secrets = npc_config.get("secrets", [])
    goals = npc_config.get("goals", [])

    if main_story:
        full_system += f"Oyunun Ana Hikayesi: {main_story}\n"
    if backstory:
        full_system += f"Kişisel Geçmişin: {backstory}\n"
    if goals:
        full_system += f"Kişisel Hedeflerin: {', '.join(goals)}\n"
    if secrets:
        full_system += f"Sırlar (Bu bilgileri doğrudan söyleme): {'; '.join(secrets)}\n"

    if actions:
        full_system += f"Yapabileceğin aksiyonlar: {', '.join(actions)}\n"
    
    # Global kısıtlamaları ekle
    full_system += f"\n{GLOBAL_CONSTRAINTS}\n"
    
    # Cross-NPC context ekle (diğer NPC'lerle olan konuşmalar)
    if cross_npc_context:
        full_system += f"\n{cross_npc_context}\n"

    # Konuşma geçmişini prompt'a ekle
    history_text = ""
    if conversation_history:
        history_text = "\nÖnceki konuşma:\n"
        for msg in conversation_history:
            role_label = "Oyuncu" if msg["role"] == "user" else npc_name
            history_text += f"{role_label}: {msg['content']}\n"

    # Final prompt
    full_prompt = f"{history_text}\nOyuncu: {user_message}\n(Hatırlatma: İlk cümlen en fazla 3 kelime olsun!)\n{npc_name}:"

    return full_system, full_prompt


_NOVOICE_RE = re.compile(r"<novoice>(.*?)</novoice>", re.IGNORECASE | re.DOTALL)

# Cümle sonu: . ! ? … karakterinden sonra boşluk geldiğinde böl
_SENTENCE_SPLIT_RE = re.compile(r'(?<=[.!?…])\s+')


def _parse_novoice(text: str) -> tuple[dict, str]:
    """LLM yanıtından <novoice> tag'ini parse eder.
    TTS'e gönderilmeyecek metadata'yı ayırır ve temiz metni döner.

    Returns: (metadata_dict, clean_text_for_tts)
    metadata_dict keys: action, price, mood, note
    """
    match = _NOVOICE_RE.search(text)
    if not match:
        return {}, text.strip()

    novoice_content = match.group(1).strip()
    clean_text = _NOVOICE_RE.sub("", text).strip()

    metadata = {}
    parts = novoice_content.split("|")
    for part in parts:
        part = part.strip()
        if ":" in part:
            key, value = part.split(":", 1)
            key = key.strip().lower()
            value = value.strip()
            if key == "price":
                try:
                    value = int(value)
                except ValueError:
                    try:
                        value = float(value)
                    except ValueError:
                        pass
            metadata[key] = value

    return metadata, clean_text


def _split_buffer(buffer: str) -> tuple[list[str], str]:
    """Buffer'ı cümle sınırlarından böler.
    Returns: (tamamlanmış_cümleler, kalan_buffer)
    """
    parts = _SENTENCE_SPLIT_RE.split(buffer)
    if len(parts) <= 1:
        return [], buffer  # Henüz tamamlanmış cümle yok
    # Son parça hariç hepsi tamamlanmış cümle
    sentences = [p.strip() for p in parts[:-1] if p.strip()]
    return sentences, parts[-1]


async def _stream_gemini_deltas(payload: dict):
    """Gemini streamGenerateContent API — text delta'ları yield eder."""
    model_name = payload.get("model", LLM_MODEL)
    gemini_model = _GEMINI_MODEL_MAP.get(model_name, model_name)

    system_prompt = payload.get("system_prompt", "")
    user_prompt = payload.get("prompt", "")

    gemini_payload = {
        "contents": [
            {"role": "user", "parts": [{"text": user_prompt}]}
        ],
        "generationConfig": {
            "temperature": payload.get("temperature", LLM_TEMPERATURE),
            "maxOutputTokens": payload.get("max_tokens", 300),
            "thinkingConfig": {"thinkingBudget": 0},
        },
    }

    if system_prompt:
        gemini_payload["systemInstruction"] = {"parts": [{"text": system_prompt}]}
    if LLM_SEED > 0:
        gemini_payload["generationConfig"]["seed"] = LLM_SEED

    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{gemini_model}:streamGenerateContent?alt=sse&key={GEMINI_API_KEY}"
    )

    client = _get_gemini_client()
    async with client.stream(
        "POST", url,
        json=gemini_payload,
        headers={"Content-Type": "application/json"},
    ) as response:
        response.raise_for_status()
        async for line in response.aiter_lines():
            if not line.startswith("data: "):
                continue
            try:
                data = _json.loads(line[6:])
            except (ValueError, _json.JSONDecodeError):
                continue
            candidates = data.get("candidates", [])
            if not candidates:
                continue
            parts = candidates[0].get("content", {}).get("parts", [])
            if parts:
                text = parts[0].get("text", "")
                if text:
                    yield text


async def _stream_llm_sentences(
    system_prompt: str,
    user_prompt: str,
    temperature: float = LLM_TEMPERATURE,
    max_tokens: int = 400,
):
    """
    LLM streaming → cümle bazlı async generator.
    Gemini aktifse streaming, değilse tek seferde non-streaming fallback.

    Yields:
        {"type": "sentence", "text": "...", "index": 0}
        ...
        {"type": "done", "full_text": "...", "novoice": {...}, "llm_time_ms": 123.4}
    """
    start_time = time.perf_counter()

    if not USE_GEMINI_API:
        # Fallback: non-streaming — tek seferde al, tek cümle olarak yield et
        result = await _call_fal({
            "prompt": user_prompt,
            "system_prompt": system_prompt,
            "model": LLM_MODEL,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "reasoning": False,
        })
        elapsed_ms = (time.perf_counter() - start_time) * 1000
        raw_text = result.get("output", "").strip()
        novoice_meta, clean_text = _parse_novoice(raw_text)
        if not clean_text:
            clean_text = "Hmm, bir şey söyleyemedim."
        yield {"type": "sentence", "text": clean_text, "index": 0}
        yield {
            "type": "done", "full_text": clean_text,
            "novoice": novoice_meta, "llm_time_ms": round(elapsed_ms, 1),
        }
        return

    # ── Gemini Streaming ──
    buffer = ""
    full_text = ""
    sentence_index = 0
    novoice_buffer = ""
    in_novoice = False
    first_sentence_ms = None

    payload = {
        "prompt": user_prompt,
        "system_prompt": system_prompt,
        "model": LLM_MODEL,
        "temperature": temperature,
        "max_tokens": max_tokens,
    }

    try:
        async for delta in _stream_gemini_deltas(payload):
            # novoice modundaysa sadece novoice buffer'a ekle
            if in_novoice:
                novoice_buffer += delta
                continue

            buffer += delta

            # <novoice> tag'i başladı mı?
            if "<novoice>" in buffer:
                idx = buffer.index("<novoice>")
                before = buffer[:idx]
                novoice_buffer = buffer[idx:]
                buffer = ""
                in_novoice = True

                # novoice öncesi kalan metni işle
                if before.strip():
                    sents, remaining = _split_buffer(before)
                    for s in sents:
                        if s.strip():
                            full_text += s + " "
                            if first_sentence_ms is None:
                                first_sentence_ms = (time.perf_counter() - start_time) * 1000
                            yield {"type": "sentence", "text": s.strip(), "index": sentence_index}
                            sentence_index += 1
                    if remaining.strip():
                        full_text += remaining + " "
                        if first_sentence_ms is None:
                            first_sentence_ms = (time.perf_counter() - start_time) * 1000
                        yield {"type": "sentence", "text": remaining.strip(), "index": sentence_index}
                        sentence_index += 1
                continue

            # Normal cümle bölme
            sentences, buffer = _split_buffer(buffer)
            for s in sentences:
                if s.strip():
                    full_text += s + " "
                    if first_sentence_ms is None:
                        first_sentence_ms = (time.perf_counter() - start_time) * 1000
                        logger.info(f"LLM ilk cümle: {first_sentence_ms:.0f}ms — \"{s[:60]}\"")
                    yield {"type": "sentence", "text": s.strip(), "index": sentence_index}
                    sentence_index += 1

    except Exception as e:
        logger.error(f"LLM streaming hatası: {e}")
        raise RuntimeError(f"LLM streaming yanıt üretemedi: {e}")

    # Kalan buffer'ı son cümle olarak yield et
    if buffer.strip() and not in_novoice:
        full_text += buffer
        if first_sentence_ms is None:
            first_sentence_ms = (time.perf_counter() - start_time) * 1000
        yield {"type": "sentence", "text": buffer.strip(), "index": sentence_index}
        sentence_index += 1

    elapsed_ms = (time.perf_counter() - start_time) * 1000
    clean_text = full_text.strip()

    # novoice parse
    novoice_meta = {}
    if novoice_buffer:
        novoice_meta, _ = _parse_novoice(novoice_buffer)

    if not clean_text:
        clean_text = "Hmm, bir şey söyleyemedim."

    logger.info(f"LLM streaming tamamlandı: {elapsed_ms:.0f}ms, "
                f"{sentence_index} cümle, ilk cümle: {first_sentence_ms:.0f}ms")

    yield {
        "type": "done",
        "full_text": clean_text,
        "novoice": novoice_meta,
        "llm_time_ms": round(elapsed_ms, 1),
        "first_sentence_ms": round(first_sentence_ms, 1) if first_sentence_ms else None,
        "sentence_count": sentence_index,
    }


async def _call_llm(payload: dict) -> dict:
    """Ortak LLM HTTP çağrısı. USE_GEMINI_API'ye göre yönlendirir."""
    if USE_GEMINI_API:
        return await _call_gemini(payload)
    return await _call_fal(payload)


async def _call_fal(payload: dict) -> dict:
    """fal.ai/OpenRouter üzerinden LLM çağrısı."""
    if LLM_SEED > 0:
        payload["seed"] = LLM_SEED

    client = _get_client()
    response = await client.post(LLM_ENDPOINT, headers=_AUTH_HEADERS_FAL, json=payload)
    response.raise_for_status()
    return response.json()


async def _call_gemini(payload: dict) -> dict:
    """
    Direkt Gemini REST API üzerinden LLM çağrısı.
    fal/OpenRouter formatindeki payload'ı Gemini formatına çevirir.
    """
    # Model adını Gemini formatına çevir
    model_name = payload.get("model", LLM_MODEL)
    gemini_model = _GEMINI_MODEL_MAP.get(model_name, model_name)
    
    # Prompt ve system_prompt'ı Gemini contents formatına çevir
    system_prompt = payload.get("system_prompt", "")
    user_prompt = payload.get("prompt", "")
    
    gemini_payload = {
        "contents": [
            {
                "role": "user",
                "parts": [{"text": user_prompt}]
            }
        ],
        "generationConfig": {
            "temperature": payload.get("temperature", LLM_TEMPERATURE),
            "maxOutputTokens": payload.get("max_tokens", 300),
            "thinkingConfig": {
                "thinkingBudget": 0
            },
        }
    }
    
    # System instruction ekle
    if system_prompt:
        gemini_payload["systemInstruction"] = {
            "parts": [{"text": system_prompt}]
        }
    
    # Seed ekle (destekleniyorsa)
    if LLM_SEED > 0:
        gemini_payload["generationConfig"]["seed"] = LLM_SEED
    
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{gemini_model}:generateContent?key={GEMINI_API_KEY}"
    
    client = _get_gemini_client()
    response = await client.post(
        url,
        headers={"Content-Type": "application/json"},
        json=gemini_payload
    )
    response.raise_for_status()
    gemini_result = response.json()
    
    # Gemini yanıtını fal/OpenRouter formatına dönüştür (gerisi değişmesin)
    output_text = ""
    usage = {}
    
    candidates = gemini_result.get("candidates", [])
    if candidates:
        parts = candidates[0].get("content", {}).get("parts", [])
        if parts:
            output_text = parts[0].get("text", "")
    
    usage_meta = gemini_result.get("usageMetadata", {})
    if usage_meta:
        usage = {
            "prompt_tokens": usage_meta.get("promptTokenCount", 0),
            "completion_tokens": usage_meta.get("candidatesTokenCount", 0),
            "total_tokens": usage_meta.get("totalTokenCount", 0),
        }
    
    return {
        "output": output_text,
        "usage": usage,
    }


async def generate_response(
    npc_config: dict,
    conversation_history: list[dict],
    user_message: str,
    main_story: str = "",
    cross_npc_context: str = "",
    temperature: float = LLM_TEMPERATURE,
    max_tokens: int = 400,
) -> dict:
    """NPC yanıtı üretir (Direct HTTP + Pooling). Non-streaming endpoint'ler için."""
    system_prompt, full_prompt = _build_prompt(
        npc_config, conversation_history, user_message, main_story, cross_npc_context
    )

    logger.info(f"LLM isteği — model={LLM_MODEL}, geçmiş={len(conversation_history)} mesaj")
    start_time = time.perf_counter()

    try:
        result = await _call_llm({
            "prompt": full_prompt,
            "system_prompt": system_prompt,
            "model": LLM_MODEL,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "reasoning": False,
        })
    except Exception as e:
        logger.error(f"LLM hatası: {e}")
        raise RuntimeError(f"LLM yanıt üretemedi: {e}")

    elapsed_ms = (time.perf_counter() - start_time) * 1000
    novoice_meta, clean_text = _parse_novoice(result.get("output", "").strip())
    if not clean_text:
        clean_text = "Hmm, bir şey söyleyemedim."

    logger.info(f"LLM tamamlandı: {elapsed_ms:.0f}ms — \"{clean_text[:60]}\"")
    return {
        "text": clean_text,
        "action": novoice_meta.get("action", ""),
        "price": novoice_meta.get("price", 0),
        "mood": novoice_meta.get("mood", ""),
        "note": novoice_meta.get("note", ""),
        "llm_time_ms": round(elapsed_ms, 1),
        "usage": result.get("usage", {}),
    }


async def generate_response_stream(
    npc_config: dict,
    conversation_history: list[dict],
    user_message: str,
    main_story: str = "",
    cross_npc_context: str = "",
    temperature: float = LLM_TEMPERATURE,
    max_tokens: int = 400,
):
    """
    NPC yanıtını streaming olarak üretir — cümle bazlı async generator.
    Her cümle yield edildiğinde hemen TTS'e gönderilebilir.
    """
    system_prompt, full_prompt = _build_prompt(
        npc_config, conversation_history, user_message, main_story, cross_npc_context
    )
    logger.info(f"LLM streaming isteği — model={LLM_MODEL}, geçmiş={len(conversation_history)} mesaj")

    async for item in _stream_llm_sentences(system_prompt, full_prompt, temperature, max_tokens):
        yield item


async def generate_starter_response(
    npc_config: dict,
    instruction: str,
    main_story: str = "",
    temperature: float = LLM_TEMPERATURE,
    max_tokens: int = 400,
) -> dict:
    """NPC'nin diyaloğu başlatması için yanıt üretir (Direct HTTP + Pooling)."""
    npc_name = npc_config.get("name", "NPC")
    personality = npc_config.get("personality", "")
    backstory = npc_config.get("backstory", "")
    system_prompt_base = npc_config.get("system_prompt", "")

    full_system = f"{system_prompt_base}\n\n"
    if personality:
        full_system += f"Kişiliğin: {personality}\n"
    if main_story:
        full_system += f"Oyunun Ana Hikayesi: {main_story}\n"
    if backstory:
        full_system += f"Kişisel Geçmişin: {backstory}\n"

    full_system += f"\n{GLOBAL_CONSTRAINTS}\n"
    full_system += f"\nTALİMAT: {instruction}"

    full_system += f"\nSadece {npc_name} olarak o ilk sözü dön."

    full_prompt = f"Dükkana girerken söyleyeceğin ilk cümleyi kur.\n{npc_name}:"

    logger.info(f"LLM Başlatıcı — NPC={npc_name}, Talimat={instruction[:50]}...")
    start_time = time.perf_counter()

    try:
        result = await _call_llm({
            "model": LLM_MODEL,
            "prompt": full_prompt,
            "system_prompt": full_system,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "reasoning": False,
        })
    except Exception as e:
        logger.error(f"LLM Başlatıcı hatası: {e}")
        raise RuntimeError(f"Diyalog başlatılamadı: {e}")

    elapsed_ms = (time.perf_counter() - start_time) * 1000
    novoice_meta, clean_text = _parse_novoice(result.get("output", "").strip())

    return {
        "text": clean_text,
        "action": novoice_meta.get("action", ""),
        "price": novoice_meta.get("price", 0),
        "mood": novoice_meta.get("mood", ""),
        "note": novoice_meta.get("note", ""),
        "llm_time_ms": round(elapsed_ms, 1),
        "usage": result.get("usage", {}),
    }


async def generate_starter_response_stream(
    npc_config: dict,
    instruction: str,
    main_story: str = "",
    temperature: float = LLM_TEMPERATURE,
    max_tokens: int = 400,
):
    """
    NPC diyalog başlatıcısını streaming olarak üretir — cümle bazlı.
    """
    npc_name = npc_config.get("name", "NPC")
    personality = npc_config.get("personality", "")
    backstory = npc_config.get("backstory", "")
    system_prompt_base = npc_config.get("system_prompt", "")

    full_system = f"{system_prompt_base}\n\n"
    if personality:
        full_system += f"Kişiliğin: {personality}\n"
    if main_story:
        full_system += f"Oyunun Ana Hikayesi: {main_story}\n"
    if backstory:
        full_system += f"Kişisel Geçmişin: {backstory}\n"

    full_system += f"\n{GLOBAL_CONSTRAINTS}\n"
    full_system += f"\nTALİMAT: {instruction}"

    full_system += f"\nSadece {npc_name} olarak o ilk sözü dön."

    full_prompt = f"Dükkana girerken söyleyeceğin ilk cümleyi kur.\n{npc_name}:"

    logger.info(f"LLM Başlatıcı streaming — NPC={npc_name}")

    async for item in _stream_llm_sentences(full_system, full_prompt, temperature, max_tokens):
        yield item
