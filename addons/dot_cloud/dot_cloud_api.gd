extends RefCounted

## dot-cloud's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game or a tool could call that did not exist before.
## OLDEST is raised to LEVEL when something that could have been called is removed or
## changes meaning.

# 1: everything before this file existed (an absent file reads as 1).
# 2: DotCloudPublisher.extra_files (pack path -> file outside the source).
# 3: acquire refuses a pack whose requires.json asks for more than this build has BEFORE
#    downloading it (CODE_VERSION, no pack bytes fetched).
# 4: DotCloudPublisher.ship_import_sources (off: an imported asset's source is left out of
#    the pack; the CLI's --with-sources turns it back on).
# 5: provides in the manifest (DotCloudProvides), DotCloudScriptScan, DotCloudClient.session_tag / ensure_for_session
#    (uid_policy add_only, allow_root), mounted packs fill DotContentIndex. Needs dot-core API 9.
# 6: DotCloudWorkshop (workshop/): the sync client, DotCloudWorkshopConfig / List / Device, registry name dot_workshop.
# 7: DotCloudWorkshop.client_platform / request_platform / force_platform (the site reviews
#    script packs per platform).
# 8: DotCloudFile.side (client / server, signed in the manifest), DotCloudConfig.side and
#    resolved_side(), DotCloudManifest.fetch_side / side_counts(), DotCloudPublisher.side_rules
#    and the source's sides.json. An older build ignores the field and fetches both sides.
# 9: DotCloudManifest.bundle (one ZIP of the small objects, signed), DotCloudPublisher.write_bundle,
#    DotCloudConfig.use_bundles; the HTTP source's fetch_bundle. An older client ignores the field.
# 10: DotCloudSliceLoader.loaded / named_class_scripts, DotCloudClient.warm_content (its on_progress callable).
# 11: DotCloudPublisher.script_tokens_dir (pre-tokenized .gdc + .gd.remap in place of .gd text).
# 12: DotCloudAutoUpdate / DotCloudAutoUpdateConfig (server/): a dedicated server restarts onto newer packs.
# 13: DotCloudMirrorList (the site's signed mirrors.json, key scope _platform/mirrors), DotCloudConfig.mirrors_url /
#     use_mirrors / prefetch_max_bytes / prefetch_max_packs / prefetch_on_web, DotCloudClient.load_mirror_list /
#     mirror_list / mirror_alternatives / prefetch / parse_prefetch, DotCloudSourceHttp.mirror_list / bases_for
#     (published mirrors before the origin, per-base demotion; the breaker counts files, not bases).
# 14: DotCloudMirrorList.parse_signed(bytes, trusted_keys, now_unix, newest_seen): refuses a signed list older than the
#     newest accepted (replay of an old mirror list).
# 15: DotCloudManifest.dependencies (signed {id, version} list), DotCloudPublisher.dependencies / CLI --depends;
#     DotCloudClient acquires them first (skipped when mounted or already in the store). An older build ignores the field.
# 16: DotCloudSuggested, DotCloudWorkshop.suggested, workshop_suggested (config), DotCloudWorkshopDevice.suggested_mode:
#     a game's suggested packs (its map packs) mount by default for a solo session, with opt-outs.
# 17: DotCloudSuggested.MODE_ASK / asks / device_choice / mode_for_choice, DotCloudWorkshop.set_device_suggested_mode:
#     the per-device Off / Ask / Auto switch for suggested packs; ask prompts once through ask_fn and a refusal skips only those.
# 18: DotCloudJobProgress, DotCloudClient.job / begin_job / end_job / job_progress_changed (one overall bar for a many-pack job).
# 19: DotCloudConfig.parallel_packs (default 4), DotCloudDownloaderPool, DotCloudClient.pool: a collection's dependencies download side by side.
# 20: DotCloudClient.job_register / job_register_manifest / job_download / job_begin_unpack / read_pack_file, DotCloudJobProgress.begin_unpack /
#     note_unpacked (snapshot gains phase, unpack_done, unpack_total), DotCloudWorkshop.defer_mount / mount_pending: one outer job whose total
#     is fixed up front, every download first and every mount after. Additive; a caller that never opens an outer job is unchanged.
# 21: DotCloudInventoryReport (the account site's downloaded-content report body and its pending actions) and the
#     bridge's `sync` op. Additive.
# 22: grouped files are mounted, not only downloaded: DotCloudMounter.mount's `groups` option and covers' groups,
#     DotCloudClient.ensure_groups_at (a game's per-map top-up) and DotCloudFile.ALL_GROUPS ("*", every group). Additive.
const LEVEL := 22
const OLDEST := 1
