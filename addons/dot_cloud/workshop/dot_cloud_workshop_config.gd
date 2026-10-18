@tool
class_name DotCloudWorkshopConfig
extends DotConfig

## Everything configurable about the Workshop sync client.
##
## Layered like every [DotConfig]: exported defaults, then a JSON file, then
## [code]DOT_CLOUD_WORKSHOP_*[/code] environment variables, then [code]--cloud-workshop-*[/code]
## arguments. These are a device's settings; the site's subscription list is not configuration and
## is never read from here.

## Off: [method DotCloudWorkshop.sync] succeeds with nothing mounted, and the panel says the
## Workshop is off on this build.
@export var workshop_enabled: bool = true

## The site origin. The shell passes its dot-auth backbone url; nothing a page supplies belongs here.
@export var workshop_backbone_url: String = ""

## [code]never[/code], [code]approved[/code] or [code]any[/code]: whether a pack that runs code
## is mounted. [code]approved[/code] needs the site's reviewers to have approved that version;
## [code]any[/code] (site-signed, unreviewed) is for a developer testing their own pack.
@export var workshop_script_packs: String = "approved"

## The [code]key_id[/code]s a subscription manifest must be signed with. A key trusted for a
## server's content is not thereby trusted for a stranger's subscription.
@export var workshop_key_ids: PackedStringArray = PackedStringArray(["tmc"])

## [code]ask[/code], [code]allow[/code] or [code]never[/code]: what to do on a metered connection.
## A device override (see [DotCloudWorkshopDevice]) wins over this.
@export var workshop_metered: String = "ask"

## Download size above which the player is asked on [code]ask[/code], metered or not.
@export var workshop_ask_over_bytes: int = 52428800

## The list request's timeout; past it the cached list is used.
@export_range(1.0, 120.0, 0.5) var workshop_timeout_sec: float = 10.0

## The most packs one launch will mount.
@export var workshop_max_packs: int = 200


func env_prefix() -> String:
	return "DOT_CLOUD_"


func cli_prefix() -> String:
	return "--cloud-"


func validate() -> DotResult:
	if not ["never", "approved", "any"].has(workshop_script_packs):
		return DotResult.fail(
			DotError.CODE_INVALID, "workshop_script_packs must be never, approved or any.",
			workshop_script_packs
		)
	if not ["ask", "allow", "never"].has(workshop_metered):
		return DotResult.fail(
			DotError.CODE_INVALID, "workshop_metered must be ask, allow or never.", workshop_metered
		)
	if workshop_max_packs < 0:
		return DotResult.fail(DotError.CODE_INVALID, "workshop_max_packs must not be negative.")
	return DotResult.success(null)
