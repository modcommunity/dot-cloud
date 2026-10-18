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
const LEVEL := 6
const OLDEST := 1
