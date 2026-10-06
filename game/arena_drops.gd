extends Node3D

## What comes out of a body on a critical kill: coins, and maybe a health pack.
##
## [b]Server-authoritative and drawn everywhere.[/b] On the authority this holds real
## [DotPickup]s in a [DotPickupField], ticked with the game and swept against every live
## player's simulated position; a client holds only drawn copies, created by DROP and
## removed by TAKEN, because a client that took its own pickups would be one that decides
## what it has. The same class on both ends so the two cannot disagree about what a drop is.
##
## [b]The coins are the genre's reward for a critical[/b]: they burst out of the body and
## whoever walks through them collects them. They count per player ([member coins]); a
## server owner sets how many, what one is worth, whether a health pack comes too, whether
## any kill drops them, and how long they lie there (all `arena_drop_*` cvars). See
## game-arena's CLAUDE.md.

const CHANNEL := "arena.drops"

enum Kind { COIN, HEALTH }

## A drop is out: [param id] is its number on the wire, [param from] where the body was
## (the coins burst from there), [param at] where it lands. Server side.
signal dropped(id: int, kind: int, at: Vector3, from: Vector3, value: int)

## A drop is gone: [param taker] took it, or 0 when it expired. Server side.
signal taken(id: int, taker: int)

## How many coins a lethal critical drops. 0 drops none.
var coins_per_kill: int = 5

## What one coin adds to its taker's count.
var coin_value: int = 1

## Health a health pack gives; 0 drops no pack.
var health_amount: float = 25.0

## Whether every kill drops, rather than only a critical one.
var any_kill: bool = false

## Seconds a drop lies there before it goes.
var life_sec: float = 10.0

## Whether this end decides who takes what. False on a client.
var is_authority: bool = true

## Whether this end draws drops. False on a headless server.
var draws: bool = false

## player id -> coins collected this match.
var coins: Dictionary = {}

var field: DotPickupField = null
var _tick_rate: int = 64
var _next_id: int = 1

## id -> {"pickup": DotPickup, "kind": int, "value": int, "expires": int}. Authority side.
var _live: Dictionary = {}

## id -> {"node": Node3D, "value": int, "kind": int, "from": Vector3, "at": Vector3, "age": float,
## "taker_at": Variant}. Drawing side.
var _drawn: Dictionary = {}

## id -> {"kind", "value"} for every drop this end has been told about, drawn or not: the
## coin count a HUD shows is kept from it, and a headless client draws nothing.
var _known: Dictionary = {}

## Where a player is, for a coin flying to its taker. Set by the game: id -> Vector3 or null.
var position_of: Callable = Callable()


func setup(tick_rate: int) -> void:
	_tick_rate = maxi(tick_rate, 1)
	field = DotPickupField.new()
	field.name = "Field"
	field.tick_rate = _tick_rate
	field.is_authority = is_authority
	add_child(field)


## A kill happened. Drops what the rules say at [param where]. Authority side; returns how
## many drops went out.
func on_kill(where: Vector3, critical: bool, tick: int, p_seed: int) -> int:
	if not is_authority or (not critical and not any_kill):
		return 0

	var made := 0
	var rng := RandomNumberGenerator.new()
	# Seeded from the death so a replay of the same kill scatters the same way.
	rng.seed = p_seed

	for i in range(maxi(coins_per_kill, 0)):
		var angle := TAU * (float(i) + rng.randf() * 0.5) / float(maxi(coins_per_kill, 1))
		var reach := rng.randf_range(1.0, 2.2)
		_spawn(Kind.COIN, coin_value, where, where + Vector3(cos(angle) * reach, 0.0, sin(angle) * reach), tick)
		made += 1

	if health_amount > 0.0:
		_spawn(Kind.HEALTH, int(health_amount), where, where + Vector3(0.0, 0.0, 0.0), tick)
		made += 1

	return made


func _spawn(kind: int, value: int, from: Vector3, at: Vector3, tick: int) -> void:
	var id := _next_id
	_next_id += 1

	var pickup := DotPickup.new()
	pickup.name = "Drop%d" % id
	pickup.item_id = &"coin" if kind == Kind.COIN else &"health"
	pickup.count = value
	pickup.respawn_sec = 0.0
	pickup.radius = 1.0
	pickup.height = 2.0
	pickup.set_tick_rate(_tick_rate)
	pickup.set_meta(&"drop_id", id)
	field.add_child(pickup)
	pickup.global_position = Vector3(at.x, from.y, at.z)

	_live[id] = {
		"pickup": pickup, "kind": kind, "value": value,
		"expires": tick + int(life_sec * float(_tick_rate)),
	}
	field.refresh()
	dropped.emit(id, kind, pickup.global_position, from, value)
	# An authority that also draws (offline, a listen server) draws its own; a client is
	# told by DROP.
	mirror_drop(id, kind, pickup.global_position, from, value)


