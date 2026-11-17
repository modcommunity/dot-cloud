extends RefCounted

## The text report of [DotCloudClient] for the `cloud_status` console command, in a file of their own so the client
## stays inside the size budget. Nothing here is used on its own.


## Lines describing [param client].
static func lines(client: Node) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("phase            %s" % client.phase_name(client.phase()))
	out.append("session tag      %s" % client.session_tag)
	if client.config != null:
		out.append("side             %s (%s)" % [client.config.resolved_side() if client.config.resolved_side() != "" else "both", client.config.side])

	if client.store != null:
		out.append_array(client.store.describe_lines())

	if client.mounter != null:
		out.append("mounts:")
		for l in client.mounter.describe_lines():
			out.append("  " + l)

	var index := DotRegistry.get_service(DotContentIndex.SERVICE) as DotContentIndex
	if index != null:
		out.append("provided:")
		for l in index.describe_lines():
			out.append("  " + l)

	out.append("sources:")
	for s in client.sources:
		var h: Dictionary = s.health()
		out.append("  %-10s %s" % [
			str(h["source"]),
			"ok" if bool(h["available"]) else "unavailable",
		])

	return out
