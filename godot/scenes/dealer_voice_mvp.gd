extends Node3D

@onready var voice_system: Node = $VoiceSystem
@onready var voice_recorder: Node = $VoiceRecorder

@onready var camera: Camera3D = $Camera3D
@onready var npc_a_marker: Marker3D = $NpcA
@onready var npc_b_marker: Marker3D = $NpcB
@onready var state_label: Label = $UI/Panel/Root/StateLabel
@onready var turn_label: Label = $UI/Panel/Root/TurnLabel
@onready var queue_label: Label = $UI/Panel/Root/QueueLabel
@onready var latency_label: Label = $UI/Panel/Root/LatencyLabel
@onready var npc_text_label: RichTextLabel = $UI/Panel/Root/NPCText
@onready var action_label: Label = $UI/Panel/Root/ActionLabel
@onready var price_label: Label = $UI/Panel/Root/PriceLabel
@onready var hold_button: Button = $UI/Panel/Root/Buttons/HoldToTalk
@onready var start_button: Button = $UI/Panel/Root/Buttons/StartConversation

@export var auto_approach_speed := 5.0
@export var interaction_distance := 4.0
@export var turn_advance_delay_sec := 1.0
@export var starting_cash := 10000.0
@export var camera_height_offset := 1.8
@export var camera_distance_offset := 3.8

var npc_queue: Array[Node3D] = []
var active_npc: Node3D = null
var current_npc_index := -1
var has_started_convo_for_current_npc := false
var has_bought_current_npc := false
var turn_status := "idle"
var queued_advance_at_msec := 0
var completed_npcs: Array[Node3D] = []
var deals_count := 0
var fails_count := 0
var spent_total := 0.0
var cash_left := 0.0
var last_latency_ms := -1.0

func _ready() -> void:
	_collect_scene_npcs()
	if npc_queue.is_empty():
		state_label.text = "No NPCs in queue."
		start_button.disabled = true
		return

	var ok: bool = bool(voice_system.call("configure_runtime", voice_recorder, npc_queue[0]))
	if ok == false:
		state_label.text = "Runtime bind failed"
		return

	voice_system.call("push_story_database")
	_connect_runtime_signals()
	_connect_npc_signals()
	_connect_recorder_signals()
	cash_left = starting_cash
	hold_button.disabled = true
	hold_button.text = "PTT Key: hold 'ptt' action"
	_set_turn_status("idle")
	_align_camera_to_active_npc()
	_update_ui()

func _process(delta: float) -> void:
	_process_auto_camera_approach(delta)
	_process_proximity_auto_start()
	_process_scheduled_advance()

func _on_start_pressed() -> void:
	start_button.disabled = true
	deals_count = 0
	fails_count = 0
	spent_total = 0.0
	cash_left = starting_cash
	last_latency_ms = -1.0
	current_npc_index = -1
	active_npc = null
	has_started_convo_for_current_npc = false
	has_bought_current_npc = false
	queued_advance_at_msec = 0
	completed_npcs.clear()
	_activate_next_npc()

func _connect_runtime_signals() -> void:
	voice_system.connect("wrapper_state_changed", Callable(self, "_on_wrapper_state_changed"))
	voice_system.connect("backend_error", Callable(self, "_on_backend_error"))
	voice_system.connect("conversation_started", Callable(self, "_on_conversation_started"))
	voice_system.connect("dialogue_turn_completed", Callable(self, "_on_dialogue_turn_completed"))
	voice_system.connect("action_received", Callable(self, "_on_action_received"))
	voice_system.connect("stream_first_audio_latency", Callable(self, "_on_stream_first_audio_latency"))

func _connect_npc_signals() -> void:
	for npc in npc_queue:
		npc.connect("offer_changed", Callable(self, "_on_offer_changed"))
		npc.connect("negotiation_state_changed", Callable(self, "_on_negotiation_state_changed"))

func _connect_recorder_signals() -> void:
	voice_recorder.connect("recording_started", Callable(self, "_on_recording_started"))
	voice_recorder.connect("recording_stopped", Callable(self, "_on_recording_stopped"))

func _on_wrapper_state_changed(state: String) -> void:
	state_label.text = "State: " + state
	_update_ui()

func _on_backend_error(stage: String, message: String, http_code: int, _result_code: int) -> void:
	state_label.text = "Error[" + stage + "] " + message + " (http=" + str(http_code) + ")"
	_update_ui()

