extends Node

## A fake site for the Workshop sync client: a local HTTP server whose answers come from one
## [member handler] the test sets, so each section decides what the backbone says.
##
## Like [code]http_test_server.gd[/code] it speaks as much HTTP as [DotHttp] asks for, and no
## more -- but it reads a request [b]body[/b] (the scope route is a POST) and it can decline to
## answer at all, which is how a timeout is made.
##
## [codeblock]
## var bb := preload("res://examples/workshop_backbone.gd").new()
## add_child(bb)
## bb.handler = func(method, path, query, headers, body):
##     return {"status": 200, "json": {"hello": "world"}}   # or {"hang": true}
## bb.start()
## [/codeblock]

## [code](method, path, query: Dictionary, headers: Dictionary, body: String) -> Dictionary[/code]
## returning [code]{status, json}[/code] or [code]{hang: true}[/code]. Header names are lower-cased.
var handler: Callable = Callable()

var port: int = 0

## Every request served, as [code]{method, path, query, headers, body}[/code].
var requests: Array[Dictionary] = []

var _server: TCPServer = null
var _clients: Array[Dictionary] = []


func start() -> DotResult:
	_server = TCPServer.new()
	var err := _server.listen(0, "127.0.0.1")
	if err != OK:
		return DotResult.fail(DotError.CODE_NETWORK, "The fake backbone could not listen.", error_string(err))
	port = _server.get_local_port()
	set_process(true)
	return DotResult.success(port)


func base_url() -> String:
	return "http://127.0.0.1:%d" % port


func stop() -> void:
	set_process(false)
	for c in _clients:
		(c["peer"] as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	if _server != null:
		_server.stop()
		_server = null


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buf": PackedByteArray(), "hung": false})
	var keep: Array[Dictionary] = []
	for c in _clients:
		if _pump(c):
			keep.append(c)
	_clients = keep


func _pump(c: Dictionary) -> bool:
	var peer: StreamPeerTCP = c["peer"]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	if c["hung"]:
		return true
	var available := peer.get_available_bytes()
	if available > 0:
		var got := peer.get_data(available)
		if int(got[0]) == OK:
			var buf: PackedByteArray = c["buf"]
			buf.append_array(got[1])
			c["buf"] = buf
	var raw: PackedByteArray = c["buf"]
	var text := raw.get_string_from_utf8()
	var split := text.find("\r\n\r\n")
	if split < 0:
		return true
	var head := text.substr(0, split)
	var length := 0
	for l in head.split("\r\n"):
		if l.to_lower().begins_with("content-length:"):
			length = int(l.split(":")[1].strip_edges())
	var body_bytes := raw.slice(head.to_utf8_buffer().size() + 4)
	if body_bytes.size() < length:
		return true
	_respond(c, head, body_bytes.get_string_from_utf8())
	if c["hung"]:
		return true
	peer.disconnect_from_host()
	return false


func _respond(c: Dictionary, head: String, body: String) -> void:
	var peer: StreamPeerTCP = c["peer"]
	var lines := head.split("\r\n")
	var parts := lines[0].split(" ")
	var target := parts[1] if parts.size() > 1 else "/"
	var path := target
	var query := {}
	var q := target.find("?")
	if q >= 0:
		path = target.substr(0, q)
		for pair in target.substr(q + 1).split("&"):
			var kv := pair.split("=")
			query[kv[0].uri_decode()] = kv[1].uri_decode() if kv.size() > 1 else ""
	var headers := {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0:
			headers[lines[i].substr(0, colon).to_lower()] = lines[i].substr(colon + 1).strip_edges()
	requests.append({"method": parts[0], "path": path, "query": query, "headers": headers, "body": body})
	var answer: Dictionary = {"status": 404, "json": {"error": "no handler"}}
	if handler.is_valid():
		answer = handler.call(parts[0], path, query, headers, body)
	if bool(answer.get("hang", false)):
		c["hung"] = true
		return
	var status := int(answer.get("status", 200))
	var payload := JSON.stringify(answer.get("json", {})).to_utf8_buffer()
	var out := "HTTP/1.1 %d X\r\nContent-Length: %d\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" % [
		status, payload.size()
	]
	peer.put_data(out.to_utf8_buffer())
	peer.put_data(payload)
