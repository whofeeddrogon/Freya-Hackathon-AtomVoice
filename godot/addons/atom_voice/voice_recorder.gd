extends Node

@export var ptt_action = "ptt"
signal wav_ready(wav_bytes: PackedByteArray, filename: String)
signal wav_chunk_ready(wav_bytes: PackedByteArray, filename: String)
signal recording_started()
signal recording_stopped(wav_bytes: PackedByteArray, filename: String)
signal recording_level_changed(level: float, talking: bool)

# İstersen diske de kaydet:
@export var also_save_to_disk = false
@export var wav_save_path = "user://ptt_record.wav"

@export var record_bus_name = "Record"
@export var wav_filename = "ptt_record.wav"
@export var target_sample_rate = 16000
@export var use_input_ptt = true
@export var chunk_on_silence = true
@export var silence_split_sec = 0.36
@export var min_chunk_sec = 0.25
@export var min_avg_db_to_send = -42.0

# UI ayarları
@export var talking_threshold = 0.01
@export var meter_smooth_speed = 25.0
@export var meter_gain = 7.5

var mic_player = null
var mic_bar = null
var mic_label = null

var record_bus_idx = -1
var capture = null

var is_recording = false
var pcm_bytes = PackedByteArray()
var smoothed_level = 0.0

var resample_accum = 0.0
var silence_elapsed_sec = 0.0
var chunk_has_speech = false

func _ready():
	mic_player = get_node_or_null("MicPlayer")
	mic_bar = get_node_or_null("CanvasLayer/Panel/MicLevelBar")
	mic_label = get_node_or_null("CanvasLayer/Panel/MicLabel")

	# Record bus index
	record_bus_idx = AudioServer.get_bus_index(record_bus_name)
	if record_bus_idx == -1:
		push_error("Audio bus bulunamadı: " + record_bus_name + " (Audio panelinden ekle)")
		return

	# Capture effect bul
	var fx_count = AudioServer.get_bus_effect_count(record_bus_idx)
	var i = 0
	while i < fx_count:
		var fx = AudioServer.get_bus_effect(record_bus_idx, i)
		if fx is AudioEffectCapture:
			capture = fx
			break
		i += 1

	if capture == null:
		push_error("'" + record_bus_name + "' bus'ına AudioEffectCapture eklemelisin.")
		return

	# Kendi sesini duymamak için bus'ı mute et
	AudioServer.set_bus_mute(record_bus_idx, true)

	# MicPlayer ayarla
	if mic_player == null:
		push_error("MicPlayer node bulunamadı. VoiceRecorder altına AudioStreamPlayer ekleyip adını 'MicPlayer' yap.")
		return

	mic_player.stream = AudioStreamMicrophone.new()
	mic_player.bus = record_bus_name

	# UI başlangıç
	_update_ui(0.0)

func _process(delta):
	if capture == null:
		return

	# Push-to-talk (opsiyonel)
	if use_input_ptt:
		if Input.is_action_just_pressed(ptt_action):
			start_recording()

		if Input.is_action_just_released(ptt_action):
			stop_recording_and_emit()

	if is_recording:
		_drain_capture_to_pcm_and_meter(delta)
	else:
		# UI yavaşça sönsün
		smoothed_level = move_toward(smoothed_level, 0.0, meter_smooth_speed * delta)
		_update_ui(smoothed_level)

func start_recording():
	resample_accum = 0.0
	pcm_bytes = PackedByteArray()
	silence_elapsed_sec = 0.0
	chunk_has_speech = false
	capture.clear_buffer()
	is_recording = true
	recording_started.emit()

	if mic_player.playing == false:
		mic_player.play()

func stop_recording_and_emit():
	if is_recording == false:
		return

	is_recording = false

	# kalan buffer'ı da çek
	_drain_capture_to_pcm_and_meter(0.0)

	# push-to-talk mantığı: bırakınca mic'i durdur
	mic_player.stop()

	if pcm_bytes.size() == 0:
		if chunk_on_silence == false:
			push_warning("PCM boş. Mikrofon sesi capture'a gelmemiş olabilir.")
		recording_stopped.emit(PackedByteArray(), wav_filename)
		return
	if _passes_avg_db_threshold(pcm_bytes) == false:
		recording_stopped.emit(PackedByteArray(), wav_filename)
		return

	var wav = _make_wav(pcm_bytes, target_sample_rate, 1, 16)

	if also_save_to_disk:
		_save_wav_to_disk(wav, wav_save_path)

	wav_ready.emit(wav, wav_filename)
	recording_stopped.emit(wav, wav_filename)

func _start_recording():
	start_recording()

func _stop_and_send_wav():
	stop_recording_and_emit()

