extends DotMapSession

const ArenaGame := preload("res://game/arena_game.gd")
const ArenaMap := preload("res://maps/arena_map.gd")
const ArenaMaps := preload("res://game/arena_maps.gd")
const ArenaMode := preload("res://game/arena_mode.gd")
const ArenaModes := preload("res://game/arena_modes.gd")

## A [DotMapSession] whose maps are built rather than loaded.
##
## [b]dot-map assumes a map is a scene, and this game's maps are not.[/b]
## [method DotMapSession.change_to_map] calls [DotMapLoader], which `load()`s
## [member DotMapDef.scene_path] and casts the result to a [PackedScene] — and an arena
## map's "scene path" names [code]arena_map.gd[/code], the script that produces it. Cast
## a [GDScript] to a [PackedScene] and you get null, and the next line calls
## `instantiate()` on it.
##
## So the load half is overridden and [b]nothing else is[/b]. The catalogue, the
## rotation and its cooldown, the map time limit, rock-the-vote, the extension rules,
## and the whole [DotMapSyncHost] announce/wait/swap protocol all sit on top of this
## unchanged, because none of them ever opens a scene: they work on an id and a version.
##
## [b]The delivered path is kept, not removed.[/b] A map with a
## [member DotMapDef.content_id] is content dot-cloud fetches and mounts, and there is
## no reason this game could not have one — so a non-local map falls through to
## [method DotMapSession.change_to_map] with `super`. The override is for the built-ins,
## which is exactly the set [method ArenaMap.by_id] knows how to make.
##
## [codeblock]
## var session := ArenaMapSession.new()
## session.game = arena_game
## session.catalogue = ArenaMaps.catalogue()
## add_child(session)
## await session.change_to(&"dm_atrium")
## [/codeblock]

## Log channel. Deliberately not named CHANNEL: [DotMapSession] already declares one
## and GDScript refuses a constant that shadows a parent's.
const LOG_CHANNEL := "arena.map.session"

## The game whose world is replaced. Required.
##
## Assigned rather than resolved through a [DotNodeRef] because this is not a component
## a host wires into an arbitrary scene: an [ArenaMapSession] with no [ArenaGame] has
## nothing to do at all, and a null here should fail at the change rather than resolve
## to some other node that happens to be in the right place.
var game: ArenaGame = null

## The mode to switch to along with the map, when the map names one.
##
## Read out of [code]DotMapDef.meta.mode[/code], which is how a rotation entry says
## "play team deathmatch on this one". Null means keep the mode that is running.
var mode_from_meta: bool = true


