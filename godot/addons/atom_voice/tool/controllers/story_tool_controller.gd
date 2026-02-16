@tool
extends RefCounted

const StoryRepositoryScript = preload("res://addons/atom_voice/tool/services/story_repository.gd")

var repository = StoryRepositoryScript.new()
var database_path := "res://addons/atom_voice/story_database.tres"

var db = null
var selected_index := -1
var updating_ui := false
var ui := {}
var filtered_indices: Array[int] = []
var current_filter := ""

func initialize(ui_nodes: Dictionary, db_path: String) -> void:
	ui = ui_nodes
	database_path = db_path
	db = repository.load_or_create(database_path)
	current_filter = str(ui.get("filter_edit", null).text if ui.has("filter_edit") else "")
	_fill_main_story_from_db()
	refresh_list()
	set_fields_enabled(false)
	clear_fields()

func on_add_pressed() -> void:
	if db == null:
		return

	var idx = repository.create_npc(db)
	refresh_list(idx)
	if idx >= 0:
		_select_list_item_for_db_index(idx)

func on_remove_pressed() -> void:
	if repository.remove_npc(db, selected_index):
		refresh_list()
		clear_fields()

func on_save_pressed() -> void:
	repository.save(db, database_path)

func on_list_selected(list_index: int) -> void:
	var db_index = _to_db_index(list_index)
	if repository.is_valid_npc_index(db, db_index) == false:
		return

	selected_index = db_index
	set_fields_enabled(true)
	fill_ui_from_npc()

func on_filter_changed(text: String) -> void:
	current_filter = text.strip_edges()
	refresh_list(selected_index)
	if selected_index == -1:
		clear_fields()

func on_main_story_changed() -> void:
	if updating_ui:
		return
	if db == null:
		return
	if "main_story" in db:
		db.main_story = ui["main_story_edit"].text

func on_line_changed(_text: String) -> void:
	if updating_ui:
		return
	apply_ui_to_npc(true)

func on_text_changed() -> void:
	if updating_ui:
		return
	apply_ui_to_npc(false)

func refresh_list(restore_db_index: int = -1) -> void:
	ui["npc_list"].clear()
	filtered_indices.clear()
	set_fields_enabled(false)

	if db == null:
		return

	var i = 0
	while i < db.npcs.size():
		var npc = db.npcs[i]
		if _matches_filter(npc, i):
			ui["npc_list"].add_item(repository.get_npc_label(npc, i))
			filtered_indices.append(i)
		i += 1

	selected_index = -1
	if restore_db_index >= 0:
		_select_list_item_for_db_index(restore_db_index)

func fill_ui_from_npc() -> void:
	var npc = repository.get_npc(db, selected_index)
	if npc == null:
		return

	updating_ui = true
	ui["id_edit"].text = npc.npc_id
	ui["name_edit"].text = npc.display_name
	ui["backstory_edit"].text = npc.backstory
	ui["personality_edit"].text = npc.personality
	ui["goals_edit"].text = npc.goals
	ui["secrets_edit"].text = npc.secrets
	updating_ui = false

func apply_ui_to_npc(refresh_list_labels: bool) -> void:
	var npc = repository.get_npc(db, selected_index)
	if npc == null:
		return

	npc.npc_id = ui["id_edit"].text
	npc.display_name = ui["name_edit"].text
	npc.backstory = ui["backstory_edit"].text
	npc.personality = ui["personality_edit"].text
	npc.goals = ui["goals_edit"].text
	npc.secrets = ui["secrets_edit"].text

	if refresh_list_labels:
		refresh_list(selected_index)
	else:
		var list_index = _to_list_index(selected_index)
		if list_index >= 0:
			ui["npc_list"].set_item_text(list_index, repository.get_npc_label(npc, selected_index))

func set_fields_enabled(enabled: bool) -> void:
	ui["id_edit"].editable = enabled
	ui["name_edit"].editable = enabled
	ui["backstory_edit"].editable = enabled
	ui["personality_edit"].editable = enabled
	ui["goals_edit"].editable = enabled
	ui["secrets_edit"].editable = enabled

func clear_fields() -> void:
	updating_ui = true
	ui["id_edit"].text = ""
	ui["name_edit"].text = ""
	ui["backstory_edit"].text = ""
	ui["personality_edit"].text = ""
	ui["goals_edit"].text = ""
	ui["secrets_edit"].text = ""
	updating_ui = false

func _fill_main_story_from_db() -> void:
	if ui.has("main_story_edit") == false:
		return
	updating_ui = true
	if db != null and ("main_story" in db):
		ui["main_story_edit"].text = str(db.main_story)
	else:
		ui["main_story_edit"].text = ""
	updating_ui = false

func _matches_filter(npc, index: int) -> bool:
	if current_filter == "":
		return true

	var haystack := repository.get_npc_label(npc, index).to_lower()
	if haystack.find(current_filter.to_lower()) >= 0:
		return true
	if npc == null:
		return false
	return str(npc.npc_id).to_lower().find(current_filter.to_lower()) >= 0

func _to_db_index(list_index: int) -> int:
	if list_index < 0 or list_index >= filtered_indices.size():
		return -1
	return filtered_indices[list_index]

func _to_list_index(db_index: int) -> int:
	var i = 0
	while i < filtered_indices.size():
		if filtered_indices[i] == db_index:
			return i
		i += 1
	return -1

func _select_list_item_for_db_index(db_index: int) -> void:
	var list_index = _to_list_index(db_index)
	if list_index < 0:
		selected_index = -1
		set_fields_enabled(false)
		return
	ui["npc_list"].select(list_index)
	on_list_selected(list_index)