func _on_conversation_started(_npc_id: String, npc_text: String, actions: Array[String]) -> void:
	npc_text_label.text = npc_text.uri_decode()
	action_label.text = "Actions: " + (", ".join(actions) if actions.is_empty() == false else "-")
	_set_turn_status("negotiating")
	_update_ui()
	_refresh_price()

func _on_dialogue_turn_completed(_npc_id: String, npc_text: String, actions: Array[String], action_payload: Dictionary) -> void:
	npc_text_label.text = npc_text.uri_decode()
	action_label.text = "Actions: " + (", ".join(actions) if actions.is_empty() == false else "-")
	if action_payload.has("action"):
		action_label.text += " | Primary: " + str(action_payload["action"])
	_update_ui()
	_refresh_price()

func _on_action_received(action_name: String, payload: Dictionary) -> void:
	var mood: String = str(payload.get("mood", ""))
	if mood != "":
		action_label.text = "Action: " + action_name + " | Mood: " + mood
	else:
		action_label.text = "Action: " + action_name
	_dispatch_action(action_name, payload)
	_update_ui()

func _on_offer_changed(_value: float) -> void:
	_refresh_price()
	_update_ui()

func _on_negotiation_state_changed(state: String) -> void:
	state_label.text = "Negotiation: " + state
	_update_ui()

func _on_recording_started() -> void:
	state_label.text = "Recording..."
	_update_ui()

func _on_recording_stopped(_wav: PackedByteArray, _filename: String) -> void:
	state_label.text = "Sending voice..."
	_update_ui()

func _on_stream_first_audio_latency(stage: String, latency_ms: float) -> void:
	last_latency_ms = latency_ms
	latency_label.text = "%s first audio: %.1f ms" % [stage, latency_ms]
	_update_ui()

func _refresh_price() -> void:
	if active_npc == null:
		price_label.text = "Current Price: - | State: idle"
		return
	var price: float = float(active_npc.call("get_current_price"))
	var n_state: String = str(active_npc.call("get_negotiation_state"))
	price_label.text = "Current Price: " + str(snappedf(price, 1.0)) + " | State: " + n_state

func _collect_scene_npcs() -> void:
	npc_queue.clear()
	for n in get_tree().get_nodes_in_group("voice_npc"):
		if n is Node3D:
			npc_queue.append(n)
	npc_queue.sort_custom(func(a: Node3D, b: Node3D): return a.name < b.name)

func _activate_next_npc() -> void:
	active_npc = _nearest_remaining_npc()
	current_npc_index = completed_npcs.size()
	if active_npc == null:
		_set_turn_status("day_complete")
		state_label.text = "Day complete. Bought: %d/%d | Spent: %.0f | Cash left: %.0f" % [deals_count, npc_queue.size(), spent_total, cash_left]
		start_button.disabled = false
		_update_ui()
		return

	has_bought_current_npc = false
	has_started_convo_for_current_npc = false
	queued_advance_at_msec = 0
	if active_npc.has_method("clear_audio_queue"):
		active_npc.call("clear_audio_queue")
	voice_system.call("set_active_npc", active_npc)
	_set_turn_status("go_to_npc")
	state_label.text = "Go near NPC: " + str(active_npc.call("get_npc_id"))
	_align_camera_to_active_npc()
	_update_ui()
	_refresh_price()

func _process_auto_camera_approach(delta: float) -> void:
	if active_npc == null:
		return
	if turn_status != "go_to_npc":
		return

	var target := _get_camera_target_for_current_turn()
	var next_pos := camera.global_position
	var move_step := auto_approach_speed * delta
	if current_npc_index == 0:
		# First target: move only on Z axis.
		next_pos.z = move_toward(next_pos.z, target.z, move_step)
	elif current_npc_index == 1:
		# Second target: move only on X axis.
		next_pos.x = move_toward(next_pos.x, target.x, move_step)
	else:
		next_pos = next_pos.move_toward(target, move_step)
	camera.global_position = next_pos
	_align_camera_to_active_npc()

