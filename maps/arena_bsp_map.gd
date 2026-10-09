extends RefCounted

const ArenaPaths := preload("../game/arena_paths.gd")

## A map imported from a compiled `.bsp` by game-g2gfast's importer, built here from the
## manifest it wrote: the drawn mesh, the baked lightmap, the brushes as convex hulls, the
## map's own spawn points and the teleport volumes that catch a player who falls.
##
## [b]A copy of the half of `G2GBspMap` arena needs, not a dependency on it, and not an
## addon.[/b] Three ways were open and two are closed:
##
## - [b]Naming g2gfast's script.[/b] A game cannot depend on another game — each is its own
##   repository and its own delivered pack — and a delivered pack cannot resolve a
##   `class_name` from anywhere (see the family's pack note), so `G2GBspMap` is not
##   reachable from arena at all, delivered or not.
## - [b]Lifting it into an addon.[/b] The right home in the long run, and the expensive one
##   now: an addon is in the client SHELL, so arena's pack could not use it until the addon
##   is tagged and the shell rebuilt and published — and the reusable half is tangled with
##   g2gfast's own (genre units as a class, its timer zones, its texture set and Kenney
##   stand-ins, its flashlight, dot-lighting). What arena needs is about three hundred
##   lines with none of that.
## - [b]A copy, which is this file.[/b] The family's rule for anything shared between two
##   games is that it is duplicated deliberately or lives in dot-core; this is the first.
##
## What the copy keeps is exactly what the manifest format promises: `<id>.bin` holds the
## vertices (ten floats: position, normal, uv, uv2) and indices of each surface, then the
## brush hulls (a u32 count and that many float triples each) and the welded displacement
## triangles; the manifest says where each block starts. [b]Genre units on the wire,
## metres in the scene, converted at one boundary — [constant METRES_PER_UNIT] — and no
## axis swap[/b]: the importer already wrote Godot's axes, so a manifest coordinate is
## `(x, y up, z)` in units of 0.75 inch. When the format changes in g2gfast, this file has
## to follow, and the suite that loads one of these maps is what says so.
##
## What it deliberately leaves out, and why that is safe for a deathmatch:
##
## - [b]Timer zones.[/b] dot-timer is not in this game. A combat surf map has no finish by
##   definition (that is what its `"kind": "arena"` says); the only zones arena reads are
##   the pits, which are a teleport.
## - [b]The map's sky, sun and fog.[/b] Those are dot-lighting in g2gfast, which arena does
##   not link. The surfaces are `unshaded` and lit by the baked lightmap alone, so the
##   world looks like the map; only the background behind it is arena's.
## - [b]Kenney stand-ins and g2gfast's prototype set[/b] for a texture the map did not
##   carry. Arena's own generated grid ([method ArenaMap.dev_texture]) is drawn instead,
##   tinted the colour the map's compiler measured for that texture — the same grid the
##   built-in maps wear, which is this game's look.
## - [b]Pushes, water, ladders and moving blocks[/b] (`mechanics`). Not run here; see the
##   game's CLAUDE.md.

## Metres per genre unit: 0.75 inch, the scale these maps were built at. Not the 1-inch
## figure sometimes quoted — at that scale a surf ramp is one the movement cannot hold.
const METRES_PER_UNIT := 0.01905

## Floats per vertex in the mesh block: position 3, normal 3, uv 2, uv2 2.
const VERTEX_FLOATS := 10

## How many of the generated grid's squares one 64-unit square of UV is.
##
## The importer writes UVs for an untextured surface in 64-unit squares, the grid these
## maps are built on. [method ArenaMap.dev_texture] draws four squares a tile, so a tile is
## four of those: one grid square on the floor is 64 units, 1.22 m, on every surface.
const GRID_SQUARES_PER_TILE := 4.0

## The colour a surface the importer measured nothing for is drawn, by its role.
const ROLE_COLOURS := {
	"RAMP": Color(0.78, 0.52, 0.30),
	"PLATFORM": Color(0.62, 0.64, 0.68),
	"FLOOR": Color(0.46, 0.48, 0.52),
}

## Lifts the baked darks so geometry stays readable; g2gfast's numbers, measured there.
const AMBIENT := 0.10
const LIGHT_BOOST := 1.35
## Higher for a grid surface, which has no darks of its own to lose. See g2gfast's
## `G2GBspMap.prototype_ambient`, which was chosen by rendering it.
const PROTOTYPE_AMBIENT := 0.32


## A manifest, parsed, or empty when the file is missing or is not one.
static func read_manifest(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)

	if text.is_empty():
		return {}

	var parsed: Variant = JSON.parse_string(text)

	if typeof(parsed) != TYPE_DICTIONARY:
		return {}

	return parsed


