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
		"disk_free": _bytes_or_unknown(disk_free(store)),
	}


## Bytes free on the filesystem holding the cache, or -1 when it cannot be read (always on web, where
## the browser's quota is the figure: [method DotCloudStore.free_bytes]).
static func disk_free(store: RefCounted) -> int:
	if DotPlatform.is_web():
		return -1
	var dir := DirAccess.open(ProjectSettings.globalize_path(store.config.cache_dir))
	if dir == null:
		return -1
	return int(dir.get_space_left())


static func _bytes_or_unknown(n: int) -> String:
	return DotPaths.format_bytes(n) if n >= 0 else "unknown"


## The detail of a quota refusal from [method DotCloudStore.prune]: everything an operator needs to act on it
## without reading code -- the limit and the key that sets it, what is referenced and so cannot be evicted,
## and the disk free, since a full ceiling on an empty disk is a setting to change and not a disk to clean.
static func quota_detail(store: RefCounted, freed: int, target: int, referenced_objects: int) -> String:
	var cfg: DotCloudConfig = store.config
	var key := cfg.limit_key()
	var where := "%s in the cloud config file (content.json), env %s%s or %s%s" % [
		key, cfg.env_prefix(), key.to_upper(), cfg.cli_prefix(), key.replace("_", "-")
	]
	if cfg.limit_hint != "":
		where = "%s; here: %s" % [where, cfg.limit_hint]
	return (
		"freed %s of %s needed; %d object(s) are referenced by mounted content (%s referenced, %s cached); "
		+ "limit %s (%s); disk free %s at %s. Raise %s, or set it to 0 for unlimited"
	) % [
		DotPaths.format_bytes(freed),
		DotPaths.format_bytes(target),
		referenced_objects,
		DotPaths.format_bytes(store.referenced_bytes()),
		DotPaths.format_bytes(store._total_bytes),
		DotPaths.format_bytes(store._limit_bytes),
		key,
		_bytes_or_unknown(disk_free(store)),
		cfg.cache_dir,
		where,
	]


static func describe_lines(store: RefCounted) -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe(store)
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append("%-16s %s" % [str(k), str(d[k])])
	return out
