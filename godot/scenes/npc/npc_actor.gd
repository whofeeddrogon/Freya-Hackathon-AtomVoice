extends Node3D

signal action_applied(action_name: String, payload: Dictionary)
signal offer_changed(current_price: float)
signal negotiation_state_changed(state: String)

@export var npc_id := "npc_default"
@export var display_name := "NPC"
@export var interaction_radius := 8.0
@export_multiline var start_instruction := "Oyuncu yanina geldi. Kisa bir selamlama yap."
@export var voice_system_path: NodePath = NodePath("")
@export var auto_register_active_npc := false

@export var base_price := 1000.0
@export var min_price := 700.0
@export var current_price := 1000.0
@export var negotiation_state := "open"
@export var default_mood := "neutral"
@export var action_values := {
	"haggle": 0.0
}

var last_action := ""
var last_note := ""
var mood_tag := "neutral"
var _audio_queue: Array[AudioStreamWAV] = []
var _queue_playing := false

@onready var voice_player: AudioStreamPlayer3D = $VoicePlayer

func _ready() -> void:
	add_to_group("voice_npc")
	if voice_player != null:
		voice_player.finished.connect(_on_voice_finished)
	mood_tag = default_mood
	if current_price <= 0.0:
		current_price = base_price
	if auto_register_active_npc and String(voice_system_path) != "":
		var voice_system = get_node_or_null(voice_system_path)
		if voice_system != null and voice_system.has_method("set_active_npc"):
			voice_system.call("set_active_npc", self)

func get_npc_id() -> String:
	return npc_id

func get_interaction_radius() -> float:
	return interaction_radius

func get_start_instruction() -> String:
	return start_instruction

func get_current_price() -> float:
	return current_price

func get_negotiation_state() -> String:
	return negotiation_state

func get_action_values() -> Dictionary:
	return action_values

func apply_action(action_name: String, payload: Dictionary = {}) -> void:
	var normalized := action_name.strip_edges().to_lower()
	if normalized == "":
		return

	last_action = normalized
	if payload.has("note"):
		last_note = str(payload["note"])
	if payload.has("mood"):
		mood_tag = str(payload["mood"])
	var has_price_from_payload := _apply_price_from_payload(payload)

	match normalized:
		"greet", "pitch":
			_set_negotiation_state("open")
		"haggle":
			if has_price_from_payload == false:
				_apply_counter_offer(payload, "haggle")
		"agree":
			_set_negotiation_state("deal")
		"reject":
			_set_negotiation_state("rejected")
		"leave":
			_set_negotiation_state("walked_away")
		_:
			# Unknown actions are still surfaced so game code can react.
			pass

	action_applied.emit(normalized, payload)

func distance_to_point(point: Vector3) -> float:
	return global_position.distance_to(point)

func play_wav_bytes(wav_bytes: PackedByteArray) -> bool:
	var stream := _build_stream_from_wav(wav_bytes)
	if stream == null:
		push_warning("NPC '" + npc_id + "' icin WAV parse edilemedi.")
		return false

	voice_player.stream = stream
	voice_player.play()
	return true

func enqueue_wav_bytes(wav_bytes: PackedByteArray) -> bool:
	var stream := _build_stream_from_wav(wav_bytes)
	if stream == null:
		push_warning("NPC '" + npc_id + "' icin WAV parse edilemedi (queue).")
		return false
	_audio_queue.append(stream)
	_try_play_next_queued()
	return true

func clear_audio_queue() -> void:
	_audio_queue.clear()
	_queue_playing = false
	if voice_player != null and voice_player.playing:
		voice_player.stop()

func _build_stream_from_wav(wav_bytes: PackedByteArray) -> AudioStreamWAV:
	if wav_bytes.size() < 44:
		return null
	if wav_bytes.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	if wav_bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null

	var fmt_offset := _find_chunk_offset(wav_bytes, "fmt ")
	var data_offset := _find_chunk_offset(wav_bytes, "data")
	if fmt_offset < 0 or data_offset < 0:
		return null
	if fmt_offset + 24 > wav_bytes.size():
		return null
	if data_offset + 8 > wav_bytes.size():
		return null

	var channels := _u16le_at(wav_bytes, fmt_offset + 10)
	var sample_rate := _u32le_at(wav_bytes, fmt_offset + 12)
	var bits_per_sample := _u16le_at(wav_bytes, fmt_offset + 22)
	var data_size := _u32le_at(wav_bytes, data_offset + 4)
	var data_start := data_offset + 8
	var data_end := data_start + data_size
	if data_end > wav_bytes.size():
		data_end = wav_bytes.size()
	if data_end <= data_start:
		return null

	if bits_per_sample != 16:
		push_warning("Sadece 16-bit PCM WAV destekleniyor. bits=" + str(bits_per_sample))
		return null

	var pcm := wav_bytes.slice(data_start, data_end)
	var stream := AudioStreamWAV.new()
	stream.data = pcm
	stream.mix_rate = sample_rate
	stream.stereo = channels >= 2
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	return stream

func _apply_discount(delta: float) -> void:
	current_price = max(min_price, current_price - max(delta, 0.0))
	offer_changed.emit(current_price)

func _apply_counter_offer(payload: Dictionary, fallback_key: String = "haggle") -> void:
	var proposed := 0.0
	if payload.has("price"):
		proposed = float(payload["price"])
	if proposed > 0.0:
		current_price = max(min_price, proposed)
	else:
		var fallback := _get_action_delta(fallback_key)
		if fallback > 0.0:
			current_price = max(min_price, current_price - fallback)
	offer_changed.emit(current_price)

func _set_negotiation_state(state: String) -> void:
	negotiation_state = state
	negotiation_state_changed.emit(state)

func _get_action_delta(action_name: String) -> float:
	if action_values.has(action_name):
		return float(action_values[action_name])
	return 0.0

func _apply_price_from_payload(payload: Dictionary) -> bool:
	if payload.has("price") == false:
		return false
	var quoted := float(payload["price"])
	if quoted <= 0.0:
		return false
	var next_price = max(min_price, quoted)
	if is_equal_approx(next_price, current_price):
		return true
	current_price = next_price
	offer_changed.emit(current_price)
	return true

func _on_voice_finished() -> void:
	_queue_playing = false
	_try_play_next_queued()

func _try_play_next_queued() -> void:
	if voice_player == null:
		return
	if _queue_playing:
		return
	if _audio_queue.is_empty():
		return

	var next_stream = _audio_queue.pop_front()
	if next_stream == null:
		return
	voice_player.stream = next_stream
	voice_player.play()
	_queue_playing = true

func _find_chunk_offset(bytes: PackedByteArray, chunk_id: String) -> int:
	var target := chunk_id.to_ascii_buffer()
	var i := 12
	while i + 8 <= bytes.size():
		if bytes.slice(i, i + 4) == target:
			return i
		var size := _u32le_at(bytes, i + 4)
		i += 8 + size
		if i % 2 == 1:
			i += 1
	return -1

func _u16le_at(bytes: PackedByteArray, offset: int) -> int:
	if offset + 2 > bytes.size():
		return 0
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8)

func _u32le_at(bytes: PackedByteArray, offset: int) -> int:
	if offset + 4 > bytes.size():
		return 0
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8) | (int(bytes[offset + 2]) << 16) | (int(bytes[offset + 3]) << 24)
