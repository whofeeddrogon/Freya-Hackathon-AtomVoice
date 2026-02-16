"""
NPC Registry — NPC tanımlarını yükler ve serve eder.
JSON dosyasından veya Godot client'ından gelen NPC bilgilerini saklar.
"""

import json
import threading
from pathlib import Path
from typing import Optional


class NPCRegistry:
    """NPC kayıt defteri. NPC bilgilerini yükler ve ID ile erişim sağlar."""

    def __init__(self):
        self._npcs: dict[str, dict] = {}
        self._main_story: str = ""
        self._lock = threading.Lock()

    def load_from_file(self, path: str | Path) -> int:
        """
        JSON dosyasından NPC tanımlarını yükler.
        Dosya formatı: {"main_story": "...", "npcs": [{"id": "...", ...}]}
        """
        path = Path(path)
        if not path.exists():
            raise FileNotFoundError(f"NPC config dosyası bulunamadı: {path}")

        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        with self._lock:
            self._main_story = data.get("main_story", "")
            npcs_list = data.get("npcs", [])
            for npc in npcs_list:
                npc_id = npc.get("id")
                if npc_id:
                    self._npcs[npc_id] = npc

        return len(npcs_list)

    def load_from_data(self, npcs_data: dict) -> int:
        """
        Godot client'ından gelen NPC tanımlarını yükler.
        Mevcut NPC'leri günceller/ekler.
        """
        npcs_list = npcs_data.get("npcs", [])
        with self._lock:
            if "main_story" in npcs_data:
                self._main_story = npcs_data["main_story"]
            for npc in npcs_list:
                npc_id = npc.get("id")
                if npc_id:
                    self._npcs[npc_id] = npc

        return len(npcs_list)

    def overwrite_and_save(self, npcs_data: dict, save_path: str | Path) -> int:
        """
        Mevcut tüm NPC'leri siler ve Godot'tan gelen yeni veriyle doldurur.
        Ardından veriyi belirtilen yola JSON olarak kaydeder.
        """
        npcs_list = npcs_data.get("npcs", [])
        save_path = Path(save_path)
        
        with self._lock:
            # Önce temizle
            self._npcs.clear()
            self._main_story = npcs_data.get("main_story", "")
            
            # Yeni veriyi ekle
            for npc in npcs_list:
                npc_id = npc.get("id")
                if npc_id:
                    self._npcs[npc_id] = npc
            
            # Kaydet
            with open(save_path, "w", encoding="utf-8") as f:
                json.dump(npcs_data, f, ensure_ascii=False, indent=2)
        
        return len(npcs_list)

    def get_main_story(self) -> str:
        """Global oyun hikayesini döner."""
        with self._lock:
            return self._main_story


    def get_npc(self, npc_id: str) -> Optional[dict]:
        """Bir NPC'nin bilgilerini döner. Bulunamazsa None."""
        with self._lock:
            npc = self._npcs.get(npc_id)
            if npc:
                return dict(npc)  # Kopya döndür
            return None

    def list_npcs(self) -> list[dict]:
        """Tüm kayıtlı NPC'leri listeler."""
        with self._lock:
            return [dict(npc) for npc in self._npcs.values()]

    def has_npc(self, npc_id: str) -> bool:
        """NPC kayıtlı mı kontrol eder."""
        with self._lock:
            return npc_id in self._npcs

    def remove_npc(self, npc_id: str) -> bool:
        """NPC'yi kayıttan siler."""
        with self._lock:
            if npc_id in self._npcs:
                del self._npcs[npc_id]
                return True
            return False

    def clear(self) -> None:
        """Tüm NPC kayıtlarını temizler."""
        with self._lock:
            self._npcs.clear()


# Global singleton
registry = NPCRegistry()
