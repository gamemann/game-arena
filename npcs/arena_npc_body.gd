extends Node3D

## The visible body of an arena monster, generated rather than modelled.
##
## [b]A plain [Node3D], not a [CharacterBody3D], and that is the same decision
## [ArenaPlayer] makes.[/b] This game's collision is [ArenaMap]'s analytic geometry —
## exact, needing no physics space, and giving the same answer on a client replaying a
## tick and a server that ran it. An NPC on Godot physics would be a second solver in
## a game that deliberately has none, and on a headless dedicated server it would have
## no space to be solved in. [method DotNpcBrain.steer_toward] handles a plain
## [Node3D] for exactly this case, and [DotNpcNavGraph] is what keeps one out of the
## walls.
##
## [b]Extended by nothing and referenced by PATH.[/b] A `class_name` here would be a
## global identifier reserved in every consuming project for a capsule, and — the
## reason that actually matters — a script inside a mounted dot-cloud pack cannot
## resolve one. `scene_path` in the catalogue and `extends` by path are what a
## delivered NPC must look like, so the shipped ones look like it too.
##
## The mesh is built in `_ready` rather than saved into the scene so the scene file is
## the three numbers that differ between one monster and the next. There is no art in
## this project by design.

## Radius of the trunk, in metres.
@export var body_radius: float = 0.45

## Total height. The head sits on top of it.
@export var body_height: float = 1.6

@export var tint: Color = Color(0.85, 0.30, 0.25)

## Drawn at all. Off on a dedicated server, which has no renderer to draw into and no
## reason to build a mesh per monster.
@export var visible_body: bool = true


func _ready() -> void:
	if not visible_body or Engine.is_editor_hint():
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.9

	var trunk := MeshInstance3D.new()
	trunk.name = "Trunk"
	var capsule := CapsuleMesh.new()
	capsule.radius = body_radius
	capsule.height = maxf(body_height, body_radius * 2.0 + 0.05)
	trunk.mesh = capsule
	trunk.material_override = material
	trunk.position = Vector3(0.0, body_height * 0.5, 0.0)
	add_child(trunk)

	# A snout, so which way it is facing is visible from across the arena. The smaller
	# shape has to sit OUTSIDE the larger one or the silhouette is a single blob —
	# game-playground drew every NPC icon as a coloured bar that way, and it took a
	# screenshot rather than an assertion to see it.
	var snout := MeshInstance3D.new()
	snout.name = "Snout"
	var box := BoxMesh.new()
	box.size = Vector3(body_radius * 0.5, body_radius * 0.5, body_radius * 1.1)
	snout.mesh = box
	snout.material_override = material
	snout.position = Vector3(
		0.0, body_height * 0.82, -(body_radius + box.size.z * 0.5)
	)
	add_child(snout)
