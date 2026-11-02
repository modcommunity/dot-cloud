extends RefCounted

## The closing steps of [DotCloudPublisher.publish], in a file of their own so the publisher stays inside
## the size budget. Nothing here is used on its own.

const CHANNEL := "cloud.pub"


## Adds the `extra_files` the author named to `extra` (name -> source path); a bad name or missing file fails.
static func add_extra_files(extra: Dictionary, extra_files: Dictionary) -> DotResult:
	for named: Variant in extra_files:
		var from := str(extra_files[named])
		var safe_named := DotPaths.safe_relative(str(named))
		if not safe_named.ok:
			return safe_named.wrap("Cannot publish the extra file '%s'." % named)
		if not FileAccess.file_exists(from):
			return DotResult.fail(
				DotError.CODE_IO,
				"An extra file for the pack does not exist.",
				"%s -> %s" % [named, from]
			)
		extra[str(safe_named.value)] = from
	return DotResult.success(null)


## The bytes to write as manifest.json: the envelope when a key is set, else the bare payload (with a warning).
static func signed_document(manifest: DotCloudManifest, signing_key_pem: String, signing_key_id: String) -> DotResult:
	var payload := manifest.payload_bytes()
	if signing_key_pem == "":
		DotLog.warn(
			CHANNEL,
			"publishing UNSIGNED content — a default-configured client will refuse it",
			{"content": manifest.key()}
		)
		return DotResult.success(payload)

	var sig := DotCloudSignature.sign(payload, signing_key_pem)
	if not sig.ok:
		return sig.wrap("Could not sign the manifest.")

	manifest.signature = sig.value
	manifest.signature_key_id = signing_key_id
	return DotResult.success(DotCloudEnvelope.wrap(payload, str(sig.value), signing_key_id).to_utf8_buffer())


## The one INFO line a publish writes; `stats` carries written, deduped, bytes, rewritten, objects, dropped, sided.
static func log_published(manifest: DotCloudManifest, out_dir: String, stats: Dictionary) -> void:
	DotLog.info(
		CHANNEL,
		"published",
		{
			"content": manifest.key(),
			"files": manifest.files.size(),
			"objects": stats["objects"],
			"deduped": stats["deduped"],
			"sources_dropped": stats["dropped"],
			"sided": stats["sided"],
			"provides": manifest.provides.get("entries", []).size() if not manifest.provides.is_empty() else -1,
			"runs_code": bool(manifest.provides.get("runs_code", false)),
			"written": stats["written"],
			"bytes": DotPaths.format_bytes(stats["bytes"]),
			"rewritten": stats["rewritten"],
			"signed": manifest.signature != "",
			"out": out_dir,
		}
	)