func _process_proximity_auto_start() -> void:
	if active_npc == null:
		return
	if turn_status != "go_to_npc":
		return
	var proximity_target := _get_proximity_target_for_current_turn()
	var to_npc := proximity_target - camera.global_position
	to_npc.y = 0.0
	var horizontal_dist := to_npc.length()
	var trigger_dist = max(interaction_distance, camera_distance_offset + 0.3)
	if horizontal_dist <= trigger_dist and has_started_convo_for_current_npc == false:
		has_started_convo_for_current_npc = true
		var ok: bool = bool(voice_system.call("begin_single_npc_loop", active_npc))
		if ok:
			_set_turn_status("starting_convo")
			state_label.text = "Starting conversation..."
		else:
			state_label.text = "Start failed for NPC"
		_update_ui()

func _dispatch_action(action_name: String, payload: Dictionary) -> void:
	var action := action_name.strip_edges().to_lower()
	if action == "":
		return

	match action:
		"greet":
			_set_turn_status("greet")
		"pitch":
			_set_turn_status("pitch")
		"haggle":
			_set_turn_status("countering")
		"agree":
			_finalize_purchase(payload)
		"reject", "leave":
			fails_count += 1
			_queue_turn_advance("No deal")
		_:
			_set_turn_status("negotiating")

	if payload.has("note"):
		var note := str(payload["note"]).strip_edges()
		if note != "":
			action_label.text += " | Note: " + note

func _finalize_purchase(payload: Dictionary) -> void:
	if has_bought_current_npc:
		return
	var price := _extract_price(payload)
	if price <= 0.0 and active_npc != null:
		price = float(active_npc.call("get_current_price"))

	if price > cash_left:
		fails_count += 1
		_queue_turn_advance("Not enough cash for deal (%.0f)" % price)
		return

	cash_left -= price
	spent_total += price
	deals_count += 1
	has_bought_current_npc = true
	_queue_turn_advance("Bought for %.0f" % price)

func _extract_price(payload: Dictionary) -> float:
	if payload.has("price"):
		return float(payload["price"])
	return 0.0

func _queue_turn_advance(reason: String) -> void:
	if active_npc != null and completed_npcs.has(active_npc) == false:
		completed_npcs.append(active_npc)
	_set_turn_status("finished")
	state_label.text = "%s. Next NPC..." % reason
	queued_advance_at_msec = Time.get_ticks_msec() + int(turn_advance_delay_sec * 1000.0)
	has_started_convo_for_current_npc = true

func _process_scheduled_advance() -> void:
	if queued_advance_at_msec <= 0:
		return
	if Time.get_ticks_msec() < queued_advance_at_msec:
		return
	queued_advance_at_msec = 0
	_activate_next_npc()

func _set_turn_status(next_status: String) -> void:
	turn_status = next_status
	turn_label.text = "Turn: " + next_status

func _update_ui() -> void:
	var total := npc_queue.size()
	var current := current_npc_index + 1
	var npc_name := "-"
	var target_count = min(3, total)
	if active_npc != null:
		npc_name = str(active_npc.call("get_npc_id"))
	queue_label.text = "Goal: buy %d item(s) cheap\nNPC: %d/%d (%s)\nDeals: %d   Fails: %d\nCash: %.0f   Spent: %.0f" % [target_count, max(current, 0), total, npc_name, deals_count, fails_count, cash_left, spent_total]
	if last_latency_ms >= 0.0:
		latency_label.text = "Latency (first audio): %.1f ms" % last_latency_ms
	else:
		latency_label.text = "Latency (first audio): -"

func _align_camera_to_active_npc() -> void:
	if active_npc == null:
		return
	camera.look_at(active_npc.global_position, Vector3.UP)

func _get_camera_target_for_current_turn() -> Vector3:
	if current_npc_index == 0 and npc_a_marker != null:
		return npc_a_marker.global_position
	if current_npc_index == 1 and npc_b_marker != null:
		return npc_b_marker.global_position
	return active_npc.global_position + Vector3(0.0, camera_height_offset, camera_distance_offset)

func _get_proximity_target_for_current_turn() -> Vector3:
	if current_npc_index == 0 and npc_a_marker != null:
		return npc_a_marker.global_position
	if current_npc_index == 1 and npc_b_marker != null:
		return npc_b_marker.global_position
	return active_npc.global_position

func _nearest_remaining_npc() -> Node3D:
	var nearest: Node3D = null
	var nearest_dist := INF
	for npc in npc_queue:
		if completed_npcs.has(npc):
			continue
		var d := camera.global_position.distance_to(npc.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = npc
	return nearest
