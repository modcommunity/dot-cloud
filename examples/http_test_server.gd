extends Node

## A minimal static HTTP/1.1 file server, so the HTTP source can be tested for real.
##
## [b]Why this exists.[/b] [DotCloudSourceHttp] is the source every shipped game
## actually uses — mirror failover, sticky preference, range resume, the
## content-addressed URL layout — and until this file it was exercised by no
## example at all. [code]sync_demo[/code] runs the whole pipeline through
## [DotCloudSourceLocal], which resolves synchronously and never builds a URL,
## never parses a response and never resumes anything.
##
## Serving from GDScript rather than shelling out to a real web server keeps the
## example self-contained: no Python, no Docker, no network, nothing to install,
## and it runs in [code]--headless[/code] on any machine the engine runs on.
##
## It is deliberately not production code and does not live in
## [code]addons/[/code]. It speaks exactly as much HTTP as
## [code]DotHttp[/code] asks for — GET, HEAD, one [code]Range: bytes=N-[/code]
## form, keep-alive off — and every fault it can inject exists because a source
## code path needs it:
##
## [codeblock]
## var srv := preload("res://examples/http_test_server.gd").new()
## add_child(srv)
## srv.root = "user://published"
## srv.start(0)                      # 0 = any free port
## srv.corrupt_paths.append("/objects/ab/abcd…")   # serves wrong bytes
## srv.fail_paths.append("/objects/cd/cdef…")      # serves 500
## srv.support_ranges = false                       # ignores Range, replies 200
## [/codeblock]

## Directory served as the document root. A Godot path — [code]user://[/code] is fine.
var root: String = ""

## Port actually bound. Read after [method start] when 0 was requested.
var port: int = 0

## Reply 206 to a [code]Range[/code] request. Off makes the host look like one
## that cannot resume, which is the branch that restarts from zero.
var support_ranges: bool = true

## Request paths answered with 500 rather than content.
var fail_paths: PackedStringArray = PackedStringArray()

## Request paths answered with the right length of the wrong bytes.
##
## The interesting failure, because it is the one that gets past the transfer
## and has to be caught by hash verification instead.
var corrupt_paths: PackedStringArray = PackedStringArray()

## Every request line served, in order, as "GET /path" — plus " (range)" when
## the request carried one that was honoured.
var log: PackedStringArray = PackedStringArray()

## Body bytes written to sockets. A resumed download moves fewer of these, which
## is the only externally visible proof that the range was used.
var bytes_sent: int = 0

var _server: TCPServer = null
var _clients: Array[Dictionary] = []


## Binds and starts accepting. Returns a [DotResult] carrying the bound port.
func start(requested_port: int = 0) -> DotResult:
	_server = TCPServer.new()

	var err := _server.listen(requested_port, "127.0.0.1")
	if err != OK:
		return DotResult.fail(
			DotError.CODE_NETWORK,
			"The test HTTP server could not listen.",
			"port %d: %s" % [requested_port, error_string(err)]
		)

	port = _server.get_local_port()
	set_process(true)
	return DotResult.success(port)


## The base URL a client should be pointed at.
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
		_clients.append({
			"peer": _server.take_connection(),
			"buf": PackedByteArray(),
		})

	var still_open: Array[Dictionary] = []

	for c in _clients:
		if _pump(c):
			still_open.append(c)

	_clients = still_open


## Reads one client until it has a whole request, answers it, closes. Returns
## false when the connection is finished with.
func _pump(c: Dictionary) -> bool:
	var peer: StreamPeerTCP = c["peer"]
	peer.poll()

	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false

	var available := peer.get_available_bytes()
	if available > 0:
		var got := peer.get_data(available)
		if int(got[0]) == OK:
			var buf: PackedByteArray = c["buf"]
			buf.append_array(got[1])
			c["buf"] = buf

	var text := (c["buf"] as PackedByteArray).get_string_from_utf8()

	# Headers only; nothing served here has a request body.
	if not text.contains("\r\n\r\n"):
		return true

	_respond(peer, text)
	peer.disconnect_from_host()
	return false


