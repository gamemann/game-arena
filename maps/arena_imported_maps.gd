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


## The manifest's path, or empty when there is no such map.
static func manifest_path(id: StringName) -> String:
	_scan()
	return str(_paths.get(String(id), ""))


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
static func version_of(id: StringName) -> String:
	var key := String(id)

	if _versions.has(key):
		return _versions[key]

	var path := manifest_path(id)

	if path.is_empty():
		return ""

	var hashed := FileAccess.get_md5(path)
	var version := "0.0.0-%s" % hashed.substr(0, 12)
	_versions[key] = version
	return version


## Forgets what was found, so the next ask reads the disk again.
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
			_manifests[name] = parsed