## A manifest coordinate in metres. No axis swap: the importer wrote Godot's axes.
static func to_metres(value: Variant) -> Vector3:
	var arr: Array = value as Array

	if arr == null or arr.size() < 3:
		return Vector3.ZERO

	return Vector3(float(arr[0]), float(arr[1]), float(arr[2])) * METRES_PER_UNIT


## The volume the map occupies, in metres.
##
## [b]`abs()`, because the manifest's two corners are not min and max on every axis.[/b]
## The importer wrote them through the axis swap that negates one, so `min.z` is the
## LARGER z on every map — an AABB built straight from them has a negative depth, which
## every containment test answers "no" to.
static func bounds_of(manifest: Dictionary) -> AABB:
	var b: Dictionary = manifest.get("bounds", {})
	var a := to_metres(b.get("min", [0, 0, 0]))
	var c := to_metres(b.get("max", [0, 0, 0]))
	return AABB(a, c - a).abs()


## Where a player may appear: every spawn the map placed, facing the way its mapper faced
## it. The yaw is already the motor's (the importer converted it, the fault g2gfast found
## the hard way); falls back to the manifest's one `spawn` when the list is empty.
static func spawns_of(manifest: Dictionary) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var listed: Array = manifest.get("spawns", [])

	if listed.is_empty() and manifest.has("spawn"):
		listed = [manifest["spawn"]]

	for entry: Variant in listed:
		var spot: Dictionary = entry as Dictionary
		var yaw := deg_to_rad(float(spot.get("yaw", 0.0)))
		out.append(Transform3D(Basis(Vector3.UP, yaw), to_metres(spot.get("origin", [0, 0, 0]))))

	return out


## Every volume that sends a player somewhere: `{box: AABB, to: Vector3, yaw: float}`.
##
## These are the map's `trigger_teleport`s, which on a combat surf map are the pits under
## the ramps and the ways in and out of its jail: each aims at a spawn, a jail or the top of
## a ramp. A RESPAWN zone with no destination aims at nothing usable and is left out —
## the fall-out floor (see `ArenaPlayer`) still catches a player under it.
static func pits_of(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for entry: Variant in manifest.get("zones", []):
		var zone: Dictionary = entry as Dictionary

		if str(zone.get("kind", "")) != "RESPAWN" or not zone.has("destination"):
			continue

		var a := to_metres(zone.get("min", [0, 0, 0]))
		var c := to_metres(zone.get("max", [0, 0, 0]))
		out.append({
			"box": AABB(a, c - a).abs(),
			"to": to_metres(zone["destination"]),
			"yaw": float(zone.get("destination_yaw", 0.0)),
		})

	return out


## The map as a player sees it: one [MeshInstance3D] per 256 surfaces, no collision.
##
## [b]No collision on purpose.[/b] The solid is [method build_collision], which the GAME
## builds on every machine (a dedicated server included, because the movement and the
## shots are physics queries on an imported map). A client that also added colliders here
## would have two copies of every brush in one space.
##
## One instance per 256 surfaces because that is the engine's cap on one mesh; past it a
## surface is refused with an engine error and simply not drawn (g2gfast lost 55 that way).
## Static props are drawn like the world; the 3D skybox is not drawn at all, because it is
## the map's backdrop scaled up far outside the play space and arena has its own sky.
static func build_visual(manifest: Dictionary, dir: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Imported"

	var id := str(manifest.get("id", ""))
	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % id))

	if blob.is_empty():
		DotLog.error("arena.maps", "an imported map's mesh is missing", {
			"map": id, "dir": dir
		})
		return root

	var lm_info: Dictionary = manifest.get("lightmap", {})
	var lightmap := _load_texture(dir.path_join(str(lm_info.get("file", ""))))

	var surfaces: Array = manifest.get("surfaces", [])
	var mesh: ArrayMesh = null
	var sources := PackedInt32Array()
	var made := 0

	for i in range(surfaces.size()):
		var s: Dictionary = surfaces[i]

		if bool(s.get("skybox", false)):
			continue

		var arrays := _surface_arrays(blob, s)

		if arrays.is_empty():
			continue

		if mesh == null or mesh.get_surface_count() >= RenderingServer.MAX_MESH_SURFACES:
			if mesh != null:
				root.add_child(_mesh_instance(mesh, sources, surfaces, dir, lightmap, made))
				made += 1

			mesh = ArrayMesh.new()
			sources = PackedInt32Array()

		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		sources.append(i)

	if mesh != null:
		root.add_child(_mesh_instance(mesh, sources, surfaces, dir, lightmap, made))

	return root