func _respond(peer: StreamPeerTCP, request: String) -> void:
	var lines := request.split("\r\n")
	var parts := lines[0].split(" ")

	if parts.size() < 2:
		_send(peer, 400, "Bad Request", PackedByteArray(), {})
		return

	var method := parts[0]
	var path := parts[1]

	# Strip any query string: content-addressed URLs have none, but a CDN-style
	# cache-buster appended by a host must not turn into a 404.
	var q := path.find("?")
	if q >= 0:
		path = path.substr(0, q)

	var range_from := -1
	for l in lines:
		var lower := l.to_lower()
		if lower.begins_with("range:"):
			# Only "bytes=N-" is generated by the resume path. An open-ended
			# range is the whole point: the client does not know the end.
			var spec := lower.split("=")
			if spec.size() == 2:
				range_from = int(spec[1].split("-")[0])

	if fail_paths.has(path):
		log.append("%s %s -> 500" % [method, path])
		_send(peer, 500, "Internal Server Error", PackedByteArray(), {})
		return

	# The document root answers 200 with nothing in it, the way a content host
	# with a directory root does. It matters because DotCloudSourceHttp.probe_base
	# probes the bare base URL: a host that 404s its root is reported unreachable
	# even though every object under it is served fine.
	if path == "/":
		log.append("%s /" % method)
		_send(peer, 200, "OK", PackedByteArray(), {"Accept-Ranges": "bytes"})
		return

	var file_path := root.path_join(path.trim_prefix("/"))

	if not FileAccess.file_exists(file_path):
		log.append("%s %s -> 404" % [method, path])
		_send(peer, 404, "Not Found", PackedByteArray(), {})
		return

	var body := FileAccess.get_file_as_bytes(file_path)

	if corrupt_paths.has(path):
		# Same length, different bytes: a truncated response would be caught by
		# Content-Length long before hashing, which is not the case under test.
		body = body.duplicate()
		for i in body.size():
			body[i] = (int(body[i]) + 1) & 0xFF

	var total := body.size()
	var extra := {"Accept-Ranges": "bytes" if support_ranges else "none"}
	var status := 200
	var reason := "OK"

	if range_from > 0 and support_ranges:
		if range_from >= total:
			# 416 rather than an empty 206: the client's partial is longer than
			# the object, and answering 206 with nothing looks like success.
			log.append("%s %s -> 416" % [method, path])
			extra["Content-Range"] = "bytes */%d" % total
			_send(peer, 416, "Range Not Satisfiable", PackedByteArray(), extra)
			return

		body = body.slice(range_from)
		status = 206
		reason = "Partial Content"
		extra["Content-Range"] = "bytes %d-%d/%d" % [
			range_from, total - 1, total
		]
		log.append("%s %s (range %d-)" % [method, path, range_from])
	else:
		log.append("%s %s" % [method, path])

	if method == "HEAD":
		# Content-Length still describes the body that a GET would return.
		_send(peer, status, reason, PackedByteArray(), extra, body.size())
		return

	_send(peer, status, reason, body, extra)


func _send(
	peer: StreamPeerTCP,
	status: int,
	reason: String,
	body: PackedByteArray,
	extra: Dictionary,
	length_override: int = -1
) -> void:
	var length := body.size() if length_override < 0 else length_override

	var head := "HTTP/1.1 %d %s\r\n" % [status, reason]
	head += "Content-Length: %d\r\n" % length
	head += "Content-Type: application/octet-stream\r\n"
	head += "Connection: close\r\n"

	for k in extra:
		head += "%s: %s\r\n" % [k, str(extra[k])]

	head += "\r\n"

	peer.put_data(head.to_utf8_buffer())

	if not body.is_empty():
		peer.put_data(body)
		bytes_sent += body.size()
