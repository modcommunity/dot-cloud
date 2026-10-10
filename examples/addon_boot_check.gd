extends Node

## What a start through `addon_boot_probe.tscn` found, for `addon_set_demo` to read.
##
## [b]It names nothing the overlay brings.[/b] Every script in this project is parsed on its
## own by the family's check, and `DotProbeThing` exists only inside an overlay; so the class
## is found through the global list and the typed use is compiled from text at runtime --
## which is the question anyway: does a script naming it compile in THIS process.

func _ready() -> void:
	var info := {
		"mounted": str(ProjectSettings.get_setting("dot_cloud/addon_overlay", "")),
		"class": false,
	}

	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == "DotProbeThing":
			info["class"] = true
			var script: Variant = load(str(entry.get("path", "")))
			if script is Script:
				info["hello"] = (script as Script).call("hello")

	if bool(info["class"]):
		var typed := GDScript.new()
		typed.source_code = "extends RefCounted\n\nfunc run() -> String:\n\treturn DotProbeThing.hello()\n"
		if typed.reload() == OK:
			info["typed"] = typed.new().call("run")

		var packed := load("res://addons/dot_probe/ui/panel.tscn") as PackedScene
		if packed != null:
			var node := packed.instantiate()
			info["panel"] = str(node.get_meta("v", ""))
			node.free()

		var id := ResourceUID.text_to_id("uid://b7prob3th1ng")
		info["uid"] = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""

	DotCloudAddonSet.confirm_boot()
	info["state"] = str(DotCloudAddonSet.read_plan().get("state", ""))

	print("PROBE ", JSON.stringify(info))
	get_tree().quit()
