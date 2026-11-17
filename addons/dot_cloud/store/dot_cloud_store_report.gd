extends RefCounted

## The summary of [DotCloudStore] for the `cloud_status` console command, in a file of their own so the store stays
## inside the size budget. Nothing here is used on its own.


static func describe(store: RefCounted) -> Dictionary:
	return {
		"dir": store.config.cache_dir,
		"objects": store._index.size(),
		"bytes": store._total_bytes,
		"bytes_human": DotPaths.format_bytes(store._total_bytes),
		"referenced": DotPaths.format_bytes(store.referenced_bytes()),
		"limit": DotPaths.format_bytes(store._limit_bytes) if store._limit_bytes > 0 else "unlimited",
		"over_limit": store.is_over_limit(),
		"packs": store.packs.records.size(),
		"pinned_packs": store.packs.records.values().filter(func(r: Dictionary) -> bool: return bool(r["pinned"])).size(),
	}


static func describe_lines(store: RefCounted) -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe(store)
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append("%-16s %s" % [str(k), str(d[k])])
	return out
