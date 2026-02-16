@tool
extends RefCounted

const StoryDatabaseScript: Script = preload("res://addons/atom_voice/story_database.gd")
const NPCStoryScript: Script = preload("res://addons/atom_voice/npc_story.gd")

func load_or_create(database_path: String):
	if ResourceLoader.exists(database_path) == false:
		var created = _new_story_database()
		save(created, database_path)
		return created

	var db = load(database_path)
	if db == null:
		db = _new_story_database()
	return db

func save(db, database_path: String) -> void:
	if db == null:
		return
	ResourceSaver.save(db, database_path)

func create_npc(db) -> int:
	if db == null:
		return -1

	var npc = _new_npc_story()
	npc.npc_id = "npc_" + str(db.npcs.size())
	npc.display_name = "New NPC"
	db.npcs.append(npc)
	return db.npcs.size() - 1

func remove_npc(db, index: int) -> bool:
	if is_valid_npc_index(db, index) == false:
		return false
	db.npcs.remove_at(index)
	return true

func is_valid_npc_index(db, index: int) -> bool:
	if db == null:
		return false
	if index < 0:
		return false
	if index >= db.npcs.size():
		return false
	return true

func get_npc(db, index: int):
	if is_valid_npc_index(db, index) == false:
		return null
	return db.npcs[index]

func get_npc_label(npc, index: int) -> String:
	if npc == null:
		return "NPC " + str(index)
	if npc.display_name != "":
		return npc.display_name
	if npc.npc_id != "":
		return npc.npc_id
	return "NPC " + str(index)

func _new_story_database():
	var r = Resource.new()
	r.set_script(StoryDatabaseScript)
	return r

func _new_npc_story():
	var r = Resource.new()
	r.set_script(NPCStoryScript)
	return r





