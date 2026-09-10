extends RigidBody3D

## A physics prop, generated from three numbers rather than modelled.
##
## [b]A [RigidBody3D], which is the one thing in this game that is on Godot's
## physics.[/b] Everything else here — the player's collision, the shot tracing, the
## navigation — is analytic geometry from [ArenaMap], because analytic gives the same
## answer on a client replaying a tick and a server that ran it. Rigid bodies do not:
## a contact solver is not reproducible across machines, which is why dot-props is
## server-authoritative and unpredicted and says so.
##
## So a prop is deliberately the exception, and the exception has a cost the game pays
## for it: [method ArenaMap.to_collision] has to exist, because a physics prop needs
## the level to be in a physics space and a dedicated server never instantiates one.
##
## [b]The mass is NOT set here.[/b] [method DotPropSpawner.spawn] puts the catalogue's
## mass on the body before it enters the tree, and a value written in the scene would
## be the second copy of a number this family has already shipped a bug about: a
## catalogue saying 900 kg over a scene saved at 20 kg gives a prop a physics gun
## refuses for being too heavy and a gravity gun throws like a beach ball.

## Half-extents of the box, in metres.
@export var half_size: Vector3 = Vector3(0.35, 0.35, 0.35)

## A sphere instead of a box, of radius [member half_size].x.
@export var rounded: bool = false

@export var tint: Color = Color(0.72, 0.60, 0.38)

## Build a mesh. Off on a dedicated server, which has no renderer to draw into.
@export var visible_body: bool = true


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Continuous, because a punted crate at gravity-gun speed passes through a
	# forty-centimetre wall in one step otherwise — and this game's walls are two
	# metres thick only because `add_perimeter` made them so.
	continuous_cd = true
	contact_monitor = false
	can_sleep = true

	var collider := CollisionShape3D.new()
	collider.name = "Shape"

	if rounded:
		var sphere := SphereShape3D.new()
		sphere.radius = half_size.x
		collider.shape = sphere
	else:
		var box := BoxShape3D.new()
		box.size = half_size * 2.0
		collider.shape = box

	add_child(collider)

	if not visible_body:
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.8

	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "Mesh"

	if rounded:
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = half_size.x
		sphere_mesh.height = half_size.x * 2.0
		mesh_node.mesh = sphere_mesh
	else:
		var box_mesh := BoxMesh.new()
		box_mesh.size = half_size * 2.0
		mesh_node.mesh = box_mesh

	mesh_node.material_override = material
	add_child(mesh_node)
