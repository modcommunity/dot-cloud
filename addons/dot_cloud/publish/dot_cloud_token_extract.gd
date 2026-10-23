extends SceneTree

## Copies every `.gdc` out of an export pack into a directory, keeping relative paths.
## Run by `tokenize_scripts.sh`: `godot --headless --path <empty project> --script <this> -- <pck> <out dir>`.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or not ProjectSettings.load_resource_pack(args[0], false):
		printerr("usage: -- <pack.pck> <out dir>")
		quit(1)
		return
	var count := _copy("res://", args[1].rstrip("/"))
	print("tokenized scripts: %d" % count)
	quit(0 if count > 0 else 2)


func _copy(dir: String, out: String) -> int:
	var n := 0
	for sub in DirAccess.get_directories_at(dir):
		n += _copy(dir.path_join(sub), out.path_join(sub))
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() != "gdc":
			continue
		var bytes := FileAccess.get_file_as_bytes(dir.path_join(f))
		if bytes.is_empty():
			continue
		DirAccess.make_dir_recursive_absolute(out)
		var h := FileAccess.open(out.path_join(f), FileAccess.WRITE)
		h.store_buffer(bytes)
		h.close()
		n += 1
	return n
