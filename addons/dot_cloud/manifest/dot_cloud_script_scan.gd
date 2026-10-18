class_name DotCloudScriptScan
extends RefCounted

## Does a pack's content run code? A label for honest packs, not a sandbox.
##
## Run at publish (the result is written into the manifest as `runs_code`, never taken from
## the author's file) and again between download and mount, over the stored files. A pack whose
## files run code when its manifest says they do not is refused: the manifest was signed by the
## site after review, and the bytes must not say more than it did.
##
## [b]What it cannot do.[/b] A binary resource can be crafted to hide a script class name from
## any byte search. The policy therefore rests on the site's signature and its review; this
## catches the honest mistake and the lazy attempt.

const CODE_EXTENSIONS: Array[String] = ["gd", "gdc", "cs", "gdextension", "so", "dll", "dylib", "wasm"]
const TEXT_RESOURCES: Array[String] = ["tscn", "tres"]
const BINARY_RESOURCES: Array[String] = ["scn", "res"]

## Script class names as they are stored in a binary resource's string table.
const BINARY_MARKERS: Array[String] = ["GDScript", "CSharpScript", "GDExtension"]


## Scans [param paths] (pack-relative). [param reader] is a Callable taking a path and
## returning its bytes as a PackedByteArray (empty when unreadable); it is only called for
## text and binary resources. [param provides] adds the kinds that always run code.
## Value: [code]{runs_code: bool, reasons: PackedStringArray}[/code], reasons capped at 8.
static func scan(paths: PackedStringArray, reader: Callable, provides: Dictionary = {}) -> DotResult:
	var reasons := PackedStringArray()
	if DotCloudProvides.has_code_kind(provides):
		reasons.append("entries of kind entity, tool or script")
	for p in paths:
		if reasons.size() >= 8:
			break
		var ext := p.get_extension().to_lower()
		if CODE_EXTENSIONS.has(ext):
			reasons.append("%s (code file)" % p)
		elif TEXT_RESOURCES.has(ext):
			var bytes: PackedByteArray = reader.call(p)
			if _text_runs_code(bytes.get_string_from_utf8()):
				reasons.append("%s (script in a resource)" % p)
		elif BINARY_RESOURCES.has(ext):
			var bin: PackedByteArray = reader.call(p)
			if _binary_runs_code(bin):
				reasons.append("%s (script class in a binary resource)" % p)
	return DotResult.success({"runs_code": reasons.size() > 0, "reasons": reasons})


## GDScript / C# sub-resources always count. A script ext_resource counts unless it names
## the host build's copy under res://addons/, which is how a pack that only ships definitions
## (zee-dot-weapons) stays data.
static func _text_runs_code(text: String) -> bool:
	for line in text.split("\n"):
		if not line.begins_with("["):
			continue
		if line.begins_with("[sub_resource") and (
			line.contains('type="GDScript"') or line.contains('type="CSharpScript"')
		):
			return true
		if line.begins_with("[ext_resource") and (
			line.contains('type="Script"') or line.contains('type="GDScript"')
			or line.contains('type="CSharpScript"')
		):
			var at := line.find('path="')
			if at < 0:
				return true
			var path := line.substr(at + 6, line.find('"', at + 6) - at - 6)
			if not path.begins_with("res://addons/"):
				return true
	return false


static func _binary_runs_code(bytes: PackedByteArray) -> bool:
	if bytes.size() < 8:
		return false
	# Byte search, not a string decode: the file is binary, and a decode of arbitrary bytes
	# either errors or mangles the class names this looks for.
	for m in BINARY_MARKERS:
		if _contains_bytes(bytes, String(m).to_ascii_buffer()):
			return true
	return false


static func _contains_bytes(hay: PackedByteArray, needle: PackedByteArray) -> bool:
	var n := needle.size()
	if n == 0 or hay.size() < n:
		return false
	var first: int = needle[0]
	var at := hay.find(first)
	while at != -1 and at + n <= hay.size():
		var ok := true
		for j in range(1, n):
			if hay[at + j] != needle[j]:
				ok = false
				break
		if ok:
			return true
		at = hay.find(first, at + 1)
	return false