## One tick: every live player sweeps the drops, and old ones go. Authority side.
##
## [param players] is id -> {"position": Vector3, "hurt": bool, "heal": Callable}.
func tick(tick: int, players: Dictionary) -> void:
	if not is_authority or field == null or _live.is_empty():
		return

	field.wants_fn = func(taker: int, pickup: DotPickup) -> bool:
		if pickup.item_id == &"health":
			return bool(players.get(taker, {}).get("hurt", false))
		return true

	for id in players:
		var entry: Dictionary = players[id]
		for pickup in field.sweep(int(id), entry["position"], tick):
			var drop_id := int(pickup.get_meta(&"drop_id", 0))
			if pickup.item_id == &"coin":
				coins[int(id)] = int(coins.get(int(id), 0)) + pickup.count
			elif entry.has("heal"):
				(entry["heal"] as Callable).call(float(pickup.count))
			_forget(drop_id, int(id))

	for drop_id in _live.keys():
		if tick >= int(_live[drop_id]["expires"]):
			_forget(int(drop_id), 0)


func _forget(id: int, taker: int) -> void:
	var entry: Dictionary = _live.get(id, {})

	if entry.is_empty():
		return

	_live.erase(id)
	var pickup: DotPickup = entry["pickup"]
	if is_instance_valid(pickup):
		pickup.queue_free()
	field.refresh.call_deferred()
	taken.emit(id, taker)
	mirror_taken(id, taker)


# --- Drawing ----------------------------------------------------------------

## A drop the server announced, drawn here. Client side (and a listen server's).
func mirror_drop(id: int, kind: int, at: Vector3, from: Vector3, value: int) -> void:
	_known[id] = {"kind": kind, "value": value}

	if not draws or _drawn.has(id):
		return

	var node := _model(kind)
	add_child(node)
	node.global_position = from + Vector3(0.0, 1.0, 0.0)
	_drawn[id] = {"node": node, "kind": kind, "value": value, "from": from, "at": at, "age": 0.0, "taker": 0}


## A drop the server says is gone: flown to its taker and counted, or simply gone.
func mirror_taken(id: int, taker: int) -> void:
	var known: Dictionary = _known.get(id, {})
	_known.erase(id)

	# The authority counted it when it was taken; a client counts what TAKEN tells it.
	if not is_authority and taker != 0 and int(known.get("kind", -1)) == Kind.COIN:
		coins[taker] = int(coins.get(taker, 0)) + int(known.get("value", 0))

	var entry: Dictionary = _drawn.get(id, {})

	if entry.is_empty():
		return

	if taker == 0:
		(entry["node"] as Node3D).queue_free()
		_drawn.erase(id)
		return

	entry["taker"] = taker
	entry["age"] = 0.0


## Burst, settle, spin; and a taken coin flies to its taker. Frame rate, drawing only.
func _process(delta: float) -> void:
	for id in _drawn.keys():
		var entry: Dictionary = _drawn[id]
		var node: Node3D = entry["node"]
		entry["age"] = float(entry["age"]) + delta
		var age: float = entry["age"]

		if int(entry["taker"]) != 0:
			var target: Variant = position_of.call(int(entry["taker"])) if position_of.is_valid() else null
			if target == null or age > 0.3:
				node.queue_free()
				_drawn.erase(id)
				continue
			node.global_position = node.global_position.lerp((target as Vector3) + Vector3(0.0, 1.0, 0.0), clampf(age / 0.3, 0.0, 1.0))
			continue

		# Out of the body in an arc over the first 0.4 s, then bobbing where it landed.
		var burst := clampf(age / 0.4, 0.0, 1.0)
		var from: Vector3 = entry["from"]
		var at: Vector3 = entry["at"]
		var ground := from.lerp(at, burst)
		var arc := 1.0 + 1.6 * sin(burst * PI) * (1.0 - burst * 0.5)
		node.global_position = ground + Vector3(0.0, (arc if burst < 1.0 else 0.45 + 0.08 * sin(age * 4.0)), 0.0)
		node.rotation.y = age * 4.0


## A coin is a gold disc on its edge; a health pack a green cross. Drawn, no art.
static func _model(kind: int) -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	var material := StandardMaterial3D.new()

	if kind == Kind.COIN:
		var disc := CylinderMesh.new()
		disc.top_radius = 0.18
		disc.bottom_radius = 0.18
		disc.height = 0.05
		mesh.mesh = disc
		mesh.rotation.x = PI * 0.5
		material.albedo_color = Color(1.0, 0.8, 0.15)
		material.metallic = 0.8
		material.roughness = 0.3
		material.emission_enabled = true
		material.emission = Color(0.6, 0.45, 0.05)
	else:
		var bar := BoxMesh.new()
		bar.size = Vector3(0.45, 0.15, 0.15)
		mesh.mesh = bar
		var cross := MeshInstance3D.new()
		var upright := BoxMesh.new()
		upright.size = Vector3(0.15, 0.45, 0.15)
		cross.mesh = upright
		cross.material_override = material
		root.add_child(cross)
		material.albedo_color = Color(0.2, 0.9, 0.35)
		material.emission_enabled = true
		material.emission = Color(0.05, 0.4, 0.1)

	mesh.material_override = material
	root.add_child(mesh)
	return root


func live_count() -> int:
	return _live.size()


func drawn_count() -> int:
	return _drawn.size()


func describe() -> Dictionary:
	return {
		"live": _live.size(), "drawn": _drawn.size(), "coins": coins,
		"coins_per_kill": coins_per_kill, "health": health_amount, "any_kill": any_kill,
	}
