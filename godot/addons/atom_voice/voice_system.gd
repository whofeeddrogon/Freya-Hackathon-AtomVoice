extends Node

signal backend_error(stage: String, message: String, http_code: int, result_code: int)
signal wrapper_state_changed(state: String)
signal story_bootstrapped(payload: Dictionary)
signal conversation_started(npc_id: String, npc_text: String, actions: Array[String])
signal dialogue_turn_completed(npc_id: String, npc_text: String, actions: Array[String], action_payload: Dictionary)
signal action_received(action_name: String, payload: Dictionary)
signal player_audio_submitted(npc_id: String)
signal stream_first_audio_latency(stage: String, latency_ms: float)

@export var story_database_path := "res://addons/atom_voice/story_database.tres"
@export var backend_base_url := "https://voice.vendigo.app"
@export var voice_recorder_path: NodePath = NodePath("../VoiceRecorder")
@export var request_timeout_sec := 20.0
@export var auto_bind_recorder := true
@export var auto_push_story_on_ready := true
@export var use_talk_stream := true
@export var use_start_convo_stream := true
@export var chunk_upload_retry_limit := 2

const BACKEND_CONTROLLERS := {
	# backend/app/main.py -> @app.post("/enter_knowledgebase")
	"enter_knowledgebase": "/enter_knowledgebase",
	# backend/app/main.py -> @app.post("/start_convo")
	"start_convo": "/start_convo",
	# backend/app/main.py -> @app.post("/talk")
	"talk": "/talk",
	# backend/app/main.py -> @app.get("/health")
	"health": "/health",
	# backend/app/main.py -> @app.post("/talk_stream")
	"talk_stream": "/talk_stream",
	# backend/app/main.py -> @app.post("/start_convo_stream")
	"start_convo_stream": "/start_convo_stream"
	,
	# backend/app/main.py -> @app.post("/upload_audio_chunk")
	"upload_audio_chunk": "/upload_audio_chunk"
}

var recorder: Node = null
var active_npc: Node = null

var story_request: HTTPRequest = null
var start_convo_request: HTTPRequest = null
var dialogue_request: HTTPRequest = null
var health_request: HTTPRequest = null

var pending_start_npc: Node = null
var pending_dialogue_npc: Node = null
var is_start_convo_in_flight := false
var is_dialogue_in_flight := false
var is_chunk_upload_in_flight := false
var pending_chunk_uploads: Array[Dictionary] = []
var current_chunk_session_id := ""
var current_chunk_index := 0
var final_audio_sent_this_recording := false
var pending_finalize_after_chunks := false
var pending_finalize_filename := "ptt_record.wav"
var uploaded_chunk_ack_count := 0
var chunk_upload_failed_count := 0

func _ready() -> void:
	_setup_requests()
	if auto_bind_recorder:
		var recorder_node = get_node_or_null(voice_recorder_path)
		if recorder_node != null:
			bind_recorder(recorder_node)
		else:
			_emit_backend_error("bind_recorder", "VoiceRecorder bulunamadi: " + str(voice_recorder_path), -1, -1)
	if auto_push_story_on_ready:
		push_story_database()

func bind_recorder(recorder_node: Node) -> bool:
	if recorder_node == null:
		_emit_backend_error("bind_recorder", "Recorder node null.", -1, -1)
		return false
	if recorder_node.has_signal("wav_ready") == false:
		_emit_backend_error("bind_recorder", "Recorder 'wav_ready' sinyali sunmuyor.", -1, -1)
		return false

	unbind_recorder()
	recorder = recorder_node
	recorder.connect("wav_ready", Callable(self, "_on_wav_ready"))
	if recorder.has_signal("wav_chunk_ready"):
		recorder.connect("wav_chunk_ready", Callable(self, "_on_wav_chunk_ready"))
	if recorder.has_signal("recording_started"):
		recorder.connect("recording_started", Callable(self, "_on_recording_started"))
	if recorder.has_signal("recording_stopped"):
		recorder.connect("recording_stopped", Callable(self, "_on_recording_stopped"))
	return true

func unbind_recorder() -> void:
	if recorder != null and recorder.has_signal("wav_ready"):
		var cb = Callable(self, "_on_wav_ready")
		if recorder.is_connected("wav_ready", cb):
			recorder.disconnect("wav_ready", cb)
	if recorder != null and recorder.has_signal("wav_chunk_ready"):
		var cb_chunk = Callable(self, "_on_wav_chunk_ready")
		if recorder.is_connected("wav_chunk_ready", cb_chunk):
			recorder.disconnect("wav_chunk_ready", cb_chunk)
	if recorder != null and recorder.has_signal("recording_started"):
		var cb_start = Callable(self, "_on_recording_started")
		if recorder.is_connected("recording_started", cb_start):
			recorder.disconnect("recording_started", cb_start)
	if recorder != null and recorder.has_signal("recording_stopped"):
		var cb_stop = Callable(self, "_on_recording_stopped")
		if recorder.is_connected("recording_stopped", cb_stop):
			recorder.disconnect("recording_stopped", cb_stop)
	recorder = null

func set_active_npc(npc: Node) -> bool:
	if npc == null:
		_emit_backend_error("set_active_npc", "NPC node null.", -1, -1)
		return false
	var npc_id := _get_npc_id(npc)
	if npc_id == "":
		_emit_backend_error("set_active_npc", "NPC'de gecerli npc_id yok.", -1, -1)
		return false
	active_npc = npc
	_emit_state("active_npc_set")
	return true

func clear_active_npc() -> void:
	active_npc = null
	_emit_state("active_npc_cleared")

