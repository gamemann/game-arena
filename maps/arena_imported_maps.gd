extends RefCounted

const ArenaPaths := preload("../game/arena_paths.gd")
const ArenaBspMap := preload("arena_bsp_map.gd")

## The imported maps this game plays: every manifest under the roots below whose
## `"kind"` is `"arena"` — the combat surf maps game-g2gfast keeps out of its own rotation
## because they are built to fight on rather than to time.
##
## [b]Discovered, never listed.[/b] A second list of map ids is the bug this family has
## shipped four times, and the manifest already says what a map is for: g2gfast writes
## `"kind": "arena"` into it (from its `maps/zones/<id>.json`) precisely so this game can
## find them. A map re-classified there is picked up or dropped here with nothing edited.
##
## [b]The format is g2gfast's.[/b] `<root>/<id>/<id>.json` beside `<id>.bin`, a lightmap
## and `textures/`, read by [ArenaBspMap]. The roots are `res://maps/imported` (the
## g2gfast-maps repository, linked in by dot-bootstrap at the same path g2gfast links it,
## so the `.import` markers written there are right here too) and `user://maps`, where a
## map that arrived at runtime would be; the first root that has an id wins, so a map in
## the build is never silently replaced by one dropped in beside it.
##
## A checkout without the link has none, and every caller treats an empty list as the
## supported state it is: the three built-in maps still play.
##
## [b]A delivered map is registered by its directory, not found under a root.[/b] A map the
## SERVER names (`<owner>/<id>@<version>` in [member DotGameDescriptor.maps]) is its own
## dot-cloud pack, mounted at `res://dot_cloud/<owner>/<id>/<version>/` with `<id>.json`
## and `<id>.bin` directly inside — the directory is named for the version, the files for
## the map, so a scan of `<root>/<name>/<name>.json` pointed at a mount silently finds
## nothing (game-g2gfast found the same thing and wrote `G2GMapCatalogue.at_directory`).
## [method add_mounted] takes the id and the directory, which the caller already has
## because it is the key it fetched. A mounted map is not in [method ids] — the catalogue
## offers it as delivered content, under its pack version, not as a local import — and it
## WINS over a copy of the same id under a root, because the server named that version and
## a client that fetched the same pack must build the same brushes.

## The manifest `kind` that marks a map for this game.
const KIND := "arena"

## The text that says so, searched for before a manifest is parsed. Eleven megabytes of
## manifests sit under the link and nine in ten of them are timer maps this game will
## never load; finding the word first and parsing only those that have it is the
## difference between a catalogue built in a frame and one built in a second. A hit is
## still parsed and checked, because the text could be inside a comment field.
const _KIND_TEXT := "\"kind\": \"arena\""

## id -> manifest path, once scanned.
static var _paths: Dictionary = {}
static var _scanned := false

## id -> the parsed manifest. A manifest is up to a megabyte of JSON and the catalogue,
## the client's catalogue and every map change all ask for the same ten.
static var _manifests: Dictionary = {}

## id -> version string, from the manifest's own bytes.
static var _versions: Dictionary = {}

## id -> the mount directory of a delivered map. See [method add_mounted].
static var _mounted: Dictionary = {}


## Where manifests are looked for, in order.
static func roots() -> PackedStringArray:
	return PackedStringArray([ArenaPaths.rebase("res://maps/imported"), "user://maps"])


## Every importable arena map, sorted, so two machines list them in one order.
static func ids() -> Array[StringName]:
	_scan()
	var out: Array[StringName] = []

	for id: Variant in _paths:
		out.append(StringName(str(id)))

	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return out


static func has(id: StringName) -> bool:
	_scan()
	return _paths.has(String(id))


## The manifest's path, or empty when there is no such map. A mounted map's when there
## is one (see [method add_mounted]), else the first root's.
static func manifest_path(id: StringName) -> String:
	var key := String(id)

	if _mounted.has(key):
		return str(_mounted[key]).path_join("%s.json" % key)

	_scan()
	return str(_paths.get(key, ""))