static func _mesh_instance(
	mesh: ArrayMesh, sources: PackedInt32Array, surfaces: Array, dir: String,
	lightmap: Texture2D, index: int
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "World" if index == 0 else "World%d" % (index + 1)
	mi.mesh = mesh

	# [b]Per surface, from the surface it came from[/b], never by position in a second
	# loop: one skipped surface would otherwise give every surface after it its
	# neighbour's material.
	for at in range(sources.size()):
		mi.set_surface_override_material(at, _material_for(surfaces[sources[at]], dir, lightmap))

	return mi


## The map's solid volume: one convex shape per brush, plus the displacement terrain.
##
## [b]From the brushes, not from the drawn mesh.[/b] A compiled map deletes every face
## nobody can see and paints the rest of a brush `nodraw`, and a surf ramp is routinely
## wrapped in player clip, which is never drawn at all: built from the mesh, a third to
## three quarters of every solid is missing and a player falls through the map. And
## [b]convex per brush rather than one trimesh[/b], because a hull sliding across loose
## triangles catches on every interior edge between them — on a ramp ridden at speed that
## is a ride ended by a bump that is not there. Displacements are the exception (terrain is
## not convex): one [ConcavePolygonShape3D], welded at import.
##
## A manifest with no `collision` block predates the brush reader; it gets a trimesh over
## the drawn mesh, which is the wrong collider for the reason above but still a map.
static func build_collision(manifest: Dictionary, dir: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "ImportedSolid"

	var id := str(manifest.get("id", ""))
	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % id))
	var info: Dictionary = manifest.get("collision", {})

	if blob.is_empty():
		DotLog.error("arena.maps", "an imported map's collision is missing", {
			"map": id, "dir": dir
		})
		return body

	if info.is_empty():
		var visual := build_visual(manifest, dir)

		for child in visual.get_children():
			if child is MeshInstance3D:
				var shape := CollisionShape3D.new()
				shape.shape = (child as MeshInstance3D).mesh.create_trimesh_shape()
				body.add_child(shape)

		visual.free()
		return body

	var offset := int(info.get("hull_offset", 0))

	for _h in range(int(info.get("hull_count", 0))):
		if offset + 4 > blob.size():
			break

		var count := int(blob.decode_u32(offset))
		offset += 4
		var floats := blob.slice(offset, offset + count * 12).to_float32_array()
		offset += count * 12

		if floats.size() < count * 3:
			break

		var points := PackedVector3Array()
		points.resize(count)

		for v in range(count):
			points[v] = Vector3(
				floats[v * 3], floats[v * 3 + 1], floats[v * 3 + 2]
			) * METRES_PER_UNIT

		var hull := ConvexPolygonShape3D.new()
		hull.points = points
		var shape := CollisionShape3D.new()
		shape.shape = hull
		body.add_child(shape)

	var vertex_count := int(info.get("displacement_vertex_count", 0))
	var index_count := int(info.get("displacement_index_count", 0))

	if vertex_count > 0 and index_count > 0:
		var voff := int(info.get("displacement_vertex_offset", 0))
		var coords := blob.slice(voff, voff + vertex_count * 12).to_float32_array()
		var ioff := int(info.get("displacement_index_offset", 0))
		var indices := blob.slice(ioff, ioff + index_count * 4).to_int32_array()
		var faces := PackedVector3Array()
		faces.resize(index_count)

		for i in range(index_count):
			var v := int(indices[i]) * 3

			if v + 2 >= coords.size():
				continue

			faces[i] = Vector3(coords[v], coords[v + 1], coords[v + 2]) * METRES_PER_UNIT

		# One-sided: a displacement is terrain with a solid brush under it, and a two-sided
		# one catches a player already inside the ground instead of letting them out.
		var terrain := ConcavePolygonShape3D.new()
		terrain.set_faces(faces)
		var shape := CollisionShape3D.new()
		shape.shape = terrain
		body.add_child(shape)

	return body


