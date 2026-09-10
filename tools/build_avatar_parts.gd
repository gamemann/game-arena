extends SceneTree

## Generates the avatar part scenes from Kenney's Blocky Characters.
##
## [codeblock]
## godot --headless --path . --script tools/build_avatar_parts.gd
## [/codeblock]
##
## Writes `avatars/body_kenney_<x>.tscn` and `avatars/head_kenney_<x>.tscn`, one pair
## per character, from `avatars/kenney/character-<x>.glb`.
##
## [b]Generated rather than authored, because the 18 characters are one mesh set.[/b]
## Every GLB in that kit carries byte-identical geometry — leg-left, leg-right, torso,
## arm-left, arm-right, head — and differs only by the atlas it samples. Hand-building
## 36 scenes that differ by one texture reference is 36 chances to get one wrong, and
## the kit gaining a nineteenth character would mean noticing.
##
## The split is by slot, not by file: a "body" is everything except the head, because
## [ArenaAvatars] has a head slot and a player who picks a different head must not get
## two.
##
## [b]Two corrections a straight export does not make, and both are invisible in the
## file.[/b] A Kenney character is 2.7 m tall and this genre's player hull is 72 units,
## which is 1.372 m -- so an imported character is very nearly TWICE the size of the
## thing it represents, standing with its head above the camera and its shoulders
## through every doorway, with every property of every node correct. And the parts are
## authored in the character's own space (feet at 0, head at 1.9) while ArenaAvatars mounts
## each slot at a point and expects the part to be centred on it, the way the capsule
## primitives that came first are. Both are applied here rather than asked of the rig,
## because the rig is right and the art is what has to fit it.

const KENNEY_DIR := "res://avatars/kenney"
const OUT_DIR := "res://avatars"
const HEAD_MESH := "head"

## Arena's own numbers. It is not a genre-units game -- its capsule is 1.8 m and its
## avatar mounts are absolute metres in `ArenaAvatars` -- so the figures that fit
## g2gfast's 72-unit hull are wrong here by a third.
const HULL_HEIGHT := 1.8
const BODY_MOUNT := 0.65


func _init() -> void:
	var dir := DirAccess.open(KENNEY_DIR)
	if dir == null:
		printerr("no %s — copy Kenney's Blocky Characters there first" % KENNEY_DIR)
		quit(1)
		return

	# `get_files()` lists `character-a.glb` AND `character-a.glb.import`, and both
	# trim to the same name -- so a naive pass does every character twice and reports
	# 36 of an 18-character kit while writing 18 pairs. Deduplicated, not tolerated:
	# the second pass was harmless and the count it printed was not.
	var seen: Dictionary = {}
	var letters := PackedStringArray()
	for file in dir.get_files():
		var name := file.trim_suffix(".remap").trim_suffix(".import")
		if not (name.begins_with("character-") and name.ends_with(".glb")):
			continue
		var letter := name.substr(10, name.length() - 14)
		if seen.has(letter):
			continue
		seen[letter] = true
		letters.append(letter)
	letters.sort()

	if letters.is_empty():
		printerr("no character-*.glb in %s" % KENNEY_DIR)
		quit(1)
		return

	# One factor for the whole kit, measured from the first character rather than
	# assumed: every GLB in it shares geometry, so a per-character factor would be the
	# same number eighteen times and would silently rescale the set if one ever differed.
	var scale := _fit_scale(load("%s/character-%s.glb" % [KENNEY_DIR, letters[0]]))
	print("scaling Kenney's %.2f m character to the %.2f m hull: x%.4f"
		% [_height(load("%s/character-%s.glb" % [KENNEY_DIR, letters[0]])),
		   HULL_HEIGHT, scale])

	var written := 0
	var failed := 0
	for letter in letters:
		var glb := "%s/character-%s.glb" % [KENNEY_DIR, letter]
		var packed: PackedScene = load(glb)
		if packed == null:
			printerr("could not load %s" % glb)
			failed += 1
			continue
		var source: Node = packed.instantiate()

		failed += _write(source, letter, false, scale)
		failed += _write(source, letter, true, scale)
		written += 2
		source.free()

	print("%d part scenes from %d characters, %d failed" % [written - failed, letters.size(), failed])
	quit(1 if failed > 0 else 0)


