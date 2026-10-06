extends Node3D

const ArenaProjectiles := preload("arena_projectiles.gd")

## Every rocket and grenade the game is flying, drawn. Client side.
##
## [b]Nothing drew them, offline or connected.[/b] `ArenaProjectiles` flew every rocket
## correctly on the authority and the only thing anybody saw was the splash damage — a
## launcher that fired nothing visible and a grenade that was a number going down. This
## reads the same list the simulation advances, once a frame, and moves one node per
## entry; it writes nothing back, so dropping it changes no outcome.
##
## A grenade is its own model from zee-dot-weapons' art table, turned and scaled the way
## the pack draws it in a hand. The launcher's round has no model in the kit worth the
## name at this size, so it is a small hot sphere with a light, which is also what reads
## at forty metres. On a networked client the list is the copies the server's LAUNCH
## events started, flown by `ArenaNetBridge.client_tick`.

const CHANNEL := "arena.projectiles"

## The round's radius in metres, and its glow.
const ROUND_RADIUS := 0.11
const ROUND_COLOUR := Color(1.0, 0.62, 0.22)

## A grenade's fuse light.
const FUSE_COLOUR := Color(1.0, 0.18, 0.12)

## The layer whose list is drawn. Re-pointed by the client whenever the game builds a new
## one, which a map change does.
var projectiles: ArenaProjectiles = null

## One drawn node per flying entry, keyed by the entry.
var _drawn: Dictionary = {}

var _round_mesh: SphereMesh = null
var _round_material: StandardMaterial3D = null


func _ready() -> void:
	# Top level, so the world's position is the only one: a parent that moved would carry
	# every grenade in the air with it.
	top_level = true


func _process(_delta: float) -> void:
	present()


## Moves every drawn node to where its entry is, adding and freeing as they come and go.
## Public so a suite can step it with no frame.
func present() -> void:
	var live: Array = projectiles.flying() if projectiles != null else []
	var seen := {}

	for f: ArenaProjectiles.Flying in live:
		seen[f] = true
		var node: Node3D = _drawn.get(f)

		if node == null:
			node = _make(f)
			add_child(node)
			_drawn[f] = node

		node.global_position = f.position

		# A rocket points where it is going; a grenade tumbles, which is what a thrown
		# object does and what tells a watcher it is not a rocket.
		if f.spawn.fuse_ticks <= 0 and f.velocity.length_squared() > 0.01:
			node.look_at(f.position + f.velocity, _up_for(f.velocity))
		elif not f.resting:
			node.rotate_x(0.2)

	for f in _drawn.keys():
		if not seen.has(f):
			(_drawn[f] as Node3D).queue_free()
			_drawn.erase(f)


func drawn_count() -> int:
	return _drawn.size()


## Drops everything drawn: a map change, the client leaving.
func clear() -> void:
	for node in _drawn.values():
		(node as Node3D).queue_free()
	_drawn.clear()


func _make(f: ArenaProjectiles.Flying) -> Node3D:
	var root := Node3D.new()
	root.name = "Projectile"

	var art: Variant = ZeeWeaponArtTable.table().get(f.spawn.id)

	if f.spawn.fuse_ticks > 0 and art is ZeeWeaponArt and (art as ZeeWeaponArt).has_model():
		var model := ZeeModelCache.instantiate((art as ZeeWeaponArt).model_path)

		if model != null:
			# The hand's turn and scale, without the hand's offset: the origin is the
			# grenade's own, and the entry's position is where it is.
			var placed := (art as ZeeWeaponArt).world_transform()
			placed.origin = Vector3.ZERO
			model.transform = placed
			root.add_child(model)
			root.add_child(_fuse_light())
			return root

	root.add_child(_round())
	return root


## A lit fuse: a small red light on a grenade.
##
## [b]Because the grenade alone could not be seen.[/b] Rendered, a frag resting fourteen
## metres away was two or three brown pixels on a grey floor — the size it really is, and
## a grenade nobody can see is one nobody can get away from, which is the only decision a
## grenade exists to force. The light lands on the floor round it, which is what the eye
## finds.
func _fuse_light() -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "Fuse"
	light.light_color = FUSE_COLOUR
	light.light_energy = 2.2
	light.omni_range = 1.6
	light.position = Vector3(0.0, 0.15, 0.0)
	light.shadow_enabled = false
	return light


## A small hot sphere with a light: a launcher's round, or anything without a model.
func _round() -> Node3D:
	if _round_mesh == null:
		_round_mesh = SphereMesh.new()
		_round_mesh.radius = ROUND_RADIUS
		_round_mesh.height = ROUND_RADIUS * 2.0
		_round_material = StandardMaterial3D.new()
		_round_material.albedo_color = ROUND_COLOUR
		_round_material.emission_enabled = true
		_round_material.emission = ROUND_COLOUR
		_round_material.emission_energy_multiplier = 3.0
		_round_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var holder := Node3D.new()

	var mesh := MeshInstance3D.new()
	mesh.mesh = _round_mesh
	mesh.material_override = _round_material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mesh)

	var light := OmniLight3D.new()
	light.light_color = ROUND_COLOUR
	light.light_energy = 1.6
	light.omni_range = 4.0
	holder.add_child(light)

	return holder


static func _up_for(direction: Vector3) -> Vector3:
	return Vector3.RIGHT if absf(direction.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
