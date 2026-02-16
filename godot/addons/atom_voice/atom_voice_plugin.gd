@tool
extends EditorPlugin

var dock
var dock_content

func _enter_tree():
	dock = EditorDock.new()
	dock.title = "Story Tool"
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL

	dock_content = preload("res://addons/atom_voice/atom_voice_tool_dock.tscn").instantiate()
	dock.add_child(dock_content)

	# Dock content'e plugin referansı gerekiyorsa method ile ver (property atama yok)
	if dock_content.has_method("set_plugin"):
		dock_content.call("set_plugin", self)

	add_dock(dock)

func _exit_tree():
	if dock != null:
		remove_dock(dock)
		dock.queue_free()
		dock = null
		dock_content = null
