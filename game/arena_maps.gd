extends RefCounted

const ArenaPaths := preload("arena_paths.gd")

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
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
## a built-in map: it calls [method ArenaMap.by_id]. A [b]delivered[/b] map — one the
## server names, see [method delivered_def] — sets [member DotMapDef.content_id] and points
## its scene path at the manifest inside its pack, and is still built by `ArenaMap.by_id`
## once `ArenaMapSession` has fetched it, because the pack holds data, not a scene.
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
	# 1.3.0: the north-west stair moved 0.75 m east to meet the building, and the
	# arcade's last piers 0.5 m east to meet the crates — both closing slots narrower
	# than a player that `[gate-sweep-1]` found (2026-09-24).
	# 1.4.0: the north-west keep, a roofed room in red's half with a high point on
	# top, reached by a 2 m jump off the ring's north arm (2026-09-27).
	# 1.5.0: the east stair, twelve walked treads from the east yard up to the
	# landing's north face (2026-10-01).
	# 1.6.0: the rampart, a walkway from the keep's roof across red's half to the
	# perch's north face, on three piers (2026-10-04).
	&"dm_atrium": "1.6.0",
	# 1.1.0: the east-west bridge, the south-west shelf and the perch (2026-09-18).
	# [b]Backdated.[/b] That change moved the geometry and did not move the version,
	# so every record set on the one-bridge dm_pit is recorded against the two-bridge
	# one. Nothing can un-mix them now; what this entry buys is that the runs from here
	# are separable from both.
	# 1.2.0: the north-east crates rebuilt from two steps of 1.4 and 1.2 to three of
	# 0.9, same cause as dm_atrium's (2026-09-22).
	# 1.3.0: the three pillars in the pit moved from ±6 to ±5.75, closing two 0.75 m
	# pinches against the stairs that `[gate-sweep-1]` found (2026-09-24).
	# 1.4.0: the lookout on the east arm, a second high point facing the perch
	# (2026-09-26).
	# 1.5.0: the shelf stair, twelve treads from the pit floor up the shelf's east
	# face, meeting the south-east stair foot to foot; one spawn moved off its lane
	# (2026-09-30).
	&"dm_pit": "1.5.0",
	# 1.1.0: three crates to each of the two ledges, which had been standable geometry
	# with no way up since the map was written (2026-09-22).
	# 1.2.0: two gantries joining the ledges into a loop, and a nest on the pillars at
	# (4, -12) and (-4, 12), reached by one 0.9 m step off each gantry (2026-09-24).
	# 1.3.0: two nest stairs, ten walked treads from the floor up the outside of each
	# gantry to the foot of its nest pillar (2026-09-29).
	# 1.4.0: two corner stairs, ten walked treads along the north and south walls up to
	# a landing that carries each ledge on into its corner (2026-10-02).
	&"dm_box": "1.4.0",
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

	# The built-ins, then every imported combat surf map that was found — discovered by
	# `ArenaImportedMaps` off each manifest's own `kind`, not listed here either.
	for id in ArenaMap.ids() + ArenaMap.imported_ids():
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
	if map.is_imported():
		return _imported_def_for(id, map)

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


## The imported combat surf maps in the rotation when nothing says otherwise.
##
## [b]Christian's two, by name, because he named them[/b] ("small maps that don't need a
## timer and should be used in game-arena, since they are intended for deathmatch"): the
## rest are installed, loadable with `arena_map <id>` and offered by nothing until an
## operator lists them. `arena_imported_rotation` is the setting (`all`, `none`, or ids
## separated by commas), read into [member imported_rotation].
const IMPORTED_ROTATION_DEFAULT := "surf_10x_reloaded_fixed,surf_110b_austinpowers"

## Which imported maps the rotation, the vote and nominations may offer: `all`, `none`
## (or empty), or a comma-separated list of ids. See [constant IMPORTED_ROTATION_DEFAULT].
##
## A map left out is [member DotMapDef.enabled] false — the field dot-map's rotation pool,
## dot-vote's ballot and its nominations already read, which is how game-g2gfast keeps
## these same maps out of ITS rotation — and stays in the catalogue, so a change to it by
## name still works and a client still recognises it when a server plays it.
static var imported_rotation: String = IMPORTED_ROTATION_DEFAULT


## Whether imported map [param id] is in the rotation under [member imported_rotation].
static func in_rotation(id: StringName) -> bool:
	var wanted := imported_rotation.strip_edges().to_lower()

	if wanted == "all":
		return true

	if wanted == "" or wanted == "none":
		return false

	for part in imported_rotation.split(",", false):
		if StringName(part.strip_edges()) == id:
			return true

	return false