func configure_runtime(recorder_node: Node, npc_node: Node) -> bool:
	var recorder_ok := true
	if recorder_node != null:
		recorder_ok = bind_recorder(recorder_node)
	var npc_ok := true
	if npc_node != null:
		npc_ok = set_active_npc(npc_node)
	return recorder_ok and npc_ok

func begin_single_npc_loop(npc_node: Node, instruction: String = "") -> bool:
	if set_active_npc(npc_node) == false:
		return false
	return start_conversation(instruction)

func push_story_database() -> bool:
	var payload := _build_story_payload()
	if payload.is_empty():
		_emit_backend_error("enter_knowledgebase", "Story payload bos, gonderilemedi.", -1, -1)
		return false

	var body := JSON.stringify(payload).to_utf8_buffer()
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json"
	])
	var err := story_request.request_raw(_controller_url("enter_knowledgebase"), headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_emit_backend_error("enter_knowledgebase", "Request baslatilamadi.", -1, err)
		return false
	_emit_state("bootstrapping_story")
	story_bootstrapped.emit(payload)
	return true

func start_conversation(instruction: String = "") -> bool:
	if active_npc == null:
		_emit_backend_error("start_convo", "Active NPC ayarlanmamis.", -1, -1)
		return false
	if is_start_convo_in_flight or is_dialogue_in_flight:
		return false

	var npc_id := _get_npc_id(active_npc)
	if npc_id == "":
		_emit_backend_error("start_convo", "Active NPC npc_id bos.", -1, -1)
		return false

	var effective_instruction := instruction.strip_edges()
	if effective_instruction == "":
		effective_instruction = _get_npc_start_instruction(active_npc)
	if effective_instruction == "":
		effective_instruction = "Pazarliga kisa bir acilis cumlesiyle basla."

	var payload := {
		"npc_id": npc_id,
		"instruction": effective_instruction
	}
	pending_start_npc = active_npc
	is_start_convo_in_flight = true
	_emit_state("waiting_start_convo")

	if use_start_convo_stream:
		call_deferred("_run_start_convo_stream_request", payload, pending_start_npc, Time.get_ticks_msec())
		return true

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: audio/wav, application/json"
	])
	var body := JSON.stringify(payload).to_utf8_buffer()
	var err := start_convo_request.request_raw(_controller_url("start_convo"), headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		is_start_convo_in_flight = false
		pending_start_npc = null
		_emit_backend_error("start_convo", "Request baslatilamadi.", -1, err)
		return false

	return true

func send_player_audio(wav_bytes: PackedByteArray, filename: String = "ptt_record.wav") -> bool:
	if active_npc == null:
		_emit_backend_error("talk", "Active NPC ayarlanmamis.", -1, -1)
		return false
	if current_chunk_session_id == "":
		current_chunk_session_id = _create_chunk_session_id()
	if wav_bytes.is_empty() == false:
		_enqueue_chunk_upload(wav_bytes, filename)
	pending_finalize_after_chunks = true
	pending_finalize_filename = filename
	_maybe_finalize_turn_after_chunks()
	return true

func _send_turn_request(wav_bytes: PackedByteArray, filename: String, session_id: String) -> bool:
	if active_npc == null:
		_emit_backend_error("talk", "Active NPC ayarlanmamis.", -1, -1)
		return false
	if is_dialogue_in_flight:
		return false
	var npc_id := _get_npc_id(active_npc)
	if npc_id == "":
		_emit_backend_error("talk", "Active NPC npc_id bos.", -1, -1)
		return false
	player_audio_submitted.emit(npc_id)

	var boundary := "----godotboundary" + str(Time.get_ticks_msec())
	var body := PackedByteArray()
	_append_form_field(body, boundary, "npc_id", npc_id)
	if session_id != "":
		_append_form_field(body, boundary, "session_id", session_id)
	if wav_bytes.is_empty() == false:
		# FastAPI /talk_stream endpoint paramlari: audio (opsiyonel), npc_id, session_id
		_append_form_file(body, boundary, "audio", filename, "audio/wav", wav_bytes)
	body.append_array(("--" + boundary + "--\r\n").to_utf8_buffer())

	var headers := PackedStringArray([
		"Content-Type: multipart/form-data; boundary=" + boundary,
		"Accept: text/event-stream, application/json, audio/wav"
	])

	pending_dialogue_npc = active_npc
	is_dialogue_in_flight = true
	_emit_state("waiting_talk")

	if use_talk_stream:
		call_deferred("_run_talk_stream_request", body, boundary, pending_dialogue_npc, Time.get_ticks_msec())
		return true

	var err := dialogue_request.request_raw(_controller_url("talk"), headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		is_dialogue_in_flight = false
		pending_dialogue_npc = null
		_emit_backend_error("talk", "Request baslatilamadi.", -1, err)
		return false

	return true

func ping_health() -> bool:
	var err := health_request.request(_controller_url("health"), PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		_emit_backend_error("health", "Health request baslatilamadi.", -1, err)
		return false
	return true

func _setup_requests() -> void:
	story_request = _new_request(_on_story_init_done)
	start_convo_request = _new_request(_on_start_convo_done)
	dialogue_request = _new_request(_on_dialogue_done)
	health_request = _new_request(_on_health_done)

func _new_request(callback: Callable) -> HTTPRequest:
	var req := HTTPRequest.new()
	req.timeout = request_timeout_sec
	add_child(req)
	req.request_completed.connect(callback)
	return req

func _on_wav_ready(wav_bytes: PackedByteArray, filename: String) -> void:
	if active_npc == null:
		_emit_backend_error("talk", "Recorder sesi geldi ama active NPC yok.", -1, -1)
		return
	final_audio_sent_this_recording = true
	send_player_audio(wav_bytes, filename)

func _on_recording_started() -> void:
	final_audio_sent_this_recording = false
	current_chunk_session_id = _create_chunk_session_id()
	current_chunk_index = 0
	pending_chunk_uploads.clear()
	is_chunk_upload_in_flight = false
	pending_finalize_after_chunks = false
	pending_finalize_filename = "ptt_record.wav"
	uploaded_chunk_ack_count = 0
	chunk_upload_failed_count = 0

func _on_recording_stopped(wav_bytes: PackedByteArray, filename: String) -> void:
	if final_audio_sent_this_recording:
		_maybe_finalize_turn_after_chunks()
		return
	# Sessizlikte chunklara bolunme akisini daima "upload_audio_chunk -> talk_stream" sirasiyla finalize et.
	send_player_audio(wav_bytes, filename)

func _on_wav_chunk_ready(wav_bytes: PackedByteArray, filename: String) -> void:
	if active_npc == null:
		return
	if current_chunk_session_id == "":
		current_chunk_session_id = _create_chunk_session_id()
	_enqueue_chunk_upload(wav_bytes, filename)

func _enqueue_chunk_upload(wav_bytes: PackedByteArray, filename: String) -> void:
	if wav_bytes.is_empty():
		return
	if current_chunk_session_id == "":
		current_chunk_session_id = _create_chunk_session_id()
	var item := {
		"wav": wav_bytes,
		"filename": filename,
		"session_id": current_chunk_session_id,
		"chunk_index": current_chunk_index,
		"attempt": 0
	}
	current_chunk_index += 1
	pending_chunk_uploads.append(item)
	_pump_chunk_upload_queue()

func _pump_chunk_upload_queue() -> void:
	if is_chunk_upload_in_flight:
		return
	if pending_chunk_uploads.is_empty():
		return

	var item: Dictionary = pending_chunk_uploads.pop_front()
	var wav: PackedByteArray = item["wav"]
	if wav.is_empty():
		_pump_chunk_upload_queue()
		return

	var boundary := "----godotboundarychunk" + str(Time.get_ticks_msec())
	var body := PackedByteArray()
	_append_form_field(body, boundary, "session_id", str(item["session_id"]))
	_append_form_field(body, boundary, "chunk_index", str(item["chunk_index"]))
	_append_form_file(body, boundary, "audio", str(item["filename"]), "audio/wav", wav)
	body.append_array(("--" + boundary + "--\r\n").to_utf8_buffer())
	var headers := PackedStringArray([
		"Content-Type: multipart/form-data; boundary=" + boundary,
		"Accept: application/json"
	])

	var req := HTTPRequest.new()
	req.timeout = request_timeout_sec
	add_child(req)
	is_chunk_upload_in_flight = true
	var cb := Callable(self, "_on_chunk_upload_done").bind(req, item)
	req.request_completed.connect(cb)
	var err := req.request_raw(_controller_url("upload_audio_chunk"), headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		is_chunk_upload_in_flight = false
		req.queue_free()
		_handle_chunk_upload_failure(item, "Chunk upload baslatilamadi.", -1, err)
		_pump_chunk_upload_queue()

func _on_chunk_upload_done(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, req: HTTPRequest, item: Dictionary) -> void:
	is_chunk_upload_in_flight = false
	if req != null:
		req.queue_free()
	if _chunk_upload_response_ok(result, response_code, body):
		uploaded_chunk_ack_count += 1
	else:
		_handle_chunk_upload_failure(item, "Chunk upload cevabi hatali.", response_code, result)
	_pump_chunk_upload_queue()
	_maybe_finalize_turn_after_chunks()

func _chunk_upload_response_ok(result: int, response_code: int, body: PackedByteArray) -> bool:
	if result != HTTPRequest.RESULT_SUCCESS:
		return false
	if response_code < 200 or response_code >= 300:
		return false
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var status := str(parsed.get("status", "")).to_lower()
	return status == "ok" or status == "ignored" or status == "empty"

func _handle_chunk_upload_failure(item: Dictionary, message: String, http_code: int, result_code: int) -> void:
	var attempt := int(item.get("attempt", 0))
	if attempt < chunk_upload_retry_limit:
		item["attempt"] = attempt + 1
		pending_chunk_uploads.push_front(item)
		return
	chunk_upload_failed_count += 1
	_emit_backend_error("upload_audio_chunk", message, http_code, result_code)

func _maybe_finalize_turn_after_chunks() -> void:
	if pending_finalize_after_chunks == false:
		return
	if is_chunk_upload_in_flight:
		return
	if pending_chunk_uploads.is_empty() == false:
		return
	if is_dialogue_in_flight:
		return
	# Bu turda hic chunk yoksa final istegi gonderme.
	if current_chunk_index <= 0:
		pending_finalize_after_chunks = false
		current_chunk_session_id = ""
		return

	var session_id := current_chunk_session_id
	if session_id == "":
		pending_finalize_after_chunks = false
		return
	# Butun chunklar backend tarafindan ACK almadan finalize etme.
	if uploaded_chunk_ack_count < current_chunk_index:
		return
	# Retry limiti asilip dusen chunk varsa finali iptal et.
	if chunk_upload_failed_count > 0:
		_emit_backend_error("talk_stream", "Chunk upload basarisiz oldugu icin final istek gonderilmedi.", -1, -1)
		pending_finalize_after_chunks = false
		return

	var ok := _send_turn_request(PackedByteArray(), pending_finalize_filename, session_id)
	if ok:
		pending_finalize_after_chunks = false
		current_chunk_session_id = ""
		current_chunk_index = 0
		uploaded_chunk_ack_count = 0
		chunk_upload_failed_count = 0

func _run_start_convo_stream_request(payload: Dictionary, npc: Node, submitted_ms: int) -> void:
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: text/event-stream, application/json"
	])
	var body := JSON.stringify(payload).to_utf8_buffer()
	var stage := "start_convo_stream"
	var result = await _perform_sse_request(stage, "start_convo_stream", headers, body, submitted_ms, npc)
	is_start_convo_in_flight = false
	if bool(result.get("ok", false)) == false:
		pending_start_npc = null
		return

	var npc_text := str(result.get("npc_text", ""))
	var actions: Array[String] = _to_string_array(result.get("actions", []))
	var action_payload := _extract_action_payload_from_stream_result(result, actions, npc_text)
	if action_payload.has("action"):
		_apply_action_to_npc(npc, action_payload)
		action_received.emit(str(action_payload["action"]), action_payload)
	conversation_started.emit(_get_npc_id(npc), npc_text, actions)
	_emit_state("start_convo_done")
	pending_start_npc = null

func _run_talk_stream_request(body: PackedByteArray, boundary: String, npc: Node, submitted_ms: int) -> void:
	var headers := PackedStringArray([
		"Content-Type: multipart/form-data; boundary=" + boundary,
		"Accept: text/event-stream, application/json"
	])
	var stage := "talk_stream"
	var result = await _perform_sse_request(stage, "talk_stream", headers, body, submitted_ms, npc)
	is_dialogue_in_flight = false
	if bool(result.get("ok", false)) == false:
		pending_dialogue_npc = null
		return

	var npc_text := str(result.get("npc_text", ""))
	var actions: Array[String] = _to_string_array(result.get("actions", []))
	var action_payload := _extract_action_payload_from_stream_result(result, actions, npc_text)
	if action_payload.has("action"):
		_apply_action_to_npc(npc, action_payload)
		action_received.emit(str(action_payload["action"]), action_payload)

	dialogue_turn_completed.emit(_get_npc_id(npc), npc_text, actions, action_payload)
	_emit_state("turn_done")
	pending_dialogue_npc = null

func _perform_sse_request(stage: String, controller: String, headers: PackedStringArray, body: PackedByteArray, submitted_ms: int, npc: Node) -> Dictionary:
	var info := _parse_http_url(_controller_url(controller))
	if bool(info.get("ok", false)) == false:
		_emit_backend_error(stage, "URL parse edilemedi.", -1, -1)
		return {"ok": false}

	var client := HTTPClient.new()
	var connect_err = await _connect_http_client(client, info)
	if connect_err != OK:
		_emit_backend_error(stage, "Baglanti kurulamadi.", -1, connect_err)
		return {"ok": false}

	var request_path := str(info["path"])
	var req_err := client.request_raw(HTTPClient.METHOD_POST, request_path, headers, body)
	if req_err != OK:
		_emit_backend_error(stage, "SSE request baslatilamadi.", -1, req_err)
		return {"ok": false}

	var wait_err = await _wait_for_http_status(client, HTTPClient.STATUS_BODY)
	if wait_err != OK:
		_emit_backend_error(stage, "SSE response alinmadi.", -1, wait_err)
		return {"ok": false}

	var code := client.get_response_code()
	if code < 200 or code >= 300:
		_emit_backend_error(stage, "HTTP hata kodu.", code, -1)
		return {"ok": false}

	var result := {
		"ok": true,
		"npc_text": "",
		"actions": [],
		"first_audio_reported": false,
		"submitted_ms": submitted_ms,
		"sample_rate": 16000,
		"channels": 1,
		"bits_per_sample": 16,
		"audio_buffer": PackedByteArray()
	}
	var sse_buffer := ""

	while client.get_status() == HTTPClient.STATUS_BODY:
		var poll_err := client.poll()
		if poll_err != OK:
			_emit_backend_error(stage, "SSE poll hatasi.", code, poll_err)
			return {"ok": false}

		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			sse_buffer += chunk.get_string_from_utf8()
			sse_buffer = _consume_sse_blocks(stage, sse_buffer, result, npc)

		await get_tree().process_frame

	# Any trailing block (if stream ended without final double newline)
	if sse_buffer.strip_edges() != "":
		_handle_sse_block(stage, sse_buffer, result, npc)

	return result

func _consume_sse_blocks(stage: String, buffer: String, state: Dictionary, npc: Node) -> String:
	var mutable := buffer
	while true:
		var sep := mutable.find("\n\n")
		if sep < 0:
			break
		var block := mutable.substr(0, sep)
		mutable = mutable.substr(sep + 2)
		_handle_sse_block(stage, block, state, npc)
	return mutable

func _handle_sse_block(stage: String, block: String, state: Dictionary, npc: Node) -> void:
	var data_json := _sse_data_json(block)
	if data_json == "":
		return

	var parsed = JSON.parse_string(data_json)
	if typeof(parsed) != TYPE_DICTIONARY:
		return

	var event_type := str(parsed.get("type", ""))
	if event_type == "metadata":
		state["npc_text"] = str(parsed.get("npc_text", ""))
		state["actions"] = _to_string_array(parsed.get("actions", []))
		var action_name := str(parsed.get("action", "")).strip_edges()
		if action_name != "":
			state["action"] = action_name
			var action_arr: Array[String] = _to_string_array(state.get("actions", []))
			if action_arr.has(action_name) == false:
				action_arr.append(action_name)
			state["actions"] = action_arr
		if parsed.has("price"):
			state["price"] = float(parsed.get("price", 0.0))
		if parsed.has("mood"):
			state["mood"] = str(parsed.get("mood", ""))
		if parsed.has("note"):
			state["note"] = str(parsed.get("note", ""))
		if parsed.has("sample_rate"):
			state["sample_rate"] = int(parsed["sample_rate"])
		if parsed.has("channels"):
			state["channels"] = int(parsed["channels"])
		if parsed.has("bits_per_sample"):
			state["bits_per_sample"] = int(parsed["bits_per_sample"])
		return

	if event_type == "done":
		# Backend stream'de asil action/price/mood/note done event'inde geliyor.
		if parsed.has("npc_text"):
			state["npc_text"] = str(parsed.get("npc_text", ""))
		var done_action := str(parsed.get("action", "")).strip_edges()
		if done_action != "":
			state["action"] = done_action
			var done_actions: Array[String] = _to_string_array(state.get("actions", []))
			if done_actions.has(done_action) == false:
				done_actions.append(done_action)
			state["actions"] = done_actions
		if parsed.has("price"):
			state["price"] = float(parsed.get("price", 0.0))
		if parsed.has("mood"):
			state["mood"] = str(parsed.get("mood", ""))
		if parsed.has("note"):
			state["note"] = str(parsed.get("note", ""))
		return

	if event_type == "audio":
		var audio_b64 := str(parsed.get("audio", ""))
		if audio_b64 == "":
			return
		var pcm_chunk := Marshalls.base64_to_raw(audio_b64)
		if pcm_chunk.is_empty():
			return

		if bool(state.get("first_audio_reported", false)) == false:
			state["first_audio_reported"] = true
			var latency_ms := float(Time.get_ticks_msec() - int(state.get("submitted_ms", Time.get_ticks_msec())))
			stream_first_audio_latency.emit(stage, latency_ms)

		state["audio_buffer"].append_array(pcm_chunk)

		# Try low-latency playback by playing each chunk as soon as it arrives.
		var wav_chunk := _pcm16_to_wav(
			pcm_chunk,
			int(state.get("sample_rate", 16000)),
			int(state.get("channels", 1)),
			int(state.get("bits_per_sample", 16))
		)
		_play_or_queue_npc_voice(npc, wav_chunk, stage)
		return

	if event_type == "error":
		_emit_backend_error(stage, str(parsed.get("error", "Bilinmeyen stream hatasi")), -1, -1)

func _connect_http_client(client: HTTPClient, info: Dictionary):
	var host := str(info["host"])
	var port := int(info["port"])
	var use_tls := bool(info["use_tls"])
	var err := OK
	if use_tls:
		err = client.connect_to_host(host, port, TLSOptions.client())
	else:
		err = client.connect_to_host(host, port)
	if err != OK:
		return err
	return await _wait_for_http_status(client, HTTPClient.STATUS_CONNECTED)

func _wait_for_http_status(client: HTTPClient, target_status: int):
	var timeout_ms := int(request_timeout_sec * 1000.0)
	var start_ms := Time.get_ticks_msec()
	while true:
		var err := client.poll()
		if err != OK:
			return err
		var status := client.get_status()
		if status == target_status:
			return OK
		if status == HTTPClient.STATUS_DISCONNECTED:
			return ERR_CONNECTION_ERROR
		if Time.get_ticks_msec() - start_ms > timeout_ms:
			return ERR_TIMEOUT
		await get_tree().process_frame

func _parse_http_url(url: String) -> Dictionary:
	var s := url.strip_edges()
	var use_tls := false
	if s.begins_with("https://"):
		use_tls = true
		s = s.substr(8)
	elif s.begins_with("http://"):
		s = s.substr(7)

	var slash := s.find("/")
	var host_port := s
	var path := "/"
	if slash >= 0:
		host_port = s.substr(0, slash)
		path = s.substr(slash)

	var host := host_port
	var port := 443 if use_tls else 80
	var colon := host_port.find(":")
	if colon >= 0:
		host = host_port.substr(0, colon)
		port = int(host_port.substr(colon + 1))

	if host == "":
		return {"ok": false}
	return {
		"ok": true,
		"host": host,
		"port": port,
		"path": path,
		"use_tls": use_tls
	}

func _create_chunk_session_id() -> String:
	return "sess_" + str(Time.get_unix_time_from_system()) + "_" + str(Time.get_ticks_usec())

func _extract_boundary_from_multipart(body: PackedByteArray) -> String:
	var head_text := body.slice(0, min(body.size(), 200)).get_string_from_utf8()
	var first_line_end := head_text.find("\r\n")
	if first_line_end < 0:
		return ""
	var first_line := head_text.substr(0, first_line_end)
	if first_line.begins_with("--"):
		return first_line.substr(2)
	return ""

func _on_story_init_done(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _check_http_ok("enter_knowledgebase", result, response_code) == false:
		return
	_emit_state("story_ready")

func _on_start_convo_done(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	is_start_convo_in_flight = false
	if _check_http_ok("start_convo", result, response_code) == false:
		pending_start_npc = null
		return
	if pending_start_npc == null:
		return

	var npc_text := ""
	var actions: Array[String] = []
	var wav_bytes := PackedByteArray()
	var action_payload := {}

	if _is_event_stream_response(headers):
		var stream_payload := _extract_stream_talk_payload(body)
		wav_bytes = stream_payload.get("wav_bytes", PackedByteArray())
		npc_text = str(stream_payload.get("npc_text", ""))
		actions = _to_string_array(stream_payload.get("actions", []))
		action_payload = _extract_action_payload_from_stream_result(stream_payload, actions, npc_text)
	else:
		wav_bytes = _extract_wav_bytes(headers, body)
		npc_text = _header_value(headers, "x-npc-response-text")
		actions = _extract_actions(headers, npc_text)
		action_payload = _extract_action_payload_from_headers(headers, actions, npc_text)

	if wav_bytes.is_empty():
		_emit_backend_error("start_convo", "Cevapta oynatilabilir ses bulunamadi.", response_code, result)
		pending_start_npc = null
		return
	_play_npc_voice(pending_start_npc, wav_bytes, "start_convo")

	if action_payload.has("action"):
		_apply_action_to_npc(pending_start_npc, action_payload)
		action_received.emit(str(action_payload["action"]), action_payload)

	conversation_started.emit(_get_npc_id(pending_start_npc), npc_text, actions)
	_emit_state("start_convo_done")
	pending_start_npc = null

func _on_dialogue_done(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	is_dialogue_in_flight = false
	if _check_http_ok("talk", result, response_code) == false:
		pending_dialogue_npc = null
		return
	if pending_dialogue_npc == null:
		_emit_backend_error("talk", "Pending NPC yok.", response_code, result)
		return

	var npc_text := ""
	var actions: Array[String] = []
	var wav_bytes := PackedByteArray()
	var action_payload := {}

	if _is_event_stream_response(headers):
		var stream_payload := _extract_stream_talk_payload(body)
		wav_bytes = stream_payload.get("wav_bytes", PackedByteArray())
		npc_text = str(stream_payload.get("npc_text", ""))
		actions = _to_string_array(stream_payload.get("actions", []))
		action_payload = _extract_action_payload_from_stream_result(stream_payload, actions, npc_text)
	else:
		wav_bytes = _extract_wav_bytes(headers, body)
		npc_text = _header_value(headers, "x-npc-response-text")
		actions = _extract_actions(headers, npc_text)
		action_payload = _extract_action_payload_from_headers(headers, actions, npc_text)

	if wav_bytes.is_empty():
		_emit_backend_error("talk", "Cevapta oynatilabilir ses bulunamadi.", response_code, result)
		pending_dialogue_npc = null
		return
	_play_npc_voice(pending_dialogue_npc, wav_bytes, "talk")

	if action_payload.has("action"):
		_apply_action_to_npc(pending_dialogue_npc, action_payload)
		action_received.emit(str(action_payload["action"]), action_payload)

	dialogue_turn_completed.emit(_get_npc_id(pending_dialogue_npc), npc_text, actions, action_payload)
	_emit_state("turn_done")
	pending_dialogue_npc = null

func _on_health_done(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _check_http_ok("health", result, response_code):
		_emit_state("health_ok")

func _play_npc_voice(npc: Node, wav_bytes: PackedByteArray, stage: String) -> void:
	if npc.has_method("play_wav_bytes"):
		var ok = bool(npc.call("play_wav_bytes", wav_bytes))
		if ok == false:
			_emit_backend_error(stage, "NPC sesi oynatamadi.", -1, -1)
	else:
		_emit_backend_error(stage, "NPC'de play_wav_bytes metodu yok.", -1, -1)

func _play_or_queue_npc_voice(npc: Node, wav_bytes: PackedByteArray, stage: String) -> void:
	if npc != null and npc.has_method("enqueue_wav_bytes"):
		var ok = bool(npc.call("enqueue_wav_bytes", wav_bytes))
		if ok == false:
			_emit_backend_error(stage, "NPC sesi queue'ya eklenemedi.", -1, -1)
		return
	_play_npc_voice(npc, wav_bytes, stage)

func _apply_action_to_npc(npc: Node, payload: Dictionary) -> void:
	if npc == null:
		return
	if npc.has_method("apply_action"):
		npc.call("apply_action", str(payload.get("action", "")), payload)

func _extract_actions(headers: PackedStringArray, npc_text: String) -> Array[String]:
	var out: Array[String] = []

	var single_action := _header_value(headers, "x-npc-action").strip_edges()
	if single_action != "" and out.has(single_action) == false:
		out.append(single_action)

	var action_header := _header_value(headers, "x-npc-actions").strip_edges()
	if action_header != "":
		var parts := action_header.split(",", false)
		for item in parts:
			var v := str(item).strip_edges()
			if v != "" and out.has(v) == false:
				out.append(v)

	var parsed := _parse_action_line(npc_text)
	if parsed.has("action"):
		var action_name := str(parsed["action"]).strip_edges()
		if action_name != "" and out.has(action_name) == false:
			out.append(action_name)
	return out

func _extract_action_payload_from_headers(headers: PackedStringArray, actions: Array[String], npc_text: String) -> Dictionary:
	var payload := {}
	var action_name := _header_value(headers, "x-npc-action").strip_edges()
	if action_name == "" and actions.is_empty() == false:
		action_name = actions[0]
	if action_name != "":
		payload["action"] = action_name

	var price_header := _header_value(headers, "x-npc-price").strip_edges()
	if price_header != "":
		payload["price"] = price_header.to_float()
	var mood_header := _header_value(headers, "x-npc-mood").strip_edges()
	if mood_header != "":
		payload["mood"] = mood_header
	var note_header := _header_value(headers, "x-npc-note").strip_edges()
	if note_header != "":
		payload["note"] = note_header.uri_decode()

	var parsed_from_text := _extract_primary_action_payload(actions, npc_text)
	if payload.has("action") == false and parsed_from_text.has("action"):
		payload["action"] = parsed_from_text["action"]
	if payload.has("price") == false and parsed_from_text.has("price"):
		payload["price"] = parsed_from_text["price"]
	if payload.has("mood") == false and parsed_from_text.has("mood"):
		payload["mood"] = parsed_from_text["mood"]
	if payload.has("note") == false and parsed_from_text.has("note"):
		payload["note"] = parsed_from_text["note"]
	return payload

func _extract_action_payload_from_stream_result(stream_result: Dictionary, actions: Array[String], npc_text: String) -> Dictionary:
	var payload := {}
	var action_name := str(stream_result.get("action", "")).strip_edges()
	if action_name == "" and actions.is_empty() == false:
		action_name = actions[0]
	if action_name != "":
		payload["action"] = action_name
	if stream_result.has("price"):
		payload["price"] = float(stream_result.get("price", 0.0))
	var mood := str(stream_result.get("mood", "")).strip_edges()
	if mood != "":
		payload["mood"] = mood
	var note := str(stream_result.get("note", "")).strip_edges()
	if note != "":
		payload["note"] = note

	var parsed_from_text := _extract_primary_action_payload(actions, npc_text)
	if payload.has("action") == false and parsed_from_text.has("action"):
		payload["action"] = parsed_from_text["action"]
	if payload.has("price") == false and parsed_from_text.has("price"):
		payload["price"] = parsed_from_text["price"]
	if payload.has("mood") == false and parsed_from_text.has("mood"):
		payload["mood"] = parsed_from_text["mood"]
	if payload.has("note") == false and parsed_from_text.has("note"):
		payload["note"] = parsed_from_text["note"]
	return payload

func _extract_primary_action_payload(actions: Array[String], npc_text: String) -> Dictionary:
	var parsed := _parse_action_line(npc_text)
	if parsed.has("action") == false and actions.is_empty() == false:
		parsed["action"] = actions[0]
	return parsed

func _parse_action_line(text: String) -> Dictionary:
	var out := {}
	var normalized_text := text
	if normalized_text.find("<novoice>") >= 0 and normalized_text.find("</novoice>") >= 0:
		var start := normalized_text.find("<novoice>")
		var end := normalized_text.find("</novoice>")
		if end > start:
			normalized_text = normalized_text.substr(start + 9, end - (start + 9)).strip_edges()
	var lines := normalized_text.split("\n", false)
	for i in range(lines.size() - 1, -1, -1):
		var line := str(lines[i]).strip_edges()
		var lower_line := line.to_lower()
		if lower_line.find("action:") < 0:
			continue
		if lower_line.begins_with("action:") == false:
			var idx := lower_line.find("action:")
			line = line.substr(idx).strip_edges()
		var segments := line.split("|", false)
		for segment in segments:
			var kv := str(segment).split(":", false, 1)
			if kv.size() != 2:
				continue
			var key := str(kv[0]).strip_edges().to_lower()
			var value := str(kv[1]).strip_edges()
			if key == "action":
				out["action"] = value
			elif key == "price":
				out["price"] = value.to_float()
			elif key == "mood":
				out["mood"] = value
			elif key == "note":
				out["note"] = value
		break
	return out

func _header_value(headers: PackedStringArray, header_name: String) -> String:
	var needle := header_name.to_lower() + ":"
	for h in headers:
		var line := str(h)
		var lower := line.to_lower()
		if lower.begins_with(needle):
			return line.substr(needle.length()).strip_edges()
	return ""

func _check_http_ok(stage: String, result: int, response_code: int) -> bool:
	if result != HTTPRequest.RESULT_SUCCESS:
		_emit_backend_error(stage, "Baglanti hatasi.", response_code, result)
		return false
	if response_code < 200 or response_code >= 300:
		_emit_backend_error(stage, "HTTP hata kodu.", response_code, result)
		return false
	return true

func _emit_backend_error(stage: String, message: String, http_code: int, result_code: int) -> void:
	push_warning("VoiceSystem[%s] %s (http=%s, result=%s)" % [stage, message, str(http_code), str(result_code)])
	backend_error.emit(stage, message, http_code, result_code)

func _emit_state(state: String) -> void:
	wrapper_state_changed.emit(state)

func _controller_url(controller_name: String) -> String:
	var path := str(BACKEND_CONTROLLERS.get(controller_name, ""))
	if path == "":
		_emit_backend_error("controller_map", "Bilinmeyen backend controller: " + controller_name, -1, -1)
		return backend_base_url

	var base := backend_base_url.strip_edges()
	if base.ends_with("/"):
		base = base.substr(0, base.length() - 1)

	if path.begins_with("/") == false:
		path = "/" + path

	return base + path

func _build_story_payload() -> Dictionary:
	if ResourceLoader.exists(story_database_path) == false:
		push_warning("VoiceSystem: story database bulunamadi: " + story_database_path)
		return {}

	var db = load(story_database_path)
	if db == null:
		push_warning("VoiceSystem: story database yuklenemedi.")
		return {}

	var payload: Dictionary = {
		"main_story": "",
		"npcs": []
	}

	if "main_story" in db:
		payload["main_story"] = str(db.main_story)

	var npc_items: Array = []
	if "npcs" in db:
		for npc in db.npcs:
			if npc == null:
				continue
			var item: Dictionary = {
				"id": "",
				"name": "",
				"voice": "",
				"backstory": "",
				"personality": "",
				"goals": [],
				"secrets": [],
				"system_prompt": "",
				"actions": []
			}
			if "npc_id" in npc:
				item["id"] = str(npc.npc_id)
			if "display_name" in npc:
				item["name"] = str(npc.display_name)
			if "voice" in npc:
				item["voice"] = str(npc.voice)
			if "backstory" in npc:
				item["backstory"] = str(npc.backstory)
			if "personality" in npc:
				item["personality"] = str(npc.personality)
			if "goals" in npc:
				item["goals"] = _to_string_array(npc.goals)
			if "secrets" in npc:
				item["secrets"] = _to_string_array(npc.secrets)
			if "system_prompt" in npc:
				item["system_prompt"] = str(npc.system_prompt)
			if "actions" in npc:
				item["actions"] = _to_string_array(npc.actions)
			npc_items.append(item)

	payload["npcs"] = npc_items
	return payload

func _append_form_field(body: PackedByteArray, boundary: String, key: String, value: String) -> void:
	var part := ""
	part += "--" + boundary + "\r\n"
	part += "Content-Disposition: form-data; name=\"" + key + "\"\r\n\r\n"
	part += value + "\r\n"
	body.append_array(part.to_utf8_buffer())

func _append_form_file(body: PackedByteArray, boundary: String, key: String, filename: String, content_type: String, data: PackedByteArray) -> void:
	var head := ""
	head += "--" + boundary + "\r\n"
	head += "Content-Disposition: form-data; name=\"" + key + "\"; filename=\"" + filename + "\"\r\n"
	head += "Content-Type: " + content_type + "\r\n\r\n"
	body.append_array(head.to_utf8_buffer())
	body.append_array(data)
	body.append_array("\r\n".to_utf8_buffer())

func _get_content_type(headers: PackedStringArray) -> String:
	for h in headers:
		var s := str(h)
		var lower := s.to_lower()
		if lower.begins_with("content-type:"):
			return s.substr(13).strip_edges()
	return ""

func _to_string_array(value) -> Array[String]:
	var out: Array[String] = []

	if typeof(value) == TYPE_ARRAY:
		for v in value:
			var s := str(v).strip_edges()
			if s != "":
				out.append(s)
		return out

	var text := str(value).strip_edges()
	if text == "":
		return out

	var blocks := text.split("\n\n", false)
	if blocks.size() > 1:
		for b in blocks:
			var s := str(b).strip_edges()
			if s != "":
				out.append(s)
		return out

	var lines := text.split("\n", false)
	for line in lines:
		var s := str(line).strip_edges()
		if s == "":
			continue
		if s.begins_with("- "):
			s = s.substr(2).strip_edges()
		out.append(s)

	return out

func _extract_wav_bytes(headers: PackedStringArray, body: PackedByteArray) -> PackedByteArray:
	var content_type := _get_content_type(headers).to_lower()
	if content_type.find("audio/wav") >= 0 or (body.size() >= 12 and body.slice(0, 4).get_string_from_ascii() == "RIFF"):
		return body

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("audio_base64"):
		return Marshalls.base64_to_raw(str(parsed["audio_base64"]))

	return PackedByteArray()

func _is_event_stream_response(headers: PackedStringArray) -> bool:
	var content_type := _get_content_type(headers).to_lower()
	return content_type.find("text/event-stream") >= 0

func _extract_stream_talk_payload(body: PackedByteArray) -> Dictionary:
	var result := {
		"npc_text": "",
		"actions": [],
		"wav_bytes": PackedByteArray()
	}
	if body.is_empty():
		return result

	var text := body.get_string_from_utf8()
	var events := text.split("\n\n", false)
	var pcm := PackedByteArray()

	for block in events:
		var data_json := _sse_data_json(block)
		if data_json == "":
			continue

		var parsed = JSON.parse_string(data_json)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue

		var event_type := str(parsed.get("type", ""))
		if event_type == "metadata":
			result["npc_text"] = str(parsed.get("npc_text", ""))
			var parsed_actions = parsed.get("actions", [])
			if typeof(parsed_actions) == TYPE_ARRAY:
				result["actions"] = _to_string_array(parsed_actions)
		elif event_type == "audio":
			var audio_b64 := str(parsed.get("audio", ""))
			if audio_b64 != "":
				pcm.append_array(Marshalls.base64_to_raw(audio_b64))
		elif event_type == "error":
			_emit_backend_error("talk_stream", str(parsed.get("error", "Bilinmeyen stream hatasi")), -1, -1)

	if pcm.is_empty() == false:
		result["wav_bytes"] = _pcm16_to_wav(pcm, 16000, 1, 16)
	return result

func _sse_data_json(block: String) -> String:
	var lines := block.split("\n", false)
	var chunks: Array[String] = []
	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed.begins_with("data:") == false:
			continue
		chunks.append(trimmed.substr(5).strip_edges())
	if chunks.is_empty():
		return ""
	return "\n".join(chunks)

func _pcm16_to_wav(pcm: PackedByteArray, sample_rate: int, channels: int, bits_per_sample: int) -> PackedByteArray:
	var byte_rate = sample_rate * channels * int(bits_per_sample / 8)
	var block_align = channels * int(bits_per_sample / 8)
	var data_size = pcm.size()
	var riff_size = 36 + data_size

	var out = PackedByteArray()
	out.append_array("RIFF".to_ascii_buffer())
	out.append_array(_u32le(riff_size))
	out.append_array("WAVE".to_ascii_buffer())
	out.append_array("fmt ".to_ascii_buffer())
	out.append_array(_u32le(16))
	out.append_array(_u16le(1))
	out.append_array(_u16le(channels))
	out.append_array(_u32le(sample_rate))
	out.append_array(_u32le(byte_rate))
	out.append_array(_u16le(block_align))
	out.append_array(_u16le(bits_per_sample))
	out.append_array("data".to_ascii_buffer())
	out.append_array(_u32le(data_size))
	out.append_array(pcm)
	return out

func _u16le(v: int) -> PackedByteArray:
	return PackedByteArray([v & 0xFF, (v >> 8) & 0xFF])

func _u32le(v: int) -> PackedByteArray:
	return PackedByteArray([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])

func _get_npc_id(npc: Node) -> String:
	if npc.has_method("get_npc_id"):
		return str(npc.call("get_npc_id"))
	if "npc_id" in npc:
		return str(npc.npc_id)
	return ""

func _get_npc_start_instruction(npc: Node) -> String:
	if npc.has_method("get_start_instruction"):
		return str(npc.call("get_start_instruction")).strip_edges()
	if "start_instruction" in npc:
		return str(npc.start_instruction).strip_edges()
	return ""
