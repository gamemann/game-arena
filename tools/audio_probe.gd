extends SceneTree

const ArenaPresentation := preload("../game/arena_presentation.gd")

## Asks whether this game actually makes a noise, on a machine that has a sound card.
##
## [b]This exists because every assertion about this game's audio passed while the game was
## silent.[/b] The catalogue was complete and argued over — positional shots, a flat hit
## marker, cull distances, concurrency caps, a priority order — and every path in it named
## an `.ogg` nobody had produced. `examples/headless_presentation.tscn` checks the
## catalogue, the culling and the caps, and it cannot check any of this: a headless run has
## no audio device, so [DotAudioManager] correctly builds a [DotAudioSinkNull] and the one
## question worth asking here never comes up.
##
## So this is the audio half of what `tools/screenshot.sh` is for the interface. It is the
## only thing in this repository that can tell "the game would make a noise" apart from
## "the game has a table of sounds".
##
## [b]It asks `is_playing`, not "did I get a handle".[/b] The first version of this file
## checked the handle and reported four sounds on a run in which the engine printed
## *"Playback can only happen when a node is inside the scene tree"* four times — a handle
## for a voice that never sounded, which is this family's "a value produced correctly and
## consumed by nothing" in the one place built to catch exactly that. A probe that can be
## satisfied by the bug it is looking for is worse than no probe.
##
## [b]And it runs in `_process`, not `_initialize`.[/b] That is what the above was caused
## by: during `_initialize` the root viewport is not live yet, so an [AudioStreamPlayer]
## parented under it is not inside the tree and refuses to play. Nothing about the game is
## wrong there — the probe was asking before the engine could answer.
##
## Run through `tools/audio_probe.sh`. [b]Not `--headless`[/b]: `AudioServer` reports
## `Dummy` there. See [method DotAudioSink.device_present] — the driver name is the only
## honest question to ask about audio, and everything else the engine reports about it is
## plausible on a machine with no sound at all.

## What the game plays that a player has to be able to place. One of each kind: two
## positional shots that must not sound alike, a flat interface sound, a world sound.
const PROBES: Array[StringName] = [&"fire_rifle", &"fire_rail", &"hit_marker", &"pickup"]

## Frames to let the tree come up before asking anything.
const SETTLE := 2

var _presentation: Node = null
var _frame := 0
var _failed := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	print("driver:  %s" % AudioServer.get_driver_name())


func _process(_delta: float) -> bool:
	_frame += 1

	if _frame < SETTLE:
		return false

	if not DotAudioSink.device_present():
		print("")
		print("No audio device. Run this through tools/audio_probe.sh, which uses xvfb-run;")
		print("--headless gives a Dummy driver and this probe cannot say anything.")
		quit(2)
		return true

	if _presentation == null:
		return _build()

	return _sound()


func _build() -> bool:
	var p := ArenaPresentation.new()
	p.name = "AudioProbe"
	root.add_child(p)

	var ready: DotResult = p.setup()

	if not ready.ok:
		print("the presentation did not set up: %s" % ready.error.message)
		quit(1)
		return true

	_presentation = p

	var sink := p.audio.sink as DotAudioSinkGodot

	print("sink:    %s" % p.audio.sink.sink_name())

	if sink == null:
		print("")
		print("The device is present and the manager still built a null sink.")
		quit(1)
		return true

	print(
		"bank:    %d entries over %d ids" % [sink.bank.size(), p.audio.catalogue.ids().size()]
	)
	print(
		"files:   %d of the catalogue's paths do not exist"
		% p.audio.catalogue.missing_files().size()
	)
	print("")

	# Not the next frame: a voice has to be given a moment to actually start before
	# `is_playing` means anything.
	return false


func _sound() -> bool:
	var p := _presentation
	var sink := p.audio.sink as DotAudioSinkGodot

	for id in PROBES:
		# Through the MANAGER, not the sink: the limits, the culling and the mixer are the
		# part a stand-in has to survive. A bank that only plays when called directly is a
		# bank that goes quiet the moment the game is busy.
		var handle: int = p.audio.play_at(id, Vector3(2.0, 0.0, 0.0))

		# The question. A handle says the pool had room; this says a speaker is moving.
		var sounding: bool = handle != 0 and sink.is_playing(handle)

		print("  %-12s %s" % [String(id), "sounding" if sounding else "SILENT"])

		if not sounding:
			_failed += 1

	print("")

	if _failed > 0:
		print("RESULT: %d of %d made no sound." % [_failed, PROBES.size()])
		quit(1)
		return true

	print(
		"RESULT: all %d sounded, from %d synthesised stand-ins."
		% [PROBES.size(), sink.bank.size()]
	)
	quit(0)
	return true
