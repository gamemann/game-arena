extends Node

const ArenaAvatars := preload("arena_avatars.gd")

## Who a player is: content delivery, a profile, an avatar, and one admission flow.
##
## [b]Five addons, assembled in the order they depend on each other, and the order is
## the only difficult part.[/b]
##
## [codeblock]
## dot-cloud    downloads and mounts content. Registers `dot_cloud_client`.
## dot-auth     proves who somebody is to the backbone, and reports back to it.
## dot-user     the profile that follows a player between servers.
## dot-avatar   what they look like, as a document.
## dot-platform joins the three into ONE admission, and binds it to a dot-server.
## [/codeblock]
##
## [b]dot-cloud first, and registered, because four call sites in two other addons look
## it up by name.[/b] `DotCloudClient` once did not publish itself in [DotRegistry] at
## all, and dot-server, dot-user-avatar and dot-map all found null — so a client could
## never download content, a game change never released any, and a cosmetic delivered
## through the cloud was unreachable. None of them errored, because every one of them
## treats an absent cloud as "this deployment ships its content in its build", which is
## a legitimate configuration and therefore indistinguishable from the bug.
##
## [b]This game ships all its content in its build, and that is exactly why the cloud
## client is still built.[/b] The path that is only reached by one deployment shape is
## the path nothing has run.
##
## [codeblock]
## var identity := ArenaIdentity.new()
## add_child(identity)
## identity.setup()
## server.modules.load_module(identity.platform_module())
## [/codeblock]

const CHANNEL := "arena.identity"

@export_group("Content")

## Where delivered content is fetched from. Empty means everything ships in the build.
@export var content_urls: PackedStringArray = PackedStringArray()

## Directories searched before the network. A server serving content off its own disk.
@export var content_dirs: PackedStringArray = PackedStringArray()

@export_group("Backbone")

## Report the player count, the map and the roster to the site listing.
##
## Off by default. A server that phones home without its operator asking is a server
## nobody would run, and dot-auth's own defaults agree.
@export var report_to_backbone: bool = false

## Where the backbone is. Left empty, [DotAuthConfig]'s own default is used.
##
## [b]A default endpoint is a security property, not a convenience.[/b] dot-auth once
## shipped `themodcommunity.com`, which is not the site — the site is
## `moddingcommunity.com` — and was registered to nobody. Every deployment that did not
## override it aimed the opening request of an authentication flow at a name any
## stranger could buy. It failed loudly only because the name did not resolve.
@export var backbone_url: String = ""

@export_group("Admission")

## Refuse a player whose profile could not be resolved.
##
## Off. An unreachable profile store is a reason to let somebody play as a guest, not a
## reason to leave them at a loading screen — the same call `ArenaGame.apply_loadout`
## makes about a loadout store.
@export var require_profile: bool = false

var cloud: DotCloudClient = null
var users: DotUserManager = null
var avatars: DotAvatarManager = null
var platform: DotPlatformHub = null
var backbone: DotBackboneClient = null

var _module: DotPlatformModule = null


## Builds the whole chain. Returns the platform hub.
func setup() -> DotResult:
	var clouded: DotResult = await _build_cloud()

	if not clouded.ok:
		return clouded

	if report_to_backbone:
		# Not fatal. A server that cannot reach the backbone is a server that runs
		# without a site listing, which is every LAN server there has ever been.
		var reached: DotResult = await _build_backbone()
		DotLog.result(CHANNEL, "the backbone client", reached)

	var usered: DotResult = await _build_users()

	if not usered.ok:
		return usered

	var avatared: DotResult = await _build_avatars()

	if not avatared.ok:
		return avatared

	var platformed: DotResult = await _build_platform()
	return platformed