func change_to_map(map: DotMapDef) -> DotResult:
	if map == null:
		return DotResult.fail(DotError.CODE_INVALID, "No map.")

	if not map.is_local():
		# Delivered content. dot-cloud fetches it, dot-map mounts it, and the base
		# class does the rest — there is nothing arena-specific about a map that
		# really is a scene.
		return await super.change_to_map(map)

	if game == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"This map session has no ArenaGame to change.",
			String(map.id)
		)

	if changing_now:
		return DotResult.fail(
			DotError.CODE_STATE,
			"A map change is already in progress.",
			String(map.id)
		)

	var built := ArenaMap.by_id(map.id)

	if built == null:
		return DotResult.fail(
			DotError.CODE_IO,
			"The catalogue names a map ArenaMap cannot build.",
			String(map.id)
		)

	var wanted := _mode_for(map)

	# What will actually be played here, which is NOT the same question. `wanted` is
	# only ever set when the map def names a mode, and no map in this game does — so
	# for as long as the check below read `wanted`, it was guarding a case that never
	# arose while the case that did arise walked straight past it.
	var playing := _mode_after(map)

	if playing != null and not ArenaMaps.supports_mode(map, playing):
		# Refused rather than warned. A team mode on a map with no tagged spawns puts
		# both sides in one pool, which on a symmetric map means spawning in the enemy
		# base about half the time — and it reads as a spawn-selection bug for as long
		# as anybody is prepared to look at it.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That map has no tagged spawns, so it cannot host a team mode.",
			"%s / %s" % [String(map.id), String(playing.id)]
		)

	changing_now = true

	var previous := current

	# Before anything is torn down, exactly as the base class does it: this is what a
	# netcode listens to so it can stop replicating entities that are about to be
	# freed, and a renderer listens to so it can drop the meshes it is drawing.
	changing.emit(previous, map)

	var changed := game.change_map(built, wanted)

	if not changed.ok:
		changing_now = false
		change_failed.emit(map, changed.error.message)
		return changed

	# The visible half, and only where there is one. A dedicated server has no
	# `world_ref` and needs no meshes; a client and a listen server do, and the meshes
	# come from the same box list the collision does — which is the invariant this
	# whole project is arranged around.
	var world_result := _swap_world(built, map)

	if not world_result.ok:
		changing_now = false
		change_failed.emit(map, world_result.error.message)
		return world_result

	current = map

	# No zones. dot-timer is not in this game; an arena map's "zones" are its spawn
	# points, and those come from ArenaMap with the geometry.
	zones_json = ""

	rotation.note_played(map.id)

	time_limit.start(
		float(map.expected_seconds) * 3.0 if map.expected_seconds > 0 else -1.0
	)

	changing_now = false

	DotLog.info(LOG_CHANNEL, "arena map built", {
		"map": String(map.id),
		"mode": String(wanted.id) if wanted != null else "unchanged",
		"boxes": built.boxes.size(),
	})

	changed_world()

	return DotResult.success(world)


## Replaces the meshes, where this deployment draws any.
##
## [b]`free()`, not `queue_free()`.[/b] The new world is added in this same call and a
## deferred free leaves both in the tree for a frame — two maps' worth of static bodies
## in one physics space, and any group lookup finding whichever it reached first. The
## base class says the same thing at its own teardown.
func _swap_world(built: ArenaMap, def: DotMapDef) -> DotResult:
	if world_ref == null:
		# Nothing draws here. Not a failure: it is what a dedicated server looks like,
		# and `ArenaGame.change_map` has already replaced everything that matters.
		return DotResult.success(null)

	var resolved := _resolve_world_parent()

	if not resolved.ok:
		return resolved

	var parent: Node = resolved.value

	if world != null and is_instance_valid(world):
		world.get_parent().remove_child(world)
		world.free()

	world = built.to_scene()
	world.name = "Map_" + String(def.id)
	parent.add_child(world)

	return DotResult.success(world)


## Emits [signal DotMapSession.changed] with what this session actually built.
##
## A method rather than the emit inline, because `world` is legitimately null on a
## dedicated server and a listener that assumed otherwise would break on the deployment
## shape that matters most.
func changed_world() -> void:
	changed.emit(current, world)


## The mode a map def asks for, or null to keep the current one.
## The mode that will be played on [param map] once the change is done.
##
## The map's own when it names one, and otherwise the one already running — because
## changing the map does not change the mode, and "which mode is this map about to
## have to host" is the only form of the question worth refusing on.
##
## [b]Separate from [method _mode_for] deliberately.[/b] That one answers "what should
## this change set the mode to", and null there means "leave it alone" rather than
## "there is no mode". Reading it as the second was how a free-for-all-only map could
## be rotated into the middle of a team game with nothing said.
func _mode_after(map: DotMapDef) -> ArenaMode:
	var named := _mode_for(map)

	if named != null:
		return named

	return game.mode if game != null else null


func _mode_for(map: DotMapDef) -> ArenaMode:
	if not mode_from_meta:
		return null

	var wanted := String(map.meta.get("mode", ""))

	if wanted == "":
		return null

	var found := ArenaModes.by_id(StringName(wanted))

	if found == null:
		DotLog.warn(LOG_CHANNEL, "a map names a mode that does not exist", {
			"map": String(map.id), "mode": wanted
		})

	return found
