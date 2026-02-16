@tool
extends Resource
class_name NPCStory

@export var npc_id = ""
@export var display_name = ""
@export var voice = ""
@export_multiline var backstory = ""
@export_multiline var personality = ""
@export_multiline var goals = ""
@export_multiline var secrets = ""
@export_multiline var system_prompt = ""
@export var actions: Array[String] = []