## Registers a delivered map's mount directory for [param id], so [method manifest] and
## `ArenaMap.imported(id)` read it from there. Fails, and registers nothing, when the
## directory has no `<id>.json` and `<id>.bin`, or when the manifest's kind is not
## [constant KIND]: a pack the server names is still only an arena map if it says so,
## which is the same rule the roots are scanned by.
static func add_mounted(id: StringName, dir: String) -> DotResult:
	var key := String(id)
	var base := dir.rstrip("/")
	var path := base.path_join("%s.json" % key)

	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_IO, "The delivered map has no manifest.", path)

	if not FileAccess.file_exists(base.path_join("%s.bin" % key)):
		return DotResult.fail(DotError.CODE_IO, "The delivered map has no mesh.", base)

	var parsed := ArenaBspMap.read_manifest(path)

	if str(parsed.get("kind", "")) != KIND:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The delivered map is not an arena map.",
			"%s says kind \"%s\"" % [path, str(parsed.get("kind", ""))]
		)

	_mounted[key] = base
	_manifests[key] = parsed
	return DotResult.success(base)


## Forgets a delivered map's directory, so the id falls back to a root's copy, if any.
static func remove_mounted(id: StringName) -> void:
	var key := String(id)

	if _mounted.erase(key):
		_manifests.erase(key)


## Whether [param id] is registered from a mount.
static func is_mounted(id: StringName) -> bool:
	return _mounted.has(String(id))


## The kind a manifest at [param path] declares, or empty. For a pack already on the disk,
## checked before the map is offered.
static func kind_at(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""

	return str(ArenaBspMap.read_manifest(path).get("kind", ""))


## The parsed manifest, or empty.
static func manifest(id: StringName) -> Dictionary:
	var key := String(id)

	if _manifests.has(key):
		return _manifests[key]

	var path := manifest_path(id)

	if path.is_empty():
		return {}

	var parsed := ArenaBspMap.read_manifest(path)

	if not parsed.is_empty():
		_manifests[key] = parsed

	return parsed


## The map's version: `0.0.0-<12 hex>` of its manifest's bytes.
##
## [b]From the bytes, not a constant.[/b] dot-map's sync protocol accepts an announced map
## only at the version the client also has, and a rotation cooldown and every record are
## about a map AT a version. A re-import in g2gfast-maps that moved a brush is a different
## map; hashing the manifest (which carries every offset into the mesh) says so on both
## ends without anybody remembering to bump anything — the rule g2gfast's packs follow.
##
## Of the root's copy, never a mount's: a delivered map's version is its pack version, which
## the def carries from the server's key (`ArenaMaps.delivered_def`).
static func version_of(id: StringName) -> String:
	var key := String(id)

	if _versions.has(key):
		return _versions[key]

	_scan()
	var path := str(_paths.get(key, ""))

	if path.is_empty():
		return ""

	var hashed := FileAccess.get_md5(path)
	var version := "0.0.0-%s" % hashed.substr(0, 12)
	_versions[key] = version
	return version


## Forgets what was found, so the next ask reads the disk again. The mounted maps stay
## registered (a mount cannot go away), and their manifests are read again on the next ask.
static func rescan() -> void:
	_scanned = false
	_paths.clear()
	_manifests.clear()
	_versions.clear()


static func _scan() -> void:
	if _scanned:
		return

	_scanned = true

	for root in roots():
		var dir := DirAccess.open(root)

		if dir == null:
			continue

		for name in dir.get_directories():
			if _paths.has(name):
				continue

			var path := root.path_join(name).path_join("%s.json" % name)

			if not FileAccess.file_exists(path):
				continue

			if not FileAccess.get_file_as_string(path).contains(_KIND_TEXT):
				continue

			var parsed := ArenaBspMap.read_manifest(path)

			if str(parsed.get("kind", "")) != KIND:
				continue

			_paths[name] = path

			# A mounted copy of the same id is the one `manifest` answers with.
			if not _mounted.has(name):
				_manifests[name] = parsed
