extends DotNetInput

const ArenaNetCommand := preload("arena_net_command.gd")
const ArenaPlayer := preload("arena_player.gd")

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

## How far behind this command's tick the client was drawing everybody else, in quarter
## ticks: the tick a shot fired on this command was aimed at, as the server rewinds to it
## for lag compensation (`ArenaGame._rewind_to`). Sent only when a button is down -- a
## command that cannot fire costs one bit for it -- and capped by the server, never
## trusted: [constant MAX_VIEW_LAG_Q] here, and the combat config's rewind limit there.
var view_lag_q: int = -1

## 1023 quarter ticks: four seconds at 64 ticks and two at 128, past any rewind limit.
##
## It was 255 in 8 bits, commented as "just under four seconds" -- which is 255 TICKS.
## In quarter ticks it is 64 ticks, one second at 64 and half a second at 128, so on a
## 128-tick server the wire clamped a 300-400 ms player below the rewind limit that was
## meant to compensate them, whatever `arena_max_unlag_ms` said.
const MAX_VIEW_LAG_Q := 1023
const VIEW_LAG_BITS := 10


func _write(writer: DotNetWriter) -> void:
	move.write(writer)
	# Slot and buttons only. The angles come from `move`; see the class notes.
	writer.write_uint(clampi(fire.slot, 0, 15), 4)
	writer.write_uint(fire.buttons, DotWeaponCommand.BUTTON_BITS)
	var lagged := fire.buttons != 0 and view_lag_q >= 0
	writer.write_bool(lagged)
	if lagged:
		writer.write_uint(clampi(view_lag_q, 0, MAX_VIEW_LAG_Q), VIEW_LAG_BITS)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)

	fire = DotWeaponCommand.new()
	fire.slot = reader.read_uint(4)
	fire.buttons = reader.read_uint(DotWeaponCommand.BUTTON_BITS)
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	view_lag_q = reader.read_uint(VIEW_LAG_BITS) if reader.read_bool() else -1


## Clamps what a client could exaggerate.
##
## [b]Not optional, and not redundant with quantisation.[/b] Quantisation bounds each
## field on its own; it cannot bound the relationship between them. A move vector of
## (1, 1) is two legal components and a length of 1.41, which is 41% more speed than
## anyone else — [method DotFpsCommand.sanitise] is what clamps the length.
func _sanitise() -> void:
	move.sanitise()
	# `max_slots` matches ArenaPlayer's arsenal: the pack's five. A slot outside it cannot
	# select anything, but bounding it here keeps a nonsense value out of the simulation
	# rather than relying on every downstream reader to range-check. It was 4 when the
	# arsenal had four, and a hard 4 here would have made the throwable slot unreachable
	# over the wire while it worked offline.
	fire.sanitise(ArenaPlayer.MAX_SLOTS)
	# Re-derived after both sanitise calls, so a clamped pitch cannot leave the
	# aim pointing somewhere the movement never looked.
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	view_lag_q = clampi(view_lag_q, -1, MAX_VIEW_LAG_Q)


## The view lag in ticks, or -1 for none sent.
func view_lag_ticks() -> float:
	return float(view_lag_q) * 0.25 if view_lag_q >= 0 else -1.0


## Whether two inputs are identical, so a held-still player costs less.
func _equals(other: DotNetInput) -> bool:
	var them := other as ArenaNetCommand

	if them == null:
		return false

	return move.equals(them.move) and fire.equals(them.fire) and view_lag_q == them.view_lag_q


## Bits one command costs, before dot-net's own framing.
static func estimated_bits() -> int:
	return DotFpsCommand.estimated_bits() + 4 + DotWeaponCommand.BUTTON_BITS + 1


func describe() -> Dictionary:
	return {
		"tick": tick,
		"move": move.describe(),
		"fire": fire.describe(),
		"view_lag_ticks": view_lag_ticks(),
	}
