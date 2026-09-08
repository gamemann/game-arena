class_name ArenaRequest
extends DotNetMessage

## A client asking the server for something. Reliable, rare, and never trusted.
##
## The counterpart to [ArenaEvent]. Same shape and the same reason: one message type
## with a kind inside it, so adding a request is not a wire-id change on both ends.
##
## [b]Nothing in here is a fact.[/b] A request says what a client wants; the server
## decides. In particular the sender is taken from the transport in
## [ArenaNetLink], never from a field in the body — a peer id inside a payload is a
## claim anybody can make.

const NAME := &"arena.request"

const KIND_BITS := 5
const MAX_BODY := 2048

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


static func of(p_kind: int, p_body: PackedByteArray = PackedByteArray()) -> ArenaRequest:
	var request := ArenaRequest.new()
	request.kind = p_kind
	request.body = p_body
	return request


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= ArenaEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "ArenaRequest(%s, %d bytes)" % [ArenaEvents.ask_name(kind), body.size()]