func _build_cloud() -> DotResult:
	if content_urls.is_empty() and content_dirs.is_empty():
		# [b]No sources means no client, and building one anyway is worse than not.[/b]
		# `DotCloudClient.start` refuses when `require_signed_manifests` is on and no
		# trusted key is configured — correctly, because a client that mounts unsigned
		# content will mount anything a server sends it — and it says so with a red
		# error line on every boot.
		#
		# The four call sites that look this up under `dot_cloud_client` all treat an
		# ABSENT cloud as "this deployment ships its content in its build", which is
		# true here and is a legitimate configuration. A registered client that failed
		# to start is a different thing: present, found, and unable to do anything —
		# and the error it prints on every boot is the shape this family calls "a
		# warning that reads like a setting nobody has filled in".
		DotLog.info(CHANNEL, "content ships in this build", {
			"reason": "no content sources are configured"
		})
		return DotResult.success(null)

	cloud = DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.http_base_urls = content_urls
	cloud.local_search_dirs = content_dirs
	# Registered, and this is the line whose absence cost four silent failures. See
	# the class note.
	cloud.register_service = true
	add_child(cloud)

	# Awaited, and typed. Every one of these is a coroutine because every one of them
	# may reach a network — a content source, a profile store, an avatar store — and an
	# un-awaited GDScript coroutine returns at its first suspension, so the branch
	# below would be testing a property of a Signal.
	var started: DotResult = await cloud.start()

	if not started.ok:
		# Downgraded rather than fatal: with no sources configured there is nothing
		# for it to do, and a game whose content ships in its build is the ordinary
		# case rather than a broken one.
		DotLog.info(CHANNEL, "content delivery is off", {
			"why": started.error.message
		})

	return DotResult.success(cloud)


func _build_backbone() -> DotResult:
	var config := DotAuthConfig.new()

	if backbone_url != "":
		config.backbone_url = backbone_url

	backbone = DotBackboneClient.new()
	backbone.name = "Backbone"
	backbone.config = config
	backbone.auto_report = true
	add_child(backbone)

	var ready: DotResult = await backbone.start()
	return ready


func _build_users() -> DotResult:
	users = DotUserManager.new()
	users.name = "Users"
	users.register_service = true
	add_child(users)

	var ready: DotResult = await users.setup()
	return ready


func _build_avatars() -> DotResult:
	avatars = DotAvatarManager.new()
	avatars.name = "Avatars"
	avatars.schema = ArenaAvatars.schema()
	avatars.register_service = true
	add_child(avatars)

	var ready: DotResult = await avatars.setup()
	return ready


func _build_platform() -> DotResult:
	var config := DotPlatformConfig.new()
	config.require_profile = require_profile
	# Never. An avatar is cosmetic and a player without one gets a stock document that
	# is a real avatar over the same schema — refusing them would be refusing somebody
	# for the colour of a capsule.
	config.require_avatar = false
	config.apply_profile_name = true
	config.broadcast_avatar_changes = true

	platform = DotPlatformHub.new()
	platform.name = "Platform"
	platform.config = config
	platform.load_layered_config = false
	platform.register_service = true
	add_child(platform)

	var ready: DotResult = await platform.setup()
	return ready


## The module a [DotServer] loads to put this in front of joining players.
##
## dot-platform ships its own [DotModule], which is the right shape: everything it
## registers is removed again when it unloads, and a game that wanted a different
## admission flow replaces one module rather than editing another.
func platform_module() -> DotPlatformModule:
	if _module == null:
		_module = DotPlatformModule.new()
		_module.platform = platform

	return _module


## An avatar for a player, theirs if they have one and a stock one if not.
##
## [b]Never null, and that is the contract.[/b] A caller that had to branch on "did
## this player have an avatar" would be a caller that draws nothing for a guest, and a
## server full of invisible guests is worse than one full of identical ones.
func avatar_for(player_key: String) -> DotAvatar:
	if platform != null:
		var held := platform.player(player_key)

		if held != null and held.avatar != null:
			return held.avatar

	return ArenaAvatars.stock_avatar(StringName(player_key))


func describe() -> Dictionary:
	return {
		"cloud": cloud.describe() if cloud != null else {},
		"users": users.describe() if users != null else {},
		"avatars": avatars.describe() if avatars != null else {},
		"platform": platform.describe() if platform != null else {},
		"backbone": backbone.describe() if backbone != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if platform != null:
		out.append_array(platform.describe_lines())

	if users != null:
		out.append_array(users.describe_lines())

	if avatars != null:
		out.append_array(avatars.describe_lines())

	return out
