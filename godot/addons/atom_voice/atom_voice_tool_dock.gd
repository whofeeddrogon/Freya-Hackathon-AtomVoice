@tool
extends Control

const StoryToolControllerScript = preload("res://addons/atom_voice/tool/controllers/story_tool_controller.gd")

@export var database_path = "res://addons/atom_voice/story_database.tres"
var plugin_ref
var controller = StoryToolControllerScript.new()

@onready var npc_list = $Root/Content/Left/NPCList
@onready var filter_edit = $Root/Content/Left/FilterEdit
@onready var add_btn = $Root/Content/Left/LeftButtons/AddNPC
@onready var remove_btn = $Root/Content/Left/LeftButtons/RemoveNPC
@onready var save_btn = $Root/Content/Right/Save
@onready var main_story_edit = $Root/Content/Right/MainStoryEdit

@onready var id_edit = $Root/Content/Right/FormScroll/Form/IdentityGrid/IdEdit
@onready var name_edit = $Root/Content/Right/FormScroll/Form/IdentityGrid/NameEdit
@onready var backstory_edit = $Root/Content/Right/FormScroll/Form/BackstoryEdit
@onready var personality_edit = $Root/Content/Right/FormScroll/Form/PersonalityEdit
@onready var goals_edit = $Root/Content/Right/FormScroll/Form/GoalsEdit
@onready var secrets_edit = $Root/Content/Right/FormScroll/Form/SecretsEdit

func set_plugin(p):
	plugin_ref = p

func _ready():
	add_btn.pressed.connect(_on_add_pressed)
	remove_btn.pressed.connect(_on_remove_pressed)
	save_btn.pressed.connect(_on_save_pressed)
	npc_list.item_selected.connect(_on_list_selected)
	filter_edit.text_changed.connect(_on_filter_changed)

	id_edit.text_changed.connect(_on_line_changed)
	name_edit.text_changed.connect(_on_line_changed)
	main_story_edit.text_changed.connect(_on_main_story_changed)

	backstory_edit.text_changed.connect(_on_text_changed)
	personality_edit.text_changed.connect(_on_text_changed)
	goals_edit.text_changed.connect(_on_text_changed)
	secrets_edit.text_changed.connect(_on_text_changed)

	controller.initialize({
		"npc_list": npc_list,
		"filter_edit": filter_edit,
		"main_story_edit": main_story_edit,
		"id_edit": id_edit,
		"name_edit": name_edit,
		"backstory_edit": backstory_edit,
		"personality_edit": personality_edit,
		"goals_edit": goals_edit,
		"secrets_edit": secrets_edit
	}, database_path)

func _on_add_pressed():
	controller.on_add_pressed()

func _on_remove_pressed():
	controller.on_remove_pressed()

func _on_list_selected(index):
	controller.on_list_selected(index)

func _on_filter_changed(text):
	controller.on_filter_changed(text)

func _on_main_story_changed():
	controller.on_main_story_changed()

func _on_line_changed(_t):
	controller.on_line_changed(_t)

func _on_text_changed():
	controller.on_text_changed()

func _on_save_pressed():
	controller.on_save_pressed()