static func _surface_arrays(blob: PackedByteArray, s: Dictionary) -> Array:
	var vcount := int(s.get("vertex_count", 0))
	var icount := int(s.get("index_count", 0))

	if vcount <= 0 or icount <= 0:
		return []

	var voff := int(s.get("vertex_offset", 0))
	var ioff := int(s.get("index_offset", 0))
	var floats := blob.slice(voff, voff + vcount * VERTEX_FLOATS * 4).to_float32_array()

	if floats.size() < vcount * VERTEX_FLOATS:
		return []

	var positions := PackedVector3Array()
	positions.resize(vcount)
	var normals := PackedVector3Array()
	normals.resize(vcount)
	var uvs := PackedVector2Array()
	uvs.resize(vcount)
	var uv2s := PackedVector2Array()
	uv2s.resize(vcount)

	for v in range(vcount):
		var o := v * VERTEX_FLOATS
		positions[v] = Vector3(floats[o], floats[o + 1], floats[o + 2]) * METRES_PER_UNIT
		normals[v] = Vector3(floats[o + 3], floats[o + 4], floats[o + 5])
		uvs[v] = Vector2(floats[o + 6], floats[o + 7])
		uv2s[v] = Vector2(floats[o + 8], floats[o + 9])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = blob.slice(ioff, ioff + icount * 4).to_int32_array()

	# A blend surface's second texture shows by vertex alpha, which is its own block
	# rather than an eleventh float, so a manifest without it still reads.
	if s.has("alpha_offset"):
		var aoff := int(s["alpha_offset"])
		var alphas := blob.slice(aoff, aoff + vcount * 4).to_float32_array()

		if alphas.size() == vcount:
			var colours := PackedColorArray()
			colours.resize(vcount)

			for v in range(vcount):
				colours[v] = Color(1.0, 1.0, 1.0, alphas[v])

			arrays[Mesh.ARRAY_COLOR] = colours

	return arrays


## The grid every untextured surface wears, built once per process.
static var _grid: Texture2D = null


static func _material_for(s: Dictionary, dir: String, lightmap: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	# [b]Two shaders, and the opaque one is the default.[/b] Writing ALPHA at all is what
	# puts a spatial shader in the transparent pass, where depth is not written and a map
	# draws through itself (g2gfast shipped every imported map that way). Only a surface
	# the map's own material called translucent gets the shader that writes it.
	mat.shader = load(ArenaPaths.rebase(
		"res://maps/arena_bsp_translucent.gdshader" if bool(s.get("translucent", false))
		else "res://maps/arena_bsp_lightmapped.gdshader"
	))
	mat.set_shader_parameter("lightmap_tex", lightmap)
	mat.set_shader_parameter("light_boost", LIGHT_BOOST)
	mat.set_shader_parameter("ambient", AMBIENT)

	var texture_name: Variant = s.get("texture", null)

	if texture_name is String and not (texture_name as String).is_empty():
		var tex := _load_texture(dir.path_join("textures").path_join(texture_name))

		if tex != null:
			mat.set_shader_parameter("albedo_tex", tex)
			mat.set_shader_parameter("tint", Color.WHITE)
			mat.set_shader_parameter("uv_scale", 1.0)

			var second := str(s.get("texture2", ""))

			if not second.is_empty() and second != "<null>" and s.has("alpha_offset"):
				var tex2 := _load_texture(dir.path_join("textures").path_join(second))

				if tex2 != null:
					mat.set_shader_parameter("albedo2_tex", tex2)
					mat.set_shader_parameter("has_albedo2", true)

			return mat

	# No texture the map carried: it lived in the source game's own archives, which on a
	# surf map is most of the map. The grid, painted the colour the map's compiler measured
	# for that texture (`colour`), so the map keeps its palette and the grid keeps the
	# scale — a flat fill at surf speed says nothing about how fast it is going past.
	if _grid == null:
		_grid = load(ArenaPaths.rebase("res://maps/arena_map.gd")).dev_texture(
			128, 32, Color(0.80, 0.80, 0.80), Color(0.52, 0.52, 0.52)
		)

	var tint: Color = ROLE_COLOURS.get(str(s.get("role", "FLOOR")), ROLE_COLOURS["FLOOR"])
	var colour: Variant = s.get("colour", null)

	if colour is Array and (colour as Array).size() >= 3:
		var measured := Color(float(colour[0]), float(colour[1]), float(colour[2]))

		# [b]A measured black is trusted only when the name says black[/b] (g2gfast's rule,
		# found by rendering every map): a self-lit panel has no albedo for the compiler to
		# measure, so it reads zero and would draw as a hole. A material named black IS black.
		if measured.get_luminance() > 0.01 or str(s.get("material", "")).to_lower().contains("black"):
			tint = measured

	mat.set_shader_parameter("albedo_tex", _grid)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("uv_scale", 1.0 / GRID_SQUARES_PER_TILE)
	mat.set_shader_parameter("ambient", PROTOTYPE_AMBIENT)
	return mat


## A texture through the resource loader, which is the only path an export ships.
##
## `Image.load_from_file` on a `res://` path works from source and returns nothing in an
## exported build, because the export carries the imported `.ctex` and not the `.png`.
## The file read below is the fallback for a map nobody has imported yet.
static func _load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null

	if ResourceLoader.exists(path):
		var res: Resource = load(path)

		if res is Texture2D:
			return res

	if not FileAccess.file_exists(path):
		return null

	var img := Image.load_from_file(path)

	if img == null:
		return null

	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
