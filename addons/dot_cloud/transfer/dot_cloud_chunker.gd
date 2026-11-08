class_name DotCloudChunker
extends RefCounted

## Content-defined chunking and delta planning for the "chunks" manifest block (designed in docs/sources.md,
## not yet wired into the publisher or downloader). Pure functions, no I/O.
##
## Algorithm "fastcdc-v1": a gear rolling hash with normalised cut masks. A boundary depends only on the bytes
## near it, so inserting data early in a file moves one or two boundaries and leaves the rest identical, which
## is what makes unchanged chunks reusable across versions.

const ALGO := "fastcdc-v1"
const DEFAULT_AVG := 1048576
const DEFAULT_MIN := 262144
const DEFAULT_MAX := 4194304
## Hard ceiling on chunks per file, so a hostile manifest cannot ask for millions of requests.
const MAX_CHUNKS := 65536

static var _gear: PackedInt64Array = PackedInt64Array()


## Fixed table from a splitmix64 stream so every implementation (GDScript, TypeScript, Rust) can reproduce it.
static func gear() -> PackedInt64Array:
	if _gear.is_empty():
		var t := PackedInt64Array()
		t.resize(256)
		var s := 0
		for i in 256:
			s += -7046029254386353131 # 0x9E3779B97F4A7C15
			var z := s
			z = (z ^ ((z >> 30) & 0x3FFFFFFFF)) * -4658895280553007687
			z = (z ^ ((z >> 27) & 0x1FFFFFFFFFF)) * -7723592293110705685
			t[i] = z ^ ((z >> 31) & 0x1FFFFFFFF)
		_gear = t
	return _gear


static func _mask(bits: int) -> int:
	# Spread the set bits through the high half of the word, as FastCDC does, so the low bits of the hash
	# (which see only the last few bytes) are not the ones deciding.
	return ((1 << bits) - 1) << (63 - bits)


## Cut points for [param data]: returns an Array of [offset, length] covering the whole input.
static func cut(data: PackedByteArray, avg: int = DEFAULT_AVG, min_size: int = DEFAULT_MIN, max_size: int = DEFAULT_MAX) -> Array:
	var out: Array = []
	var n := data.size()
	if n == 0:
		return out
	var bits := int(round(log(float(maxi(avg, 2))) / log(2.0)))
	var mask_s := _mask(bits + 2)
	var mask_l := _mask(maxi(bits - 2, 1))
	var g := gear()
	var pos := 0
	while pos < n:
		var remain := n - pos
		if remain <= min_size:
			out.append([pos, remain])
			break
		var limit := mini(remain, max_size)
		var normal := mini(avg, limit)
		var h := 0
		var i := min_size
		var cutlen := limit
		while i < normal:
			h = (h << 1) + g[data[pos + i]]
			if (h & mask_s) == 0:
				cutlen = i + 1
				break
			i += 1
		if cutlen == limit:
			while i < limit:
				h = (h << 1) + g[data[pos + i]]
				if (h & mask_l) == 0:
					cutlen = i + 1
					break
				i += 1
		out.append([pos, cutlen])
		pos += cutlen
	return out


static func sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		ctx.update(bytes)
	return ctx.finish().hex_encode()


## The manifest block for [param data].
static func chunk_block(data: PackedByteArray, avg: int = DEFAULT_AVG, min_size: int = DEFAULT_MIN, max_size: int = DEFAULT_MAX) -> Dictionary:
	var list: Array = []
	for c in cut(data, avg, min_size, max_size):
		list.append([sha256_hex(data.slice(c[0], c[0] + c[1])), c[1]])
	return {"algo": ALGO, "avg": avg, "min": min_size, "max": max_size, "list": list}


## Validates a block from a manifest against the file's declared size. Returns "" when fine, else the reason.
static func validate_block(block: Variant, file_size: int) -> String:
	if not (block is Dictionary):
		return "chunks is not an object"
	if block.get("algo", "") != ALGO:
		return "unknown chunk algorithm"
	var list: Variant = block.get("list", null)
	if not (list is Array) or (list as Array).is_empty() or (list as Array).size() > MAX_CHUNKS:
		return "bad chunk list"
	var max_size: Variant = block.get("max", 0)
	if not (max_size is int or max_size is float) or int(max_size) <= 0:
		return "bad max chunk size"
	var total := 0
	for e in list:
		if not (e is Array) or (e as Array).size() != 2 or not (e[0] is String) or not (e[1] is int or e[1] is float):
			return "bad chunk entry"
		var h: String = e[0]
		if h.length() != 64 or not h.is_valid_hex_number(false) or h != h.to_lower():
			return "bad chunk hash"
		var sz := int(e[1])
		if sz <= 0 or sz > int(max_size):
			return "chunk size out of range"
		total += sz
	if total != file_size:
		return "chunk sizes do not add up to the file size"
	return ""


## Which chunks must be fetched. [param have] maps hash -> true for chunks already held.
## Returns {"fetch": [[hash,size],...] unique, "reuse_bytes", "fetch_bytes"}.
static func plan(block: Dictionary, have: Dictionary) -> Dictionary:
	var seen := {}
	var fetch: Array = []
	var reuse := 0
	var need := 0
	for e in block["list"]:
		var h: String = e[0]
		var sz := int(e[1])
		if have.has(h) or seen.has(h):
			reuse += sz
		else:
			seen[h] = true
			fetch.append([h, sz])
			need += sz
	return {"fetch": fetch, "reuse_bytes": reuse, "fetch_bytes": need}


## Rebuilds the file. [param chunks] maps hash -> bytes. Every chunk is re-hashed and sized, then the whole
## file hash is compared to [param file_sha256]; any mismatch fails and returns no data.
## Returns {"ok": bool, "data": PackedByteArray, "error": String}.
static func assemble(block: Dictionary, chunks: Dictionary, file_sha256: String) -> Dictionary:
	var out := PackedByteArray()
	for e in block["list"]:
		var h: String = e[0]
		if not chunks.has(h):
			return {"ok": false, "data": PackedByteArray(), "error": "missing chunk " + h}
		var b: PackedByteArray = chunks[h]
		if b.size() != int(e[1]) or sha256_hex(b) != h:
			return {"ok": false, "data": PackedByteArray(), "error": "chunk fails verification " + h}
		out.append_array(b)
	if sha256_hex(out) != file_sha256:
		return {"ok": false, "data": PackedByteArray(), "error": "whole-file hash mismatch"}
	return {"ok": true, "data": out, "error": ""}
