class_name ArenaEvents
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
}

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