func _drain_capture_to_pcm_and_meter(delta):
	var available = capture.get_frames_available()
	if available <= 0:
		smoothed_level = move_toward(smoothed_level, 0.0, meter_smooth_speed * delta)
		_update_ui(smoothed_level)
		return

	var frames = capture.get_buffer(available) # PackedVector2Array

	# --- RMS meter ---
	var sum = 0.0
	var count = frames.size()
	var j = 0
	while j < count:
		var v = frames[j]
		var mono = (v.x + v.y) * 0.5
		sum += mono * mono
		j += 1

	var rms = 0.0
	if count > 0:
		rms = sqrt(sum / float(count))

	var level = rms * meter_gain
	level = clamp(level, 0.0, 1.0)

	# smoothing
	smoothed_level = lerp(smoothed_level, level, clamp(meter_smooth_speed * max(delta, 0.016), 0.0, 1.0))
	_update_ui(smoothed_level)
	_try_emit_silence_chunk(level, delta)

	# --- PCM'e çevir (int16 LE, mono) ve 16 kHz'e düşür ---
	var mix_rate = AudioServer.get_mix_rate()
	var step = float(target_sample_rate) / float(mix_rate)  # örn: 16000/48000 = 0.3333

	j = 0
	while j < count:
		var v2 = frames[j]
		var mono2 = (v2.x + v2.y) * 0.5
		mono2 = clamp(mono2, -1.0, 1.0)

		# Accumulator yaklaşımı: gerekli örnekleri seç
		resample_accum += step
		if resample_accum >= 1.0:
			resample_accum -= 1.0

			var s = int(round(mono2 * 32767.0))
			pcm_bytes.append(s & 0xFF)
			pcm_bytes.append((s >> 8) & 0xFF)

		j += 1

func _try_emit_silence_chunk(level: float, delta: float) -> void:
	if chunk_on_silence == false:
		return
	if is_recording == false:
		return

	if level > talking_threshold:
		chunk_has_speech = true
		silence_elapsed_sec = 0.0
		return

	if chunk_has_speech == false:
		return
	silence_elapsed_sec += max(delta, 0.0)

	var min_bytes := int(float(target_sample_rate) * 2.0 * min_chunk_sec)
	if silence_elapsed_sec < silence_split_sec:
		return
	if pcm_bytes.size() < min_bytes:
		return
	if _passes_avg_db_threshold(pcm_bytes) == false:
		pcm_bytes = PackedByteArray()
		silence_elapsed_sec = 0.0
		chunk_has_speech = false
		return

	var wav_chunk = _make_wav(pcm_bytes, target_sample_rate, 1, 16)
	wav_chunk_ready.emit(wav_chunk, wav_filename)
	pcm_bytes = PackedByteArray()
	silence_elapsed_sec = 0.0
	chunk_has_speech = false

func _update_ui(level):
	var talking = is_recording and level > talking_threshold
	recording_level_changed.emit(level, talking)

	if mic_bar != null:
		mic_bar.value = clampf(level * 100.0, 0.0, 100.0)

	if mic_label != null:
		if talking:
			mic_label.text = "TALKING"
			var c1 = mic_label.modulate
			c1.a = 1.0
			mic_label.modulate = c1
		else:
			if is_recording:
				mic_label.text = "MIC ON"
			else:
				mic_label.text = "MIC OFF"
			var c2 = mic_label.modulate
			c2.a = 0.4
			mic_label.modulate = c2

func _save_wav_to_disk(wav, path):
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("WAV dosyası açılamadı: " + path)
		return
	f.store_buffer(wav)
	f.close()
	print("Saved WAV:", ProjectSettings.globalize_path(path))

# ---------------- WAV Helpers ----------------

func _make_wav(pcm, sample_rate, channels, bits_per_sample):
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
	out.append_array(_u16le(1)) # PCM
	out.append_array(_u16le(channels))
	out.append_array(_u32le(sample_rate))
	out.append_array(_u32le(byte_rate))
	out.append_array(_u16le(block_align))
	out.append_array(_u16le(bits_per_sample))

	out.append_array("data".to_ascii_buffer())
	out.append_array(_u32le(data_size))
	out.append_array(pcm)

	return out

func _u16le(v):
	v = int(v)
	return PackedByteArray([v & 0xFF, (v >> 8) & 0xFF])

func _u32le(v):
	v = int(v)
	return PackedByteArray([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])

func _passes_avg_db_threshold(pcm: PackedByteArray) -> bool:
	var avg_db := _compute_avg_dbfs(pcm)
	return avg_db >= min_avg_db_to_send

func _compute_avg_dbfs(pcm: PackedByteArray) -> float:
	if pcm.size() < 2:
		return -120.0

	var sample_count := pcm.size() / 2
	var i := 0
	var sum_sq := 0.0
	while i + 1 < pcm.size():
		var lo := int(pcm[i])
		var hi := int(pcm[i + 1])
		var s := lo | (hi << 8)
		if s > 32767:
			s -= 65536
		var normalized := float(s) / 32768.0
		sum_sq += normalized * normalized
		i += 2

	if sample_count <= 0:
		return -120.0
	var rms := sqrt(sum_sq / float(sample_count))
	if rms <= 0.000001:
		return -120.0
	return 20.0 * log(rms) / log(10.0)
