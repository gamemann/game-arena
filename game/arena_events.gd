extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, because they have to be exact inverses and nothing
## checks that for you. `headless_net` round-trips every one of them, which is the only
## reason to be confident: **the two ends of a serialisation are exactly as capable of
## never meeting as the two ends of a wire**, and this family has shipped a stored voice
## mute that loaded back as a warning.
##
## [b]HELLO carries the tick rate, and the client is expected to adopt it.[/b] That
## sentence is the largest measured error in this family's history: g2gfast's client
## took its rate from `Engine.physics_ticks_per_second`, which a browser shell never
## sets, and ran at 60 against a 128-tick server — correction rate 0.96, and every run
## time wrong by 128/60. Do not add a second source for this number.

enum Kind {
	## Tick rate, who you are, the map, the rules, the server's current tick.
	HELLO,
	## A player joined, or is being described to a client that just connected.
	JOIN,
	## A player left.
	LEAVE,
	## Somebody was killed. Drives the kill feed.
	KILL,
	## The match state, the clock and the score limit changed.
	MATCH,
	## A player's score changed.
	SCORE,
	## Text for everybody: a vote, an admin's message, a refusal.
	NOTICE,
}

enum Ask {
	## I have loaded my scene and can receive. Tell me everything.
	##
	## [b]Nothing may be sent to a peer before this arrives.[/b] dot-server's signon
	## finishes and *then* the client builds its scene; everything sent in between
	## lands on a node that does not exist and is lost, one "Node not found" per call.
	READY,
	## Put me back in the match — the player pressed the respawn key.
	RESPAWN,
	## My display name, if the client wants one the server did not already know.
	NAME,
	## Do something with a prop: grab, release, freeze or punt.
	##
	## [b]An intent, not an action, and the whole reason dot-props needs one.[/b] A
	## rigid body's contact solver is not reproducible across machines, so props are
	## server-authoritative and unpredicted — a client that moved one locally would be
	## corrected on the next snapshot, every snapshot. The body carries what the
	## player did and where they were aiming; the server decides whether it happened.
	PROP_TOOL,
}

## What a [constant Ask.PROP_TOOL] asks for.
enum PropAct {
	## Hold what I am looking at, and keep holding it.
	GRAB,
	## Let go.
	RELEASE,
	## Freeze what I am holding where it is.
	FREEZE,
	## Punt what I am looking at away from me.
	PUNT,
	## Pull what I am looking at towards me.
	PULL,
}

## Bits a prop action occupies. Three, which is eight — twice what there are.
const PROP_ACT_BITS := 3

const NAME_BYTES := 64
const MAP_BYTES := 64
const TEXT_BYTES := 256

## Bits a weapon name occupies in a KILL. Short because it is a label, not an id.
const WEAPON_BYTES := 32


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func ask_name(ask: int) -> String:
	var names := Ask.keys()
	return String(names[ask]) if ask >= 0 and ask < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


# --- HELLO -----------------------------------------------------------------

## Everything a client needs before it can mirror anything.
static func write_hello(
	tick_rate: int,
	session_id: int,
	peer_id: int,
	server_tick: int,
	map_name: String,
	score_limit: int,
	time_limit_sec: float
) -> PackedByteArray:
	var writer := _w()
	writer.write_uint(tick_rate, 8)
	writer.write_varint(session_id)
	writer.write_varint(peer_id)
	writer.write_uint(server_tick, 32)
	writer.write_string(map_name, MAP_BYTES)
	writer.write_uint(score_limit, 16)
	writer.write_float32(time_limit_sec)
	return writer.to_bytes()


static func read_hello(reader: DotNetReader) -> Dictionary:
	var out := {
		"tick_rate": reader.read_uint(8),
		"session_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"server_tick": reader.read_uint(32),
		"map_name": reader.read_string(MAP_BYTES),
		"score_limit": reader.read_uint(16),
		"time_limit_sec": reader.read_float32(),
	}
	out["ok"] = reader.ok()
	return out


# --- LEAVE -----------------------------------------------------------------

static func write_leave(session_id: int) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(session_id)
	return writer.to_bytes()


static func read_leave(reader: DotNetReader) -> Dictionary:
	var out := {"session_id": reader.read_varint()}
	out["ok"] = reader.ok()
	return out


# --- PROP_TOOL -------------------------------------------------------------

