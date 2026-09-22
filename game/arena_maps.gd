extends RefCounted

const ArenaPaths := preload("arena_paths.gd")

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("arena_mode.gd")

## This game's maps as dot-map content: a catalogue, a rotation and a vote can address.
##
## [b]The awkward part is honest and worth naming.[/b] dot-map's whole design is that a
## map is content — an id, a version and a [b]scene path[/b] — and this game's maps are
## not scenes. [ArenaMap] builds them in code, on purpose, because "the headless test
## and the played game must get the same map" and a `.tscn` instantiated in one and
## hand-built in the other is two maps that drift. So [member DotMapDef.scene_path]
## here names [b]the script that actually produces the map[/b] rather than a scene, and
## [code]meta.builder[/code] says so out loud.
##
## That is not a workaround for dot-map; it is the seam. Everything dot-map does with a
## map def — rotation, cooldowns, nominations, ballots, the announce/ready/load
## protocol — works on the id and the version and never opens the scene. The only thing
## that reads `scene_path` is [DotMapLoader], and [ArenaMapDirector] does not use it for
## a built-in map: it calls [method ArenaMap.by_id]. A [b]delivered[/b] arena map would
## set [member DotMapDef.content_id], [member DotMapDef.manifest_url] and a real scene
## path, and the loader would take over with nothing else changing.
##
## The path is a real file rather than a sentinel deliberately. A catalogue full of
## `code://` strings is a catalogue no validator can ever check; this one points at
## something that must exist, so a map def that survives a file being deleted is a map
## def that fails rather than one that fails later, elsewhere, at a load.

const CHANNEL := "arena.maps"

## The file that builds every map in this catalogue.
static var BUILDER_PATH := ArenaPaths.rebase(ArenaPaths.rebase("res://maps/arena_map.gd"))

## What a map is at, when nothing says otherwise.
##
## Every map starts here and leaves when its geometry moves.
const MAP_VERSION := "1.0.0"

## Per-map versions, for the maps that have moved on from [constant MAP_VERSION].
##
## [b]Per map, not one constant for the catalogue, and that distinction is the whole
## point of the field.[/b] A record and a rotation cooldown are both about a map AT a
## version, so geometry that moved under one id is a different map wearing the same
## name and has to say so. A single shared constant could only say it about all three
## at once — bumping it because `dm_atrium` grew an arcade would also declare `dm_box`
## and `dm_pit` to be new maps, which invalidates two sets of records to describe a
## change neither map had.
##
## A map absent from here is at [constant MAP_VERSION]; that is the common case and it
## is why this is a lookup rather than a column every map has to fill in.
const MAP_VERSIONS := {
	# 1.1.0: the south arcade, the stair onto its roof, and the doorway cut in the
	# bunker's east wall to reach it (2026-09-16).
	# 1.2.0: the south-east crates rebuilt from three steps of 1.5 m to five of 0.9,
	# because a jump here peaks at 1.25 and the route had never been climbable
	# (2026-09-22).
	&"dm_atrium": "1.2.0",
	# 1.1.0: the east-west bridge, the south-west shelf and the perch (2026-09-18).
	# [b]Backdated.[/b] That change moved the geometry and did not move the version,
	# so every record set on the one-bridge dm_pit is recorded against the two-bridge
	# one. Nothing can un-mix them now; what this entry buys is that the runs from here
	# are separable from both.
	# 1.2.0: the north-east crates rebuilt from two steps of 1.4 and 1.2 to three of
	# 0.9, same cause as dm_atrium's (2026-09-22).
	&"dm_pit": "1.2.0",
	# 1.1.0: three crates to each of the two ledges, which had been standable geometry
	# with no way up since the map was written (2026-09-22).
	&"dm_box": "1.1.0",
}


## Every built-in map, as dot-map content.
##
## Built from [method ArenaMap.ids] rather than listed here. [b]A second list of the
## maps is the bug this family has now shipped four times[/b] — `setup.sh`,
## `tools/check.sh`, `tools/package_check.sh` and bootstrap all carried one and all
## four went stale — and the fix has always been the same: read it from the one place
## that cannot, which is the code that makes the maps.
static func catalogue() -> DotMapCatalogue:
	var out := DotMapCatalogue.new()
	out.meta = {"game": "arena"}

	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)

		if map == null:
			continue

		if map.id != id:
			# `ids()` is kept beside `by_id` deliberately — a map in one and not the
			# other is a map that either cannot be listed or cannot be loaded — and
			# this is the third statement of that same id. A mismatch here means a
			# catalogue entry addressed by a name the builder does not answer to,
			# which fails at the change rather than at the boot.
			DotLog.warn(CHANNEL, "a map's own id disagrees with the one it is listed under", {
				"listed": String(id), "built": String(map.id)
			})
			continue

		var added := out.add(_def_for(id, map))

		if not added.ok:
			DotLog.warn(CHANNEL, "a map could not be catalogued", {
				"map": String(id), "why": added.error.message
			})

	return out


static func _def_for(id: StringName, map: ArenaMap) -> DotMapDef:
	var def := DotMapDef.new()
	def.id = id
	def.version = MAP_VERSIONS.get(id, MAP_VERSION)
	def.display_name = map.display_name
	def.kind = DotMapDef.KIND_ARENA
	def.scene_path = BUILDER_PATH
	def.author = "dot"
	def.enabled = true

	# The tier is a difficulty in a timer game and a size here, and dot-map does not
	# care which — it is an integer a nomination filter and a ballot can sort on. One
	# is a room, ten is a complex. Derived from the map's own extent rather than
	# written down, for this file's own reason.
	def.tier = clampi(int(map.extent / 8.0), 1, 10)

	def.description = "%d boxes, %d spawns, %.0f m across." % [
		map.boxes.size(), map.spawns.size(), map.extent * 2.0
	]

	def.meta = {
		"builder": "ArenaMap.by_id",
		"spawns": map.spawns.size(),
		# Whether the map has tagged spawns, which is what decides if a team mode can
		# be played on it at all. A ballot reads this to keep team deathmatch off a
		# map where both sides would share one pool — the symptom of which is
		# "the sides keep spawning in each other's base", and it reads as a
		# spawn-selection bug rather than as an untagged map.
		"teams": _has_team_spawns(map),
	}

	return def


## Whether a map can host a team mode: some spawn is tagged.
static func _has_team_spawns(map: ArenaMap) -> bool:
	for index in range(map.spawns.size()):
		if map.spawn_tag(index) != &"":
			return true

	return false


## Whether [param def] can host [param mode], by that one property.
##
## Used by [ArenaVote] to build a ballot and by [ArenaMapDirector] to pick the next
## map. A free-for-all runs anywhere; a team mode needs somewhere to put the sides.
static func supports_mode(def: DotMapDef, mode: ArenaMode) -> bool:
	if def == null or mode == null:
		return false

	if not mode.is_team_mode():
		return true

	return bool(def.meta.get("teams", false))
