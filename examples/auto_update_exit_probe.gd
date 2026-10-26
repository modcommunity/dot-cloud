extends Node

## Real [DotCloudAutoUpdate] restart with the default quit path, run by
## examples/auto_update_exit_check.sh under an open stdin pipe to assert exit status 75.


func _ready() -> void:
	var u := DotCloudAutoUpdate.new()
	u.config = DotCloudAutoUpdateConfig.new()
	u.drive_by_process = false
	add_child(u)
	await get_tree().process_frame
	u.request_restart("exit code probe")