## What a player did with a prop tool, and where they were looking when they did it.
##
## [b]The aim is on the wire and the position is not.[/b] The server already knows
## where a player is — it simulated them — and a client that could name its own origin
## could grab a prop from across the map. The direction it cannot know, because a
## player's view between two ticks is theirs; so the direction is a claim, the origin
## is a fact, and `DotPropTool.target` is handed one of each.
##
## The direction is quantised the same way an aim is everywhere else here: two angles
## rather than three components, because a unit vector sent as three floats is three
## numbers that can fail to be a unit vector.
static func write_prop_act(act: int, yaw: float, pitch: float) -> PackedByteArray:
	var writer := _w()
	writer.write_uint(act, PROP_ACT_BITS)
	# Twelve bits: about a tenth of a degree, which at a twenty-metre grab range is a
	# couple of centimetres at the far end. Nine — the default a view angle uses — is
	# 0.7 degrees and would be a quarter of a metre out there, which is the difference
	# between grabbing the crate and grabbing the one behind it.
	writer.write_angle(yaw, 12)
	writer.write_angle(pitch, 12)
	return writer.to_bytes()


static func read_prop_act(reader: DotNetReader) -> Dictionary:
	var out := {
		"act": reader.read_uint(PROP_ACT_BITS),
		"yaw": reader.read_angle(12),
		"pitch": reader.read_angle(12),
	}
	out["ok"] = reader.ok()
	return out


# --- KILL ------------------------------------------------------------------

## One line of the kill feed.
##
## The killer is a session id and **0 means the world** — a fall, a slay, a map hazard.
## Not the empty string this game uses internally for the same idea: a string on the
## wire for a value with exactly two shapes is a string somebody will put a name in.
static func write_kill(
	killer_id: int, victim_id: int, weapon: String, headshot: bool
) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(killer_id)
	writer.write_varint(victim_id)
	writer.write_string(weapon, WEAPON_BYTES)
	writer.write_bool(headshot)
	return writer.to_bytes()


static func read_kill(reader: DotNetReader) -> Dictionary:
	var out := {
		"killer_id": reader.read_varint(),
		"victim_id": reader.read_varint(),
		"weapon": reader.read_string(WEAPON_BYTES),
		"headshot": reader.read_bool(),
	}
	out["ok"] = reader.ok()
	return out


# --- MATCH -----------------------------------------------------------------

static func write_match(state: int, remaining_ticks: int, round_number: int) -> PackedByteArray:
	var writer := _w()
	writer.write_uint(state, 4)
	# `write_svarint`, not `write_varint`. "No limit" is negative and a match past its
	# clock reports a negative remainder; `write_varint` pushes an engine error and
	# writes 0 for a negative, so an unsigned one here would have turned "eight ticks
	# over" into "no time has passed" with a red line in the log and nothing failing.
	# Zigzag also keeps a small negative to one byte, which two's complement would not.
	writer.write_svarint(remaining_ticks)
	writer.write_uint(round_number, 16)
	return writer.to_bytes()


static func read_match(reader: DotNetReader) -> Dictionary:
	var out := {
		"state": reader.read_uint(4),
		"remaining_ticks": reader.read_svarint(),
		"round": reader.read_uint(16),
	}
	out["ok"] = reader.ok()
	return out


# --- SCORE -----------------------------------------------------------------

static func write_score(session_id: int, kills: int, deaths: int) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(session_id)
	writer.write_varint(kills)
	writer.write_varint(deaths)
	return writer.to_bytes()


static func read_score(reader: DotNetReader) -> Dictionary:
	var out := {
		"session_id": reader.read_varint(),
		"kills": reader.read_varint(),
		"deaths": reader.read_varint(),
	}
	out["ok"] = reader.ok()
	return out


# --- NOTICE ----------------------------------------------------------------

static func write_notice(text: String) -> PackedByteArray:
	var writer := _w()
	writer.write_string(text, TEXT_BYTES)
	return writer.to_bytes()


static func read_notice(reader: DotNetReader) -> Dictionary:
	var out := {"text": reader.read_string(TEXT_BYTES)}
	out["ok"] = reader.ok()
	return out


# --- Requests --------------------------------------------------------------

static func write_name(display_name: String) -> PackedByteArray:
	var writer := _w()
	writer.write_string(display_name, NAME_BYTES)
	return writer.to_bytes()


static func read_name(reader: DotNetReader) -> Dictionary:
	var out := {"display_name": reader.read_string(NAME_BYTES)}
	out["ok"] = reader.ok()
	return out