## Puts [member imported_rotation] onto an existing catalogue, for a setting changed on a
## running server. In place, because a rotation holds its catalogue by reference.
static func apply_rotation(catalogue: DotMapCatalogue) -> void:
	if catalogue == null:
		return

	for def in catalogue.maps:
		if bool(def.meta.get("imported", false)):
			def.enabled = in_rotation(def.id)


## An imported map as dot-map content.
##
## [b]Local, not delivered[/b] — no `content_id` — because on every machine that has it the
## map is files in this build's tree (the linked g2gfast-maps) that `ArenaMap.by_id`
## builds, exactly like a built-in. The version is its manifest's hash
## (`ArenaImportedMaps.version_of`), so a server and a client holding different imports of
## one map disagree at the announce instead of colliding against different brushes.
static func _imported_def_for(id: StringName, map: ArenaMap) -> DotMapDef:
	var def := DotMapDef.new()
	def.id = id
	def.version = ArenaImportedMaps.version_of(id)
	def.display_name = map.display_name
	def.kind = DotMapDef.KIND_ARENA
	def.scene_path = BUILDER_PATH
	def.author = map.author if map.author != "" else "unknown"
	def.enabled = in_rotation(id)
	def.tier = clampi(int(map.extent / 32.0), 1, 10)
	def.description = "Combat surf, %d spawns, %.0f m across." % [
		map.spawns.size(), maxf(map.bounds.size.x, map.bounds.size.z)
	]
	def.meta = {
		"builder": "ArenaMap.by_id",
		"spawns": map.spawns.size(),
		"teams": _has_team_spawns(map),
		"imported": true,
		"manifest": map.manifest_path,
		"movement": String(map.movement_profile),
	}
	return def


# --- Delivered: the maps the server names --------------------------------

## Where dot-cloud mounts every pack. dot-cloud's own constant, spelled out so this file
## parses in a build that does not link it.
const MOUNT_ROOT := "res://dot_cloud/"

## Keys the server named whose pack turned out not to be an arena map, so a refresh does
## not offer them again (and does not warn again).
static var _refused_keys: Dictionary = {}


## The pack keys (`<owner>/<map id>@<version>`) the server names for the running game:
## [code]server.games.current_maps()[/code], which dot-server-deploy's `cfg/content.yml`
## fills. Duck-typed, so a dot-server that predates the field — or a stand-in in a suite —
## is an empty list rather than a parse error.
##
## [b]Not dot-game's `DotGameContent.map_keys`[/b], which says the same thing, because this
## game does not link dot-game: its module is a `DotModule`, and pulling an addon into the
## client shell's dependency list for six lines of duck typing is the wrong trade.
static func server_map_keys(server: Object) -> PackedStringArray:
	var out := PackedStringArray()
	var games: Variant = server.get("games") if server != null else null

	if not (games is Object) or not (games as Object).has_method("current_maps"):
		return out

	for key: Variant in (games as Object).call("current_maps"):
		if not out.has(str(key)):
			out.append(str(key))

	return out


## A map the server names, as dot-map content: delivered, not downloaded.
##
## [b]Built from the key alone[/b], because nothing else is on the disk yet: these packs are
## a megabyte to five each and a server that fetched every one at boot would sit
## unreachable while it did, so a pack is fetched when the map is changed to
## (`ArenaMapSession`), as game-g2gfast fetches its own. So the def says what the key says
## — id, content id, version — and nothing measured: no spawn count, no size, untagged, so
## the team modes are refused by the existing rule and the box-built modes by `imported`.
##
## [b]The version is the pack's, not the manifest's hash.[/b] A local import is hashed
## because nobody versions a link; a pack is versioned by whoever published it, the server
## named exactly that version, and a client is told it in the announce and fetches it from
## its own origin — so both ends agree on the bytes by construction, and a republish is a
## new version by dot-cloud's rule. Hashing would need the manifest before the fetch.
##
## [b]The scene path is the manifest inside the mount[/b] (`<mount>/<id>.json`): the file
## [ArenaMap] is built from, and inside the pack's own content — which is what lets a client
## that has never heard of the map accept it (`DotMapSyncClient` takes an unknown map only
## when its scene is under its mount). Null when the key is not `<owner>/<id>@<version>`.
static func delivered_def(key: String) -> DotMapDef:
	var def := DotMapDef.from_content_key(key)

	if def == null or def.content_version == "":
		return null

	def.scene_path = manifest_in_mount(def)
	def.version = def.content_version
	def.display_name = String(def.id)
	def.kind = DotMapDef.KIND_ARENA
	def.author = "unknown"
	def.enabled = in_rotation(def.id)
	def.tier = 1
	def.description = "Combat surf, delivered as %s." % key
	def.meta = {
		"builder": "ArenaMap.by_id",
		"imported": true,
		"delivered": true,
		"key": key,
		"teams": false,
		"movement": "surf",
	}
	return def


