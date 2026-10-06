extends DotNetBehaviour

## A monster over the wire: where it is, which way it faces, how hurt it is, what it is doing.
##
## dot-npc's [DotNpcNetSync] fields, on this game's net behaviour — the split that addon
## exists to make, since dot-npc cannot name dot-net. Server-authoritative and never
## predicted: a monster's position comes out of a navigation graph and a brain, neither of
## which a client could reproduce, so the client interpolates and draws.
##
## [b]Monsters were not replicated at all before this.[/b] The horde ran on the server and a
## connected player was hurt by monsters they could not see; only an offline game or a
## listen server ever showed one.

## The server's row. Null on a client.
var npc: DotNpcInstance = null

## The body this moves: the server's monster, or a client's mirror of it.
var body: Node3D = null

var net_x: float = 0.0
var net_y: float = 0.0
var net_z: float = 0.0
var net_yaw: int = 0
var net_health: int = 0
var net_state: int = 0


func _register_net_vars() -> void:
	for spec in DotNpcNetSync.specs():
		var field := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			field.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			field.interpolated()


func pull() -> void:
	if npc == null or not npc.is_alive():
		return

	var state := DotNpcNetSync.State.IDLE

	if npc.has_target():
		state = DotNpcNetSync.State.ATTACKING

	DotNpcNetSync.pull(npc, self, state)


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


func _net_state_applied(_tick: int) -> void:
	_draw()


func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if body == null or not is_instance_valid(body):
		return

	if identity != null and identity.is_authoritative:
		return

	DotNpcNetSync.apply(body, self)
