extends RefCounted

## Manifest resolving of [DotCloudClient] ([method DotCloudClient.resolve_manifest], [method DotCloudClient.fetch_manifest],
## [method DotCloudClient.verify_manifest]), in a file of its own so the client stays inside the size budget.
## Nothing here is used on its own.

static func resolve(c: DotCloudClient,
	content_id: StringName,
	version: String = "",
	manifest_url: String = ""
) -> DotResult:
	var id := String(content_id)

	if id == "":
		return DotResult.fail(DotError.CODE_INVALID, "No content id to resolve.")

	if not c._started:
		var started := await c.start()
		if not started.ok:
			return started

	var effective_version := version if version != "" else "0.0.0"

	var candidates := (
		PackedStringArray([manifest_url]) if manifest_url != ""
		else c.manifest_urls_for(content_id, effective_version)
	)

	if candidates.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE,
			"There is nowhere to fetch %s from." % id,
			"set local_search_dirs or http_base_urls on this DotCloudClient, or give "
			+ "the content a manifest_url of its own"
		)

	var last: DotResult = null

	for candidate in candidates:
		var fetched := await c.fetch_manifest(candidate)

		if not fetched.ok:
			# Tried in order and the first hit wins, so a base that does not have this
			# content is not a failure until every base has been asked. Only the last
			# error is kept — reporting five 404s helps nobody.
			last = fetched
			continue

		var manifest: DotCloudManifest = fetched.value

		# The manifest decides what it is, and it has to agree with what was asked
		# for. Without this a mirror serving the wrong document mounts content under
		# the id the caller wanted and the paths inside it are somebody else's.
		if manifest.content_id != id:
			last = DotResult.fail(
				DotError.CODE_INVALID,
				"The manifest at %s is for different content." % candidate,
				"asked for '%s', it says '%s'" % [id, manifest.content_id]
			)
			continue

		if version != "" and manifest.version != effective_version:
			last = DotResult.fail(
				DotError.CODE_INVALID,
				"The manifest at %s is the wrong version." % candidate,
				"asked for '%s', it says '%s'" % [effective_version, manifest.version]
			)
			continue

		# A published directory holds the manifest and the objects it names, so a base that answered
		# for the manifest is where the content is. The URL form does not need this: its caller
		# configured the sources.
		if c.is_local_manifest_url(candidate):
			c._adopt_local_dir(c._local_manifest_path(candidate).get_base_dir())

		return DotResult.success(manifest)

	return (
		last if last != null
		else DotResult.fail(
			DotError.CODE_IO, "Could not get %s's manifest." % id
		)
	)


static func fetch(c: DotCloudClient, manifest_url: String) -> DotResult:
	var bytes: PackedByteArray

	if c.is_local_manifest_url(manifest_url):
		var read := DotPaths.read_bytes(c._local_manifest_path(manifest_url))
		if not read.ok:
			return read.wrap("Could not read the content manifest.")
		bytes = read.value
	elif not manifest_url.contains("://"):
		# A local search directory that does not hold this pack: not a URL either, so refuse cleanly
		# and let `ensure` try the next candidate, instead of an engine "Invalid URL scheme" error.
		return DotResult.fail(
			DotError.CODE_STATE,
			"No manifest at '%s'." % manifest_url,
			"a local search directory does not hold this content, and the path is "
			+ "not a URL; set http_base_urls to fetch it"
		)
	else:
		var res := await c._http.get_bytes(manifest_url)
		if not res.ok:
			return res.wrap("Could not download the content manifest.")
		bytes = res.value

	if c._pinned.has(manifest_url) and DotHash.sha256_bytes(bytes) != c._pinned[manifest_url]:
		return DotResult.fail(
			DotError.CODE_INTEGRITY, "The manifest at %s does not match content.lock.json." % manifest_url,
			"manifest_sha256 pins the signed bytes as served; this is another document"
		)

	var parsed := DotCloudManifest.from_json_bytes(bytes)
	if not parsed.ok:
		return parsed

	var manifest: DotCloudManifest = parsed.value

	var checked := c.verify_manifest(manifest)
	if not checked.ok:
		return checked

	# A pack's objects live beside its manifest, so where it came from is always a valid mirror;
	# without it a client pointed at a content root asks for objects one directory too high.
	# Appended, never prepended: a mirror the publisher named is where the operator wants load.
	# A manifest kept on disk names no pack directory, so each HTTP base's own one is used instead.
	var homes := PackedStringArray([manifest_url]) if not c.is_local_manifest_url(manifest_url) \
		else c._http_manifest_urls(manifest.content_id, manifest.version)
	for url in homes:
		var here := url.get_base_dir()
		if here != "" and not manifest.mirrors.has(here):
			manifest.mirrors.append(here)

	return DotResult.success(manifest)


static func verify(c: DotCloudClient, manifest: DotCloudManifest) -> DotResult:
	if not c.config.require_signed_manifests:
		if manifest.signature != "":
			# Verify anyway when a signature is present: it costs nothing and a
			# manifest that claims to be signed but is not should be refused
			# whatever the policy says.
			var opportunistic := DotCloudSignature.verify_for(
				manifest.raw_bytes,
				manifest.signature,
				c.config.trusted_keys,
				manifest.content_id,
				manifest.signature_key_id
			)
			if not opportunistic.ok and not c.config.trusted_keys.is_empty():
				return opportunistic
		return DotResult.success(true)

	c._set_phase(DotCloudClient.Phase.VERIFYING_SIGNATURE, "Checking content signature…")

	if manifest.raw_bytes.is_empty():
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"This manifest cannot be verified.",
			"it was constructed in memory rather than received, so there are no "
			+ "signed bytes to check"
		)

	# verify_for, not verify_any: a valid signature is half the question; the key must also be trusted
	# for THIS content id, or a second publisher could sign a manifest claiming to be somebody else's game.
	return DotCloudSignature.verify_for(
		manifest.raw_bytes,
		manifest.signature,
		c.config.trusted_keys,
		manifest.content_id,
		manifest.signature_key_id
	)
