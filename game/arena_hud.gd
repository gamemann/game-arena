@tool
extends DotHud

const ArenaGame := preload("res://game/arena_game.gd")
const ArenaPlayer := preload("res://game/arena_player.gd")

## The in-game display: crosshair, health, armour, ammo, kill feed, round timer.
##
## [b]Built here rather than shipped by dot-ui, and that is the division of labour.[/b]
## dot-ui knows how to draw a bounded self-expiring list of coloured fragments; it does
## not know what a kill is. It knows how to draw a bar from a `Callable`; it does not
## know what health is. Every widget below is a dot-ui class bound to a game value, and
## the binding is the only thing in this file.
##
## No art. The theme is generated, the crosshair is drawn, and the bars are rectangles
## — which is what the rest of a dev-textured game looks like anyway.

## The player this HUD is about. Rebound on spawn, because the body is replaced.
var player: ArenaPlayer = null

var game: ArenaGame = null

var crosshair: DotCrosshair = null
var health_bar: DotStatBar = null
var armour_bar: DotStatBar = null
var ammo_bar: DotStatBar = null
var feed: DotFeedView = null
var timer_label: Label = null

## Seconds left, when something other than this game's own match knows. NAN means
## "ask the match", which is what a server and an offline client do.
var remaining_override: float = NAN
var score_label: Label = null

## What the round is about, when it is about something. Empty in a deathmatch.
##
## One line rather than a widget per objective, because the two modes that have any
## want completely different pictures — a hill wants a clock and a flag wants two
## states — and a widget general enough for both would draw neither well. A game that
## wants a proper objective HUD builds it; this is the line that says a mode is
## running and how far along it is.
var objective_label: Label = null


## Builds every widget. Call after adding to the tree.
func build(p_game: ArenaGame) -> void:
	game = p_game

	crosshair = DotCrosshair.new()
	crosshair.name = "Crosshair"
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.fov_degrees = 75.0
	crosshair.length = 7.0
	crosshair.base_gap = 3.0
	crosshair.thickness = 2.0
	# Bound to the weapon's actual spread, so the crosshair opening means something.
	# A crosshair that opens by an arbitrary factor tells the player something
	# confident and wrong about where their shots will go.
	crosshair.bind(func() -> Variant:
		return player.spread_degrees() if _live() else 0.0
	)
	add_child(crosshair)

	health_bar = _make_bar("Health", "%d", Vector2(24.0, -96.0), Vector2(220.0, 34.0))
	health_bar.fill_colour = Color(0.35, 0.80, 0.45)
	health_bar.low_colour = Color(0.90, 0.30, 0.28)
	health_bar.bind(func() -> Variant:
		return player.health.health if _live() else 0.0
	)
	health_bar.max_source = func() -> Variant:
		return player.health.max_health if _live() else 100.0

	armour_bar = _make_bar("Armour", "%d", Vector2(24.0, -56.0), Vector2(220.0, 26.0))
	armour_bar.fill_colour = Color(0.35, 0.62, 0.95)
	armour_bar.low_fraction = 0.0
	armour_bar.bind(func() -> Variant:
		return player.health.armour if _live() else 0.0
	)
	armour_bar.max_source = func() -> Variant:
		return player.health.max_armour if _live() else 100.0

	ammo_bar = _make_bar("Ammo", "%d", Vector2(-240.0, -96.0), Vector2(216.0, 34.0))
	ammo_bar.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo_bar.offset_left = -240.0
	ammo_bar.offset_top = -96.0
	ammo_bar.offset_right = -24.0
	ammo_bar.offset_bottom = -62.0
	ammo_bar.show_bar = false
	ammo_bar.bind(func() -> Variant:
		if not _live():
			return 0.0
		var slot := player.arsenal.current()
		return float(slot.magazine) if slot != null else 0.0
	)
	ammo_bar.max_source = func() -> Variant:
		if not _live():
			return 1.0
		var slot := player.arsenal.current()
		return float(maxi(1, slot.def.magazine)) if slot != null else 1.0

	feed = DotFeedView.new()
	feed.name = "KillFeed"
	feed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	feed.offset_left = -480.0
	feed.offset_top = 12.0
	feed.offset_right = 0.0
	feed.offset_bottom = 140.0
	feed.max_lines = config.feed_lines
	feed.lifetime_sec = config.feed_lifetime_sec
	feed.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(feed)

	timer_label = _make_label("Timer", Control.PRESET_CENTER_TOP, Vector2(0.0, 8.0))
	score_label = _make_label("Score", Control.PRESET_CENTER_TOP, Vector2(0.0, 34.0))
	score_label.theme_type_variation = &"DotDim"

	objective_label = _make_label(
		"Objective", Control.PRESET_CENTER_TOP, Vector2(0.0, 58.0)
	)
	objective_label.theme_type_variation = &"DotDim"

	if game != null:
		game.player_killed.connect(_on_kill)


func _make_bar(
	node_name: String,
	format: String,
	offset: Vector2,
	size_hint: Vector2
) -> DotStatBar:
	var bar := DotStatBar.new()
	bar.name = node_name
	bar.format = format
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_left = offset.x
	bar.offset_top = offset.y
	bar.offset_right = offset.x + size_hint.x
	bar.offset_bottom = offset.y + size_hint.y
	bar.ease_sec = 0.18
	add_child(bar)
	return bar