## One part scene: the head, or everything but the head.
func _write(source: Node, letter: String, head_only: bool, scale: float) -> int:
	var slot := "head" if head_only else "body"
	var root := Node3D.new()
	root.name = "arena_%s_kenney_%s" % [slot, letter]

	for mesh in _meshes(source):
		var is_head := mesh.name.to_lower().contains(HEAD_MESH)
		if is_head != head_only:
			continue
		var copy := MeshInstance3D.new()
		copy.name = str(mesh.name)
		copy.mesh = mesh.mesh
		# The transform relative to the character root, not to the immediate parent:
		# Kenney parents the limbs under a `root` node with its own offset, and
		# copying the local transform alone drops that and stacks every limb at the
		# origin — a character that is correct in every property and is a pile.
		copy.transform = _relative_to(source, mesh)
		root.add_child(copy)

	if root.get_child_count() == 0:
		printerr("arena_%s_kenney_%s has no meshes" % [slot, letter])
		root.free()
		return 1

	# Scale to the hull, then place the part relative to the mount [G2GRig] will put
	# it on.
	#
	# The head is centred on its mount, like the stock capsules. The BODY is not: it is
	# aligned so its feet land on the floor. `ArenaAvatars` mounts the body at BODY_MOUNT and the stock capsule is centred there, which leaves it floating about
	# 13 cm -- invisible on a capsule, and a character standing in mid-air the moment
	# the part has legs. The rig is not changed for this because arena mounts the same
	# way and its parts are still primitives; the art is what fits the rig.
	var box := _bounds(root)
	var centre := box.get_center()
	if not head_only:
		centre.y = box.position.y + BODY_MOUNT / scale
	for child in root.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		# Basis and origin separately, and the origin exactly once.
		# `Transform3D.scaled()` scales the origin as well as the basis, so doing that
		# and then multiplying the origin again scales the LAYOUT twice while scaling
		# each mesh once: limbs drift apart from a body that is the right size, which
		# measures as a part 8% too tall and reads as a slightly wrong model.
		mi.transform.origin = (mi.transform.origin - centre) * scale
		mi.transform.basis = mi.transform.basis.scaled(Vector3(scale, scale, scale))

	for child in root.get_children():
		child.owner = root

	var scene := PackedScene.new()
	var packed := scene.pack(root)
	if packed != OK:
		printerr("could not pack arena_%s_kenney_%s" % [slot, letter])
		root.free()
		return 1

	var path := "%s/arena_%s_kenney_%s.tscn" % [OUT_DIR, slot, letter]
	var saved := ResourceSaver.save(scene, path)
	root.free()
	if saved != OK:
		printerr("could not write %s" % path)
		return 1
	return 0


## The whole character's height in metres, in its own units.
func _height(packed: PackedScene) -> float:
	if packed == null:
		return 0.0
	var n: Node = packed.instantiate()
	var h := _bounds(n).size.y
	n.free()
	return h


## What to multiply the kit by so it stands as tall as the genre's player.
func _fit_scale(packed: PackedScene) -> float:
	var h := _height(packed)
	if h <= 0.0:
		return 1.0
	return HULL_HEIGHT / h


## A node tree's bounds, in the tree root's own space.
func _bounds(root: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi in _meshes(root):
		var b: AABB = _relative_to(root, mi) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out


## A node's transform in the character root's space.
func _relative_to(root: Node, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var walk: Node = node
	while walk != null and walk != root:
		if walk is Node3D:
			t = (walk as Node3D).transform * t
		walk = walk.get_parent()
	return t
