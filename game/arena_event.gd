extends DotNetMessage

const ArenaEvent := preload("arena_event.gd")
const ArenaEvents := preload("arena_events.gd")

## Anything the authority tells a client that is not a snapshot. Reliable, to clients.
##
## A kind and a body, rather than one message type per event. dot-net seals its message
## registry by sorting the type names and assigning wire ids from that order, so every
## message type added is a wire-id change on both ends — and the two ends are separate
## programs the moment a browser connects. One message with a kind inside it moves that
## versioning problem into a field this game owns.

const NAME := &"arena.event"

## Bits the kind occupies. Five is 32 kinds; there are far fewer and there will not be
## thirty-two.
const KIND_BITS := 5

const MAX_BODY := 16384

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


static func of(p_kind: int, p_body: PackedByteArray) -> ArenaEvent:
	var event := ArenaEvent.new()
	event.kind = p_kind
	event.body = p_body
	return event


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= ArenaEvents.Kind.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown event kind %d." % kind)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "ArenaEvent(%s, %d bytes)" % [ArenaEvents.kind_name(kind), body.size()]