func _make_label(
	node_name: String,
	preset: Control.LayoutPreset,
	offset: Vector2
) -> Label:
	var label := Label.new()
	label.name = node_name
	label.set_anchors_preset(preset)
	label.offset_top = offset.y
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label


## Points the HUD at a player. Called on every spawn.
##
## The widgets hold a `Callable` that reads `player`, so re-pointing this one field
## repoints all of them. Binding each widget to a body would mean rebinding six
## callables every time someone respawns, and the one that got missed would show the
## previous life's health for ever.
func follow(p_player: ArenaPlayer) -> void:
	player = p_player


func _live() -> bool:
	return player != null and is_instance_valid(player)


## Puts a kill on the feed.
##
## Public because on a NETWORKED client nothing local scores anything: `game.player_killed`
## fires on the server, and the client learns about a kill from an `ArenaEvents.Kind.KILL`
## event. `ArenaClient` rebuilds the entry and calls this; the signal path below is the
## offline and listen-server one. Both end in the same place deliberately — a feed that
## looked different depending on how the kill arrived would be two feeds.
func show_kill(entry: DotKillFeed.Entry) -> void:
	_on_kill(entry)


func _on_kill(entry: DotKillFeed.Entry) -> void:
	if feed == null:
		return

	var mine := Color(1.0, 0.85, 0.35)
	var theirs := Color(0.86, 0.88, 0.92)
	var me := str(player.player_id) if _live() else ""

	feed.add_kill(
		entry.killer_name,
		mine if entry.killer_key == me else theirs,
		String(entry.cause),
		entry.victim_name,
		mine if entry.victim_key == me else theirs,
		entry.headshot
	)


## Fills the feed from kills that happened before this HUD existed.
##
## What a client joining a match in progress needs, and what a HUD rebuilt after a
## settings change needs. `DotKillFeed` is bounded and keeps its entries, so the last
## few are always available -- taking them is one call and not having it is a feed that
## is empty until the next person dies.
func catch_up(since_tick: int = -1) -> int:
	if game == null or feed == null:
		return 0

	var entries := (
		game.match_node.feed.recent(feed.max_lines) if since_tick < 0
		else game.match_node.feed.since(since_tick)
	)

	for entry in entries:
		_on_kill(entry)

	return entries.size()


## Refreshes the two labels that are not widgets.
##
## The round timer and the score are read once a frame rather than through a
## `DotHudWidget`, because both are strings assembled from several values and a widget
## exists to bind one.
func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or game == null or timer_label == null:
		return

	# The override first, when there is one.
	#
	# [b]A networked client's own `DotMatch` never runs.[/b] Nothing ticks it, so
	# `seconds_remaining()` is derived from `_ticks_in_state` against a `_current_tick`
	# that is still 0 — a number nothing ever wrote, not a stale one. A connected
	# browser client showed "IDLE" for ever while the server was playing a round.
	# `ArenaClient` writes the server's figure here from the MATCH event.
	var remaining := (
		remaining_override if not is_nan(remaining_override)
		else game.match_node.seconds_remaining()
	)

	timer_label.text = (
		DotMatch.State.keys()[game.match_node.state] if remaining < 0.0
		else "%d:%02d" % [int(remaining) / 60, int(remaining) % 60]
	)

	var leader := game.match_node.scoreboard.leader()
	score_label.text = (
		"" if leader == null
		else "%s  %d / %d" % [
			leader.display_name, leader.score, game.match_node.rules.score_limit
		]
	)

	if objective_label != null:
		objective_label.text = _objective_line()


## One line about the objectives, or nothing at all.
##
## Reads the mirroring manager on a client and the real one on a listen server, which
## is the same object either way: `ArenaObjectives` holds a `DotObjectiveManager` whose
## `authoritative` decides whether it simulates, and a HUD asking it for a fraction does
## not care which.
func _objective_line() -> String:
	if game.objectives == null or game.objectives.manager == null:
		return ""

	var manager := game.objectives.manager

	if not manager.has_objectives():
		return ""

	var parts := PackedStringArray()

	for objective in manager.objectives.objectives:
		var label := objective.def.label if objective.def.label != "" \
			else String(objective.id())

		if objective is DotObjectiveHoldout:
			var holdout := objective as DotObjectiveHoldout
			var lead := holdout.leader()
			if lead <= 0:
				parts.append("%s --" % label)
			else:
				var left := holdout.remaining_for(lead)
				parts.append(
					"%s %d:%02d" % [
						label,
						left / (60 * game.tick_rate),
						(left / game.tick_rate) % 60,
					]
				)
		elif objective is DotObjectiveFlag:
			var flag := objective as DotObjectiveFlag
			parts.append(
				"%s %s" % [
					label,
					DotObjectiveFlag.State.keys()[flag.state].substr(0, 4),
				]
			)
		elif objective.owner_team > 0:
			parts.append("%s:%d" % [label, objective.owner_team])
		else:
			parts.append("%s %d%%" % [label, int(objective.progress() * 100.0)])

	return "  ".join(parts)
