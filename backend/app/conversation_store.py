"""
Conversation Store — Global sohbet veri yapısı.
Her NPC UUID'si altında tüm konuşma geçmişi saklanır.
Thread-safe erişim threading.Lock ile sağlanır.
"""

import threading
from typing import Optional


class ConversationStore:
    """
    In-memory conversation store.
    
    Yapı:
    {
        "npc_uuid": {
            "npc_id": "npc_uuid",
            "messages": [
                {"role": "user", "content": "..."},
                {"role": "assistant", "content": "..."}
            ]
        }
    }
    """

    def __init__(self):
        self._conversations: dict[str, dict] = {}
        # Geçici session chunk storage: session_id -> {index: {'text': str, 'stt_ms': float}}
        self._active_sessions: dict[str, dict[int, dict]] = {}
        self._lock = threading.Lock()

    def _ensure_conversation(self, npc_id: str) -> None:
        """NPC için konuşma kaydı yoksa oluşturur."""
        if npc_id not in self._conversations:
            self._conversations[npc_id] = {
                "npc_id": npc_id,
                "messages": [],
            }

    def add_user_message(self, npc_id: str, text: str) -> None:
        """Kullanıcı mesajını ekler."""
        with self._lock:
            self._ensure_conversation(npc_id)
            self._conversations[npc_id]["messages"].append(
                {"role": "user", "content": text}
            )

    def add_assistant_message(self, npc_id: str, text: str) -> None:
        """NPC (assistant) yanıtını ekler."""
        with self._lock:
            self._ensure_conversation(npc_id)
            self._conversations[npc_id]["messages"].append(
                {"role": "assistant", "content": text}
            )

    def get_conversation(self, npc_id: str) -> Optional[dict]:
        """Bir NPC'nin tüm konuşma geçmişini döner."""
        with self._lock:
            conv = self._conversations.get(npc_id)
            if conv is None:
                return None
            # Derin kopya döndür, dışarıdan mutasyonu engelle
            return {
                "npc_id": conv["npc_id"],
                "messages": list(conv["messages"]),
            }

    def get_messages(self, npc_id: str) -> list[dict]:
        """Bir NPC'nin mesaj listesini döner (boş liste eğer konuşma yoksa)."""
        with self._lock:
            conv = self._conversations.get(npc_id)
            if conv is None:
                return []
            return list(conv["messages"])

    def get_all_conversations(self) -> dict[str, dict]:
        """Tüm NPC sohbetlerini döner."""
        with self._lock:
            result = {}
            for npc_id, conv in self._conversations.items():
                result[npc_id] = {
                    "npc_id": conv["npc_id"],
                    "messages": list(conv["messages"]),
                }
            return result

    def clear_conversation(self, npc_id: str) -> bool:
        """Bir NPC'nin konuşma geçmişini temizler. Başarılıysa True döner."""
        with self._lock:
            if npc_id in self._conversations:
                self._conversations[npc_id]["messages"] = []
                return True
            return False

    def clear_all(self) -> None:
        """Tüm konuşmaları temizler."""
        with self._lock:
            self._conversations.clear()
            self._active_sessions.clear()

    def get_summary_for_context(self, exclude_npc_id: Optional[str] = None) -> str:
        """
        Tüm NPC konuşmalarının kısa özetini döner.
        Cross-NPC context için kullanılır — LLM'e gönderilir.
        exclude_npc_id verilirse o NPC'nin konuşması hariç tutulur
        (zaten tam konuşması ayrıca gönderildiği için).
        """
        with self._lock:
            summaries = []
            for npc_id, conv in self._conversations.items():
                if npc_id == exclude_npc_id:
                    continue
                msg_count = len(conv["messages"])
                if msg_count == 0:
                    continue
                # Son mesajı göster
                last_msg = conv["messages"][-1]
                summaries.append(
                    f"[{npc_id}] {msg_count} mesaj, son: {last_msg['role']}: \"{last_msg['content'][:80]}...\""
                )
            if not summaries:
                return ""
            return "Diğer NPC konuşmaları:\n" + "\n".join(summaries)

    # ─── Session / Chunk Management ─────────────────────────────────

    def add_chunk_text(self, session_id: str, index: int, text: str, stt_ms: float = 0.0) -> None:
        """
        Geçici session için chunk metni ve STT süresini ekler.
        Thread-safe.
        """
        with self._lock:
            if session_id not in self._active_sessions:
                self._active_sessions[session_id] = {}
            self._active_sessions[session_id][index] = {
                "text": text,
                "stt_ms": stt_ms
            }
    
    def get_session_indices(self, session_id: str) -> list[int]:
        """Mevcut session'daki chunk indexlerinin listesini döner."""
        with self._lock:
            if session_id not in self._active_sessions:
                return []
            return list(self._active_sessions[session_id].keys())

    def finalize_session(self, session_id: str) -> tuple[str, float | None]:
        """
        Session için biriken tüm metinleri index sırasına göre birleştirir
        ve session'ı siler.
        Returns: (full_text, last_chunk_stt_ms)
        """
        with self._lock:
            chunks = self._active_sessions.pop(session_id, {})
            if not chunks:
                return "", None
            
            # Index'e göre sırala
            sorted_indices = sorted(chunks.keys())
            sorted_texts = [chunks[i]["text"] for i in sorted_indices]
            
            # Son chunk'ın STT süresini bul
            last_index = sorted_indices[-1]
            last_stt_ms = chunks[last_index].get("stt_ms", 0.0)
            
            return " ".join(sorted_texts).strip(), last_stt_ms


# Global singleton
store = ConversationStore()
