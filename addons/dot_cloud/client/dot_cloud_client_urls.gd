@tool
extends Node

## Where a [DotCloudClient] looks for manifests: the base lists, the URL templates and their expansion. A base
## layer so the client stays inside the size budget; nothing here is used on its own.

@export_group("Sources")

## HTTP base URLs to try when a manifest lists no mirrors of its own.
@export var http_base_urls: PackedStringArray = PackedStringArray()

## Directories searched before the network. For development and bundled content.
@export var local_search_dirs: PackedStringArray = PackedStringArray()

## How a content id and version become a manifest URL, for [method ensure]: {base}, {id} and {version}
## are substituted. A catalogue of a hundred maps should not repeat one CDN hostname a hundred times;
## the default matches what [DotCloudPublisher] writes.
@export var manifest_url_template: String = "{base}/{id}/{version}/manifest.json"

## Other shapes to try when [member manifest_url_template] does not answer.
##
## For content published before the versioned layout; expanded like the main template, appended per base.
@export var manifest_url_fallbacks: PackedStringArray = PackedStringArray()


## Manifest URLs to try for this content, best first: every local base before any network base,
## because the disk is cheaper than a request whatever layout it is in and works offline.
func manifest_urls_for(
	content_id: StringName, version: String = ""
) -> PackedStringArray:
	var out := PackedStringArray()
	for base in local_search_dirs:
		for url in _expand_all(base, content_id, version):
			out.append(url)
	for base in resolved_http_base_urls():
		for url in _expand_all(base, content_id, version):
			out.append(url)
	return out


## One base, every template, primary first.
func _expand_all(
	base: String, content_id: StringName, version: String
) -> PackedStringArray:
	var out := PackedStringArray([_expand_manifest_url(base, content_id, version)])
	for template in manifest_url_fallbacks:
		if template.strip_edges() == "":
			continue
		var url := _expand_with(template, base, content_id, version)
		# A fallback that expands to the primary would log as a retry that is not happening.
		if not url in out:
			out.append(url)
	return out


## Puts the page's origin on a root-relative base, so it becomes a URL.
##
## HTTPRequest refuses `/content/x/manifest.json` before the browser sees it. HTTP bases only: a local search dir beginning with `/` is a real path.
static func resolve_base_url(base: String) -> String:
	return join_origin(DotWeb.origin(), base)


## The pure half of [method resolve_base_url], so it can be tested off-web. Off-web the origin is ""
## and the base comes back untouched, so a native absolute path keeps working.
static func join_origin(origin: String, base: String) -> String:
	if origin == "" or base == "" or base.contains("://") or not base.begins_with("/"):
		return base
	return origin.trim_suffix("/") + base


## Every HTTP base, made absolute where a page origin can do it.
func resolved_http_base_urls() -> PackedStringArray:
	var out := PackedStringArray()
	for base in http_base_urls:
		out.append(resolve_base_url(base))
	return out


func _expand_manifest_url(
	base: String, content_id: StringName, version: String
) -> String:
	return _expand_with(manifest_url_template, base, content_id, version)


## The substitution itself, for the primary template and every fallback alike.
static func _expand_with(
	template: String, base: String, content_id: StringName, version: String
) -> String:
	return template \
		.replace("{base}", base.trim_suffix("/")) \
		.replace("{id}", String(content_id)) \
		.replace("{version}", version if version != "" else "0.0.0")


## Whether a manifest URL names a file on this machine rather than a server.
##
## A bare path is local only if it exists: a root-relative `/content/x/manifest.json` is a same-origin URL on the web.
static func is_local_manifest_url(manifest_url: String) -> bool:
	if manifest_url.begins_with("res://") or manifest_url.begins_with("user://"):
		return true
	if manifest_url.begins_with("file://"):
		return true
	if manifest_url.contains("://"):
		return false
	return FileAccess.file_exists(manifest_url)


static func _local_manifest_path(manifest_url: String) -> String:
	return (
		manifest_url.trim_prefix("file://") if manifest_url.begins_with("file://")
		else manifest_url
	)