## `res://dot_cloud/<content id>/<version>`, where [param def]'s pack mounts.
static func mount_of(def: DotMapDef) -> String:
	return "%s%s/%s" % [MOUNT_ROOT, String(def.content_id), def.effective_content_version()]


## `<mount>/<id>.json`: the manifest a delivered map is built from.
static func manifest_in_mount(def: DotMapDef) -> String:
	return mount_of(def).path_join("%s.json" % String(def.id))


## Whether [param def] is one of this game's delivered maps: content, and its scene the
## manifest in its own mount. Structural rather than a meta flag, because a def from a host
## carries whatever meta the host wrote; the mount is checked plain by `DotMapSyncClient`.
static func is_delivered(def: DotMapDef) -> bool:
	return (
		def != null and not def.is_local()
		and String(def.content_id).get_file() == String(def.id)
		and def.scene_path == manifest_in_mount(def)
	)


## Makes [param catalogue]'s delivered maps the ones [param keys] names: adds each one not
## there (replacing a local import of the same id, because the server named a version and a
## client without the link can only fetch a pack), and removes each delivered map no longer
## named (putting back a local import of that id, when this machine has one). Returns how
## many were added and removed. [param playing] is the map running now: it leaves the
## catalogue like any other, but its mount stays registered, because the running game
## rebuilds its solid from that manifest on a mode change.
##
## [b]A pack already on the disk is checked now[/b]: one whose manifest is not
## `"kind": "arena"` is skipped with one warning. One not fetched yet is checked when it is
## (`ArenaMapSession`), and leaves the catalogue then. A built-in map's id is never
## replaced: `ArenaMap.by_id` would build the built-in whatever the catalogue said.
static func adopt_delivered(
	catalogue: DotMapCatalogue, keys: PackedStringArray, playing: StringName = &""
) -> Dictionary:
	var added := 0
	var removed := 0

	if catalogue == null:
		return {"added": 0, "removed": 0}

	var named: Dictionary = {}

	for key in keys:
		var def := delivered_def(key)

		if def == null:
			DotLog.warn(CHANNEL, "a map the server names is not <owner>/<map>@<version>", {"entry": key})
			continue

		if ArenaMap.ids().has(def.id):
			DotLog.warn(CHANNEL, "a map the server names has a built-in map's id, and is skipped", {
				"pack": key,
			})
			continue

		if _refused_keys.has(key):
			continue

		var on_disk := ArenaImportedMaps.kind_at(def.scene_path)

		if FileAccess.file_exists(def.scene_path) and on_disk != ArenaImportedMaps.KIND:
			refuse(key, on_disk)
			continue

		named[def.id] = key
		var existing := catalogue.get_map(def.id)

		if existing != null and str(existing.meta.get("key", "")) == key:
			continue

		var res := catalogue.add(def)

		if res.ok:
			added += 1
		else:
			DotLog.warn(CHANNEL, "a map the server names could not be catalogued", {
				"pack": key, "why": res.error.message,
			})

	for def in catalogue.maps.duplicate():
		if not bool(def.meta.get("delivered", false)) or named.has(def.id):
			continue

		catalogue.remove(def.id)
		removed += 1

		if def.id != playing:
			ArenaImportedMaps.remove_mounted(def.id)

		var local := ArenaMap.imported(def.id)

		if local != null:
			var _put_back := catalogue.add(_def_for(def.id, local))

	if added > 0 or removed > 0:
		DotLog.info(CHANNEL, "the server's maps are in the catalogue", {
			"added": added, "removed": removed, "named": keys.size(),
		})

	return {"added": added, "removed": removed}


## Records that the pack [param key] is not an arena map, once, with the one warning.
static func refuse(key: String, kind: String) -> void:
	if _refused_keys.has(key):
		return

	_refused_keys[key] = true
	DotLog.warn(CHANNEL, "a map the server names is not an arena map, and is skipped", {
		"pack": key, "kind": kind if kind != "" else "(none)",
	})


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

	# An imported map has no box list, and the monsters' navigation, the objectives'
	# layout and the scattered props are all built out of one. Offered such a mode it
	# would build a hill in mid-air and a navmesh of nothing, so it hosts the modes that
	# are only about the players: free-for-all, gun game, a weapon pool.
	if bool(def.meta.get("imported", false)) and needs_built_world(mode):
		return false

	if not mode.is_team_mode():
		return true

	return bool(def.meta.get("teams", false))


## Whether [param mode] builds a layer out of a built-in map's boxes: monsters,
## objectives or props.
static func needs_built_world(mode: ArenaMode) -> bool:
	return (
		mode.horde or mode.objective_layout != &""
		or mode.player_props or mode.scatter_props > 0
	)
