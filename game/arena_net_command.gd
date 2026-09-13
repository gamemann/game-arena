extends DotNetInput

const ArenaNetCommand := preload("arena_net_command.gd")

## One tick of a player's intent, on the wire.
##
## [b]This is the only thing a client is allowed to send about itself.[/b] Clients
## send inputs, never state — a client that could send a position could send any
## position, and dot-net's whole security model rests on the distinction.
##
## An arena player has two commands, because two addons that do not know about each
## other each define one: [DotFpsCommand] for movement and [DotWeaponCommand] for
## the weapon. Both already know how to write themselves through a duck-typed
## [code]Variant[/code] writer, for the same reason [DotFpsNetSync] never mentions
## [code]DotNetVar[/code] — an addon that named a dot-net class would fail to parse
## without dot-net installed. Composing them here costs nothing and keeps the
## quantisation decisions in the addon that owns them.
##
## [b]The view angles travel once, not twice.[/b] [DotWeaponCommand] carries its own
## yaw and pitch, and sending them again would be 21 wasted bits per tick — and worse
## than wasted: two copies can disagree, and then the shot leaves at an angle the
## player was not looking along. [ArenaPlayer.simulate_tick] already overwrites the
## combat command's angles from the simulated movement state, so the movement
## command's copy is the only one that was ever read.

## Movement: the move vector, the view angles, jump and crouch.
var move: DotFpsCommand = DotFpsCommand.new()

## Weapons: the selected slot, attack, reload, and the rest of the buttons.
var fire: DotWeaponCommand = DotWeaponCommand.new()


func _write(writer: DotNetWriter) -> void:
	move.write(writer)
	# Slot and buttons only. The angles come from `move`; see the class notes.
	writer.write_uint(clampi(fire.slot, 0, 15), 4)
	writer.write_uint(fire.buttons, DotWeaponCommand.BUTTON_BITS)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)

	fire = DotWeaponCommand.new()
	fire.slot = reader.read_uint(4)
	fire.buttons = reader.read_uint(DotWeaponCommand.BUTTON_BITS)
	fire.yaw = move.yaw
	fire.pitch = move.pitch


## Clamps what a client could exaggerate.
##
## [b]Not optional, and not redundant with quantisation.[/b] Quantisation bounds each
## field on its own; it cannot bound the relationship between them. A move vector of
## (1, 1) is two legal components and a length of 1.41, which is 41% more speed than
## anyone else — [method DotFpsCommand.sanitise] is what clamps the length.
func _sanitise() -> void:
	move.sanitise()
	# `max_slots` matches ArenaPlayer's arsenal. A slot outside it cannot select
	# anything, but bounding it here keeps a nonsense value out of the simulation
	# rather than relying on every downstream reader to range-check.
	fire.sanitise(4)
	# Re-derived after both sanitise calls, so a clamped pitch cannot leave the
	# aim pointing somewhere the movement never looked.
	fire.yaw = move.yaw
	fire.pitch = move.pitch


## Whether two inputs are identical, so a held-still player costs less.
func _equals(other: DotNetInput) -> bool:
	var them := other as ArenaNetCommand

	if them == null:
		return false

	return move.equals(them.move) and fire.equals(them.fire)


## Bits one command costs, before dot-net's own framing.
static func estimated_bits() -> int:
	return DotFpsCommand.estimated_bits() + 4 + DotWeaponCommand.BUTTON_BITS


func describe() -> Dictionary:
	return {
		"tick": tick,
		"move": move.describe(),
		"fire": fire.describe(),
	}
