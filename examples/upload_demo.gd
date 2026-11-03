extends Node
## DotCloudUploader._put_many against a local mock PUT server (tools/mock_put_server.py): every object arrives, a failing one is named, a 403 asks for fresh URLs, and concurrency is faster than serial.

const PORT := 18765

var _pass := 0
var _fail := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _jobs(dir: String, n: int, prefix: String, route: String) -> Array:
	var jobs: Array = []
	for i in n:
		var sha := "%s%062d" % [prefix, i]
		var path := dir.path_join(sha)
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string("object %d" % i)
		f.close()
		jobs.append({"put": {"sha256": sha, "size": 8, "url": "http://127.0.0.1:%d/%s/%s" % [PORT, route, sha], "headers": {"x-test": "1"}}, "path": path})
	return jobs


func _run_check(dir: String) -> void:
	var out := dir.path_join("pack")
	for i in 14:
		var sha := "dd%062d" % i
		DirAccess.make_dir_recursive_absolute(out.path_join("objects/dd"))
		var f := FileAccess.open(out.path_join("objects/dd/" + sha), FileAccess.WRITE)
		f.store_string("object %d" % i)
		f.close()
	var m := FileAccess.open(out.path_join("manifest.json"), FileAccess.WRITE)
	m.store_string("{}")
	m.close()
	var tok := dir.path_join("token")
	var t := FileAccess.open(tok, FileAccess.WRITE)
	t.store_string("testtoken\n")
	t.close()
	var server := OS.create_process("python3", [ProjectSettings.globalize_path("res://examples/mock_put_server.py"), str(PORT), "0.05", ProjectSettings.globalize_path(out)])
	OS.delay_msec(800)
	for conc in [6, 1]:
		var up := DotCloudUploader.new()
		up.site = "http://127.0.0.1:%d" % PORT
		up.token_file = tok
		up.retries = 0
		up.concurrency = conc
		var last := [0, 0, 0]
		up.on_progress = func(d: int, tot: int, b: int) -> void:
			last[0] = d
			last[1] = tot
			last[2] = b
		var r: DotResult = up._run(FileAccess.get_file_as_bytes(out.path_join("manifest.json")), out, 1, _cfg(tok))
		_check(r.ok and r.value["uploaded"] == 14 and r.value["status"] == "READY", "_run (concurrency %d) uploads all, refreshing expired URLs: %s" % [conc, str(r.value if r.ok else r.error.message)])
		_check(last == [14, 14, 116], "_run progress %s" % str(last))
		OS.kill(server)
		OS.delay_msec(200)
		server = OS.create_process("python3", [ProjectSettings.globalize_path("res://examples/mock_put_server.py"), str(PORT), "0.05", ProjectSettings.globalize_path(out)])
		OS.delay_msec(800)
	OS.kill(server)


func _cfg(tok: String) -> String:
	var cfg := OS.get_user_data_dir().path_join("upload_demo/auth.cfg")
	var f := FileAccess.open(cfg, FileAccess.WRITE)
	f.store_line('header = "Authorization: Bearer %s"' % FileAccess.get_file_as_string(tok).strip_edges())
	f.close()
	return cfg


func _ready() -> void:
	var dir := OS.get_user_data_dir().path_join("upload_demo")
	DirAccess.make_dir_recursive_absolute(dir)
	var server := OS.create_process("python3", [ProjectSettings.globalize_path("res://examples/mock_put_server.py"), str(PORT), "0.2"])
	OS.delay_msec(800)
	var up := DotCloudUploader.new()
	up.retries = 0
	var seen := [0, 0]
	var cb := func(n: int, b: int) -> void:
		seen[0] += n
		seen[1] += b

	var jobs := _jobs(dir, 24, "aa", "ok")
	up.concurrency = 6
	var t0 := Time.get_ticks_msec()
	var r: DotResult = up._put_many(jobs, cb)
	var fast := Time.get_ticks_msec() - t0
	_check(r.ok and r.value == false, "parallel PUTs succeed")
	_check(seen[0] == 24 and seen[1] == 24 * 8, "progress counts %s" % str(seen))

	var t1 := Time.get_ticks_msec()
	for j: Dictionary in jobs:
		_check(up._put(j["put"], j["path"]).ok, "serial PUT")
	var slow := Time.get_ticks_msec() - t1
	print("24 objects, 0.2 s each: parallel(6) %d ms, serial %d ms" % [fast, slow])
	_check(fast * 3 < slow, "parallel is at least 3x faster")

	var bad := _jobs(dir, 4, "bb", "ok")
	bad[2]["put"]["url"] = "http://127.0.0.1:%d/fail/%s" % [PORT, bad[2]["put"]["sha256"]]
	r = up._put_many(bad, cb)
	_check(not r.ok and r.error.message.contains(bad[2]["put"]["sha256"]), "failure names the sha")

	var exp := _jobs(dir, 4, "cc", "expired")
	r = up._put_many(exp, cb)
	_check(r.ok and r.value == true, "403 reports expiry")

	OS.kill(server)
	_run_check(dir)
	print("upload_demo: %d passed, %d failed" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 or _pass == 0 else 0)
