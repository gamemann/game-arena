# game-arena

The reference game. Read `../../CLAUDE.md` first for the family-wide rules; this file
is what is specific to using them together.

## Why this project exists

Every addon passes its own suite, and **every one of those suites runs one addon
with the others absent**. dot-platform makes the point in its own notes and it is the
lesson of every bug this family has found: *a code path only one deployment shape
reaches is a code path nothing has run.*

game-arena is the deployment shape where **twenty-six addons** are present at once. It
is a game, and it is also the only test of the joins between them.

```
the fight        dot-player-controller  dot-combat  dot-loadout  dot-match
what you keep    dot-stats  dot-achievements  dot-leaderboard
the world        dot-map  dot-props  dot-npc  dot-npc-ai  dot-npc-ai-director
what plays next  dot-vote
who you are      dot-auth  dot-user  dot-user-avatar  dot-platform  dot-cloud
the server       dot-server  dot-net  dot-chat  dot-voice  dot-moderation
                 dot-browser (its query half)
the screen       dot-ui
everything       dot-core
```

**Each of those is a few lines, and each is a few lines *because* the addons refuse to
know about each other.** The list of joins is under "Where the seams are".

## One description, three representations

`ArenaMap` holds a list of `AABB`s. `to_scene()` makes meshes and static bodies,
`to_fps_body()` makes a `DotFpsFlatBody`, `to_trace()` makes a `DotTraceFlat`.

Building those independently is the obvious approach and it is wrong in a way nothing
reports: the server's idea of a wall moves a metre and shots start passing through
something clients can see. The self-test asserts all three have the same box count and
that a shot at the perimeter stops at it.

It is also why a dev-textured game is easy to reason about: the geometry *is* the
gameplay, and there is not a separate art pass that could disagree with it.

The texture is generated (`ArenaMap.dev_texture`) and triplanar-mapped, because a
`BoxMesh` UV-maps every face to the same 0..1 square — without triplanar a two-metre
box and a forty-metre wall show the same number of grid squares, and the texture stops
telling you anything about scale, which is its only job.

## One id space

`ArenaPlayer.player_id` is the scoreboard key, the combat entity id, the damage
attribution and the loadout key. dot-server's `session.userid` feeds it.

Two things fall out of that:

- `DotArsenal.attacker_id()` defaults to the parent node's *instance id*, which is a
  fourth id space. `ArenaPlayer.PlayerArsenal` overrides it. Without that, damage
  arrives attributed to a number no scoreboard has ever heard of.
- The loadout key is `"arena-player-%08d"`, not `str(id)`. `DotLoadoutKey.is_usable`
  has a minimum length, so a bare `"7"` is refused before any store sees it — and the
  check exists so a malformed key can never reach a filesystem path. Padding is right;
  loosening the check is not.

**Use the session id, never the peer id.** A peer id is reassigned the moment someone
reconnects, and everything downstream would be handed to the next player to join.
`ArenaModule._add` says so at the point it matters.

## Order inside a tick

`ArenaGame.tick()` and `ArenaPlayer.simulate_tick()` both have an order that is not
arbitrary:

1. **Movement, then the shot.** Half a tick of movement at arena speeds is fifteen
   centimetres, which at range is a miss.
2. **Spread inputs pushed from the simulated state**, never read from a rendered one.
   An interpolated position differs between client and server by design.
3. **Aim from the movement command**, not a second sample. Sampling the mouse twice
   gives a shot that leaves at a different angle than the player was looking along.
4. **All shots resolved after everyone has moved**, so a shot is traced against the
   world as it ends the tick.
5. **The match ticks last**, so a kill scored this tick can end the round this tick
   rather than the next one.

## Where the seams are, and what they cost

Every join between two addons is a few lines, and each is a few lines *because* the
addons refuse to know about each other:

| Join | What it is |
| --- | --- |
| loadout → combat | `ArenaPlayer.give_loadout`, a table from item id to `DotWeapon` |
| combat → match | `ArenaGame._on_entity_killed`, `entity_killed` → `report_kill` |
| match → loadout | `ArenaGame._on_respawn_due` → `_apply_loadout_deferred` |
| movement → combat | `arsenal.movement/airborne/crouched` pushed from `DotFpsState` |
| match → ui | `ArenaHud._on_kill`, a `DotKillFeed.Entry` → coloured fragments |
| game → server | `ArenaModule`, one of the two files that name dot-server |
| combat → stats | `ArenaProgress._on_shot_resolved` / `_on_killed`, a kill feed entry to four counters |
| stats → achievements | `DotAchievementStatsLink`, which **differences** rather than connecting |
| stats → leaderboard | `ArenaBoards.submit_session`, once per session rather than per kill |
| map → game | `ArenaMapSession.change_to_map` → `ArenaGame.change_map` |
| map → clients | `DotMapSyncHost.send_fn` → `ArenaNetLink.send_map` |
| vote → map | `ArenaVoteSource.apply`, routed on a `map:` / `mode:` prefix |
| npc → combat | `ArenaHorde._register_combat`, hitboxes and health under one entity id |
| npc → game | the brain reaches `ArenaHorde` through `DotRegistry`, never by name |
| chat → server | `ArenaServices._on_player_chat`, which **cancels** dot-server's own |
| voice → wire | `ArenaNetLink.send_voice`, on a channel of its own |
| moderation → everything | two registry names nobody imports: `dot_mute_source`, `dot_ban_source` |

`_on_entity_killed` passes `""` for a world death rather than `"0"`. dot-match reads an
empty killer key as "the world"; `"0"` would create a scoreboard record for a player
who does not exist.

`_apply_loadout_deferred` does not await inside the respawn handler. A loadout comes
from a store, which may be slow; a respawn may not be. The player is in the world with
whatever they had and the loadout arrives a frame later.

`apply_loadout` falls back to the default on *any* failure. An unreachable loadout
store is a reason to give someone a rifle, not a reason to leave them watching.

## Movement is a game's choice

`ArenaPlayer.arena_tunables()` is fast, floaty, high air control, and has no sprint.
None of it is dot-player-controller's default — the addon ships numbers that feel like a
modern shooter, and this is a deliberate departure. The air-acceleration and
wish-speed-cap pair is the classic formula: it does nothing when you hold forward and
everything when you turn while strafing.

Health does not regenerate, for the same kind of reason: regeneration turns every fight
into a question of who disengages first, which is a different game.

## The netcode bridge

`ArenaNetBridge` is the only file that names both `ArenaGame` and `DotNetManager`, and it
is a file rather than a few lines because **the ordering is the hard part**. dot-net
simulates per entity; this game's tick order is a whole-game property. Those two facts
meet in `ensure_game_ticked`: the first `_net_simulate` on a given tick drives the entire
game and the rest find it done.

Three things in it that are not obvious:

- **`Authority.SHARED`, not `SERVER`.** The server stays authoritative and corrects; the
  owning client predicts. `DotNetIdentity.is_predicted()` is false for any other
  authority, so `SERVER` would mean a player seeing their own movement a full round trip
  late.
- **The acknowledgement rides the input packet.** dot-net owns no client-to-server
  channel, so `encode_ack()` produces four fixed-width bytes that go in front of the
  bit-packed command — in front, because a bit-packed command is not fixed width and a
  reader that had to skip it would have to decode it first.
- **The server tick calls `ensure_game_ticked` again afterwards.** A server with no
  players registered runs no behaviours at all, and the match clock still has to advance.

`ArenaPlayerNet` resolves `DotFpsNetSync` and `DotCombatNetSync`'s specs against
`DotNetVar.Type`, which is the whole of why neither addon has to know dot-net exists.
Ammunition is declared `to_owner_only()` — not a bandwidth saving: exact ammunition is
information an opponent should not have, and data never sent cannot be read out of a
modified client.

**`receive_snapshot` must not reconcile.** `DotNetManager.receive_snapshot` already routes
a predicted entity's state to `DotNetPredictor.reconcile` rather than applying it, and
acknowledges the inputs it covers. This file used to do a second pass on top of that,
replaying the same inputs against values that had already been rewound. Nothing failed —
the client still converged, because the second replay started from the first one's answer
— and the only visible cost was in the number that exists to measure exactly this:
`correction_rate()` read **0.500** with the extra pass and **0.032** without. A rate near
a half is what `DotNetPredictor` documents as "the two simulations disagree, and no
smoothing will fix that". Found from `game-hungario`, whose bridge was written from this
one and inherited it.

## The client

`ArenaClient` is everything a person needs on top of `ArenaGame`, and a dedicated
server never loads it: a camera rig, input sampling, the renderer, the HUD, the menus
and the keys. Until it existed this was the reference game with nothing to sit down at.

Four decisions in it are not obvious, and three of them were bugs first.

**It uses `Mode.HEADLESS` collision, on a client with a screen.** That reads like the
wrong setting and is the only correct one. `HEADLESS` is `ArenaMap`'s analytic geometry
— the same list of `AABB`s the meshes come from — and what matters is the last clause
of dot-player-controller's own note on it: *it gives the same answer on a client replaying
a tick and a server that ran it.* **A predicting client must use the same collision
backend as the server it is predicting against.** Godot physics on the client is a
second solver with its own contact epsilons; every replay would land somewhere slightly
different and reconciliation would correct a client that had done nothing wrong. It was
tried the other way first: `Mode.PHYSICS` wants a collision shape on the player node,
`ArenaPlayer` is a plain `Node3D`, and the player fell through a floor that was drawn
perfectly — a void with one box in it and no error anywhere.

**It watches `player_added`, not `player_spawned`.** `player_spawned` comes out of
dot-match's respawn queue, which runs on the *authority*; a mirroring client never
fires it. A client waiting on it waits for ever, and the symptom is the most misleading
in this project: the HUD binds by id and works, the scoreboard works, the connection is
live, and there is no camera and no world at all, because both hang off that one
reference. `ArenaGame.player_added` was added for this. It is the same bug g2gfast
shipped, one signal over.

**It owns the mouse; `DotScreenStack.manage_mouse` is off.** dot-ui's stack forces
CAPTURED whenever no screen is open, which is right on a desktop and impossible in a
browser: pointer lock needs transient user activation and a browser refuses it
*silently* — `Input.mouse_mode` reads back as CAPTURED while the cursor sits on top of
the game. Two owners fighting over it is a cursor that flickers, which dot-ui's own
documentation says. So there is exactly one, and it knows about the click.

**It draws between ticks.** `ArenaPlayer.present` uses `DotFpsController.render_state`,
and `ArenaNetBridge._adopt_tick_rate` moves `Engine.physics_ticks_per_second` as well as
the game's, the config's and the clock's. Either half alone measures as no better than
doing nothing: the fraction a renderer interpolates at is a fraction through a *physics
frame*, which is a fraction through a tick only while the two rates agree.

## One number, written once

`ArenaGame.NET_WORLD_EXTENT` and `NET_SNAPSHOT_RATE` are constants on the game because
the module and the client both build a `DotNetConfig` and **a quantised position decoded
against a different range is a different position, not a less precise one**. They were
written separately — 128 in `ArenaModule`, 256 in `ArenaClient`, two files a hundred
lines apart — and what that looked like in a real browser was: connects, seals a
byte-identical message schema, adopts its own player alive with 100 health, logs every
stage correctly, and draws sky in every direction with a HUD reading zero. No error
anywhere, because there is no error. `headless_net._test_config_agreement` asserts the
two ends agree on the extent, the tick rate and the schema hash.

## Modes are data

`ArenaMode` is a `Resource`: an id, a `DotMatchRules`, a team count, and what damage
does. Free-for-all and team deathmatch differ only in what is written in one, so
adding a mode is writing a resource rather than writing a file — which is what makes
"configurable" true rather than aspirational. `ArenaModes` is the catalogue, shaped
exactly like `ArenaMap.by_id` / `ids` so a console command or a `DotVoteListSource`
can be handed `ids()` without knowing what a mode is.

**The line where data stops being enough is real.** A mode that changes what *happens*
on an event, rather than what an event is *worth*, needs code — gun game, where a kill
replaces your weapon, is the first, and it subclasses `DotMatchRules` and hangs it on
the mode. Everything short of that is the resource.

Four things in the wiring that are not obvious:

- **`team_count` and `rules.team_based` are two statements of one fact**, and
  `validate()` refuses a mode where they disagree. `team_based` is what dot-match reads
  to decide whether to assign anybody a side at all, so a mode claiming two teams over
  free-for-all rules puts everyone on no team and scores them individually *while
  calling itself Team Deathmatch* — correct at every point inside dot-match, and wrong.
- **The rules resource is duplicated before use.** A `Resource` is a reference, so
  handing dot-match the catalogue's own object means a server that raised a score limit
  at runtime has edited the mode every later match reads. This family has shipped that
  aliasing four times; the suite asserts two lookups are not the same object.
- **The team manager is built before `add_child(match_node)`**, because that is what
  runs `DotMatch._ready` and therefore `setup`, and setup only makes one when it finds
  none. Left to dot-match it makes an untagged `standard_pair()`, and untagged is the
  whole problem — `DotTeam.spawn_tag` is what sends a side to its own end of the map.
  Without it both sides draw from one pool, which on a symmetric map means spawning in
  the enemy base about half the time and reads as a spawn-selection bug.
- **`combat.resolver.team_of` is the entire friendly-fire seam**, and it is assigned
  *after* `add_child(combat)` because the resolver is built in `setup`. dot-combat has
  no idea what a team is: it asks a callable for two entity ids and compares the
  answers, treating 0 as "no team" so a free-for-all still works. Unwired,
  `friendly_fire = false` protects nobody, because every pair looks like strangers.

`ArenaPlayer.team` had been declared and assigned by **nothing** since the class was
written — the family's most repeated shape, at the size of a whole feature. It is what
the scoreboard, the renderer and the friendly-fire check all read.

`ArenaMap.spawns` gained a parallel `spawn_tags`, and `add_spawn(at, tag)` is the only
way to append: two parallel arrays that can be written independently are two lists that
will disagree, and the helper is the only reason they cannot.

## Where it runs besides here

`dot-server-deploy` vendors it — `setup.sh` copies `game/`, `scenes/*.tscn` and
`maps/`, `content/arena/game.yml` points at `res://scenes/arena_server.tscn`, and the
browser shell maps content id `arena` to `res://game/arena.tscn`. It is **demo server
five**, on loopback `:6110` and nginx TLS `:6068`, at 64 ticks.

**`setup.sh` copies only `scenes/*.tscn`, not the scripts beside them**, which is why
`arena_server.gd` lives in `game/` and not next to its own scene. A script under
`scenes/` never reaches that build; the scene then fails to load with "referenced
non-existent resource", the module refuses to load because no game registered itself,
and the server reports "the game loaded but its module did not". Every other game in
the family already keeps its server scene's script in `game/`.

## Progression, and the one line that is not a signal connection

`ArenaStats` declares the numbers, `ArenaAwards` is a document of rules over them,
`ArenaBoards` orders them, and `ArenaProgress` is the node that joins all three to the
game. The ids are the contract and there is exactly one copy of them.

**The link between dot-stats and dot-achievements is not `stats.recorded.connect(...)`,
and writing it that way compiles, runs, and is wrong.** dot-stats' `recorded` carries
the player's *session* total — its whole design is that a session is what a server
counts and a delta is what it reports — and an achievement is about a lifetime. Wired
straight through, the running total is added to the lifetime total on every kill: two
after the second, five after the third, nine after the fourth, and 5,050 after a
hundred. `DotAchievementStatsLink` exists for exactly that and is what is used;
`headless_match` asserts that a player's lifetime kills equal their session kills,
which is the smallest check that can tell the two wirings apart.

Two other decisions worth naming:

- **A board is written when a player leaves, not when they score.** A submission reads
  the store, compares, writes and re-sorts; six of those per kill on a sixteen-player
  server is a sort per kill per board for a number nobody is looking at. A session is
  also the natural unit, because it is when a player's totals stop moving.
- **Accuracy and kill/death are derived, never stored.** A stored quotient is a third
  number that can disagree with the two it came from, and this family has shipped that
  disagreement often enough to know the price.

## Changing the map, which used to be impossible here

`ArenaGame.setup` builds the combat trace, the match node and every spawn point as
children in one pass and **is not re-entrant** — calling it twice leaves two matches,
two combat managers and two sets of spawns in one tree, all connected to the same
signals, with the second of each quietly winning. So the map was chosen at boot with
`-- --map <id>` and `arena_maps` listed what could be typed.

`ArenaGame.change_map` is the half that makes a change possible: **the teardown is the
feature.** Every join this game exists to test is a signal connection, and a connection
to a freed object is an error at the next emit rather than at the disconnect that was
skipped — which is why `ArenaProgress` has `unbind_world` / `bind_world` rather than one
`attach`.

What survives a change and what does not:

- **The players do.** Their nodes, their statistics and their loadouts are about a
  person on this server, not about a room. They are re-bodied against the new geometry
  — `ArenaPlayer.rebind_map`, and **assigning the body is not enough**, because
  `DotFpsMotor` holds a reference to the one it was built with.
- **The match does not.** A new map is a new match.
- **The combat manager does not**, because its trace *is* the map.

`ArenaMapDirector` is the half that makes it reach the players: a catalogue, a rotation
with a cooldown, a map clock with warnings and rtv, and `DotMapSyncHost` — announce,
wait for every peer, swap, tell them to load. Without the last of those a `changelevel`
is a change in one process and every client carries on playing a world that no longer
exists, which dot-map's own notes call "the structural one".

**Two bugs came out of wiring the client half, and both looked like something else.**
`DotMapSyncClient` accepts an announced map only if it is in *its own* catalogue at the
same version, or is delivered content whose scene resolves inside its own mount. Built
with no session it has no catalogue, so every arena map was refused with "a host may not
send a map that is not delivered content" — which is the correct answer to the question
it was being asked. And `DotMapSyncClient.changed` carries one argument where
`DotMapSession.changed` carries two, which is a runtime error on the first map change
and on no other occasion.

## Maps are content, and this game's maps are code

`ArenaMaps.catalogue()` builds a `DotMapCatalogue` from `ArenaMap.ids()` — **not from a
second list**, which is this tree's most repeated bug and has now happened to four
files. `DotMapDef.scene_path` names `arena_map.gd`, the script that actually produces
the map, and `meta.builder` says so out loud.

That is not a workaround. Everything dot-map does with a map def — rotation, cooldowns,
nominations, ballots, the sync protocol — works on the id and the version and never
opens the scene. The only thing that reads `scene_path` is `DotMapLoader`, and
`ArenaMapSession` overrides the load for a built-in map and falls through to `super` for
a delivered one. The path is a real file rather than a `code://` sentinel so a
validator can check it.

## Monsters, and a fourth id space

`siege` is the mode where dot-npc, dot-npc-ai, dot-npc-ai-director and dot-props are all
live at once. It is a real game — monsters make the middle of the map expensive to hold,
and movable cover is the only answer a player can build — and it is also the only place
the four run together.

**A monster's combat entity id is allocated now, by the `DotEntityTable` the game holds as `entities`.** It used to be `ENTITY_BASE + (npc.instance_id % ENTITY_BASE)` with `ENTITY_BASE = 1_000_000`, and the reasoning written here was about the wrong collision: the worry was a monster colliding with a *player*, and what actually collides is a monster with another monster. Godot's instance ids are neither small nor dense, so two a million apart produce one entity id; the second `register_health` overwrites the first and the loser is shootable, hittable and unkillable, with no error anywhere. An id from the table is `kind * 10^12 + serial`, so `is_npc_entity` asks the id what it names instead of comparing it against a constant, and `headless_match` asserts every monster alive has an id of its own rather than trusting the arithmetic.

**`ArenaPlayer` still uses the dot-server session id as its entity id, and that half is deliberately not converted.** In this game an entity id *is* a session id, and seven things depend on it: dot-match's scoreboard keys, dot-effects' per-entity scales, dot-stats rows, dot-spectate, the player-stack roster, the kill feed on the wire, and the client that rebuilds one from two ints it was sent. dot-effects is the one that makes it indivisible — it is keyed from **both** spaces today, `damage_taken_scale(damage.victim)` against `move_speed_scale(session_id)` — so a half-done conversion is an effect layer that silently stops applying to damage. Monsters were the half that was broken and they are the half that moved; the other half is a measured piece of work, not an oversight. The two cannot collide meanwhile, because a table id is above 10^12 and a session id is not.

Two things fell out of putting a non-player entity into dot-combat, and both were bugs
that had been latent since the combat manager was wired:

- **`_on_entity_killed` handed any entity id to `DotMatch.report_kill`**, which creates
  a scoreboard record keyed on a number no player has ever had. `non_player_killed` is
  the signal now, and `ArenaHorde` is what listens to it.
- **`_on_damage_applied` did the same to `report_damage`**, and `ArenaProgress` would
  have filed a stats session, a lifetime progress row and eventually a leaderboard entry
  against a monster.

Three more the suite found, all in the wiring rather than in the addons:

- **`DotNpcAiBrain._npc_ready` seeds the character and puts it on the context *before*
  calling `_build`.** A brain that assigns `character` inside `_build` gets neither:
  every monster of a kind shares its preset's seed, so all of them roll the same aim
  error at the same moment — the firing squad dot-npc-ai warns about — and
  `ctx.character` stays null for every node in the tree. Nothing errors.
- **`DotNpcSpawner._ready` builds its own `DotNpcSenses` when it finds none**, so
  assigning one after `add_child` leaves it configured and read by nobody.
- **The map's furniture shares a player's budget.** `may_spawn` checks
  `per_player_budget` against whatever owner it is given and the empty owner is an
  owner like any other, so eight props costing fourteen against a budget of twelve
  placed seven and refused the eighth silently.

## The server browser, from the other end

**dot-server has answered queries since it was written and nothing had ever asked
one.** `ArenaModule` contributes a query provider — the mode, the map, the round, the
state, how many monsters and props are in the world — and until `ArenaBrowser` existed,
the only thing in this family that could read it was a test.

`dedicated` now has a real browser ask a real `DotServer` over a real UDP socket. Two
things a reader of a query section gets wrong once, and both were got wrong here first:

- **The map is not `entry.map`.** That is dot-server's `info.map`, which means "the
  content id of the loaded game" and is empty on a server that never switches games.
  dot-browser nests a game's own section under `rules["game"]` precisely so a game
  putting a field called `map` in it cannot overwrite the other one.
- **The query port is a separate argument, not a third part of the address.**
  `DotBrowserTarget.parse` takes `host:port`; a three-part string parses as a malformed
  IPv6 address and fails at `connect_to_host` with "Invalid IPv6 address", several
  layers below anything that could say what was wrong.

**Filtering is local, and that is a rule rather than an optimisation.** A server does
not get to decide whether it appears in your list: you queried it, you hold the answer,
and a filter the server applied would be a filter the server could lie about.

## Chat, voice and moderation

`ArenaServices` is **the second file that names dot-server**, and the rule is now "two
files do, and here is what each is for": `ArenaModule` bridges a game to a server;
`ArenaServices` bridges a server to three addons that are not about the game at all.

**dot-chat and dot-server's own chat are not two chat systems here**, because exactly
one of them delivers a line. The `player_chat` event is hooked and *cancelled*, the text
goes to `DotChatRouter`, and the router's `send_fn` hands each recipient's line back to
dot-server's manager to put on the wire. What that buys is a radius channel, a whisper,
markup and invisible-character stripping, per-channel history, a backlog for a joining
player, and `!` commands the game can claim.

**Moderation is built first, and the order is load-bearing.** It publishes
`dot_mute_source` on `_ready`, and both routers look that name up when they start — a
chat router that started first would find nothing, warn once, and enforce no gag for the
life of the server.

**Voice has its own channel on the link, and picks its own transport.** A talk spurt is fifty frames a second per
speaker relayed to every listener; on the state channel it would sit in the same ordered
queue as the snapshots, so somebody holding the talk key would add a frame of latency to
everybody's movement. The speaker id is stamped from the transport's sender and never
read out of the payload — a client that could name its own could put words in anybody's
mouth, and the only symptom is words coming out of the wrong player.

**UDP on a desktop and TCP in a browser, with neither named anywhere.** The two voice
calls are declared `unreliable`, which is what voice wants: a lost frame is 20 ms of
silence a jitter buffer conceals, and a resent one arrives after the frames either side
of it have already played. What that becomes on the wire is `DotTransportAuto`'s
decision, and it has one sensible answer either way — ENet honours the unreliable
channel as UDP, and a browser has no UDP at all, so WebSocket delivers it reliably and
in order over TCP whatever anybody asks for. The platform rule falls out rather than
being written.

## Two examples, two deployment shapes

**`headless_match`** drives an `ArenaGame` directly. No socket, no netcode, no
rendering. Four bots aim at whoever is nearest and hold the trigger, which is enough to
produce kills, deaths, respawns and blocked shots. It asserts what happened *and* what
did not: nobody fell through the floor, nobody left the room, and the geometry actually
blocks shots — that last one because if the trace ignored the map, every other check
would still pass while proving nothing.

**`headless_net`** runs a server and a client in one process over a loopback that can
drop packets, and checks the netcode: the wire round-trips, a spawn is mirrored, movement
replicates, prediction moves the client on the tick it presses, and the two stay together
under loss.

**`dedicated`** boots a real `DotServer` and loads `ArenaModule`. It does not connect a
client: dot-platform runs that seam with a real `DotClientLink` over a real socket, and
`game-hungario`'s `sandbox` now runs it with a game's own RPCs on top. Repeating it here
would test dot-server rather than this game.

Two bugs the interface checks found, both of which parsed cleanly:

- `initial_focus = button.get_path()` in a screen built before it is registered. The
  node is not in the tree, so `get_path()` errors and returns nothing — and the menu
  then opens with nothing focused, which is unusable with a gamepad and invisible with
  a mouse.
- A HUD built after kills had already happened showed an empty feed. That is also
  exactly what a client joining a match in progress sees, which is why the fix is
  `ArenaHud.catch_up()` rather than a reordered test.


## Spawn protection was three mechanisms, two durations and one that had never run

The mode sets `DotMatchRules.spawn_protection_sec` — 1.5 s in a free-for-all, 2.5 s in the
horde. The effect table carried a hardcoded 2.0 s. dot-spawn's rules carried 0, and its
ledger was drained every tick by `ArenaPlayerStack.tick` and **filled by nothing**, because
`DotSpawnProtection.grant` is called inside `DotSpawnDirector.choose` and this game used
dot-match's spawn point instead.

All three read `spawn_protection_sec` now, `_on_respawn_due` asks the director (dot-match's
points are still the source — `refresh_spawns` copies them in), and
`ArenaPlayerStack.blocks_damage` is consulted from `ArenaEffects.adjust_damage`, which is
the one hook `DotDamageResolver` offers and which this game already owns.

`protection_breaks_on_attack` is **off**, and not because breaking on attack is wrong — it
is what a deathmatch wants. Only one of the three records can be revoked: `DotHealth`
counts to a tick and the effect expires on its own, and neither has a "somebody shot"
input. Revoking the ledger alone makes a player who fired stop being protected by the
resolver and stay protected by the other two, which is worse than either answer.

**`ArenaEffects.on_spawn` was called by nothing**, so `arena_protected` had never been
applied to anybody and a player who died burning respawned still burning. It is called from
the respawn now.

**The collision layout is worn rather than named.** `DotPhysicsWorld.setup` writes the
layer names into ProjectSettings for the inspector; every body here stayed on Godot's
default layer 1. The level is classified `world` — on the client, which is what draws it
and therefore what puts it in the physics space — props are classified `prop`, which is
what lets two of them collide, and `DotFpsTunables.collision_mask` comes from the layout
rather than from its default of `1`. An `ArenaPlayer` is a `Node3D` with no collider and is
deliberately **not** classified: its movement is a shape query, which is this game's model.

**The class's loadout is the arsenal's source.** `DotPlayerClassDef.loadout_id` reached
nothing and every player got the pistol-and-rifle pair written into
`ArenaPlayer.give_default_loadout`. `DotWeaponPlayerBridge.give_class_loadout` reads the
field and looks it up in `ArenaPlayerStack.LOADOUT_WEAPONS`, which is the game's table
because dot-weapon deliberately does not own the id space between a loadout and a weapon.
The hardcoded pair is the fallback for a game with no catalogue.

**Third person is deliberately not here.** game-playground runs
`DotTpsController` over a `DotPlayerControllerSwitch`; this game does not, and the reason is
the one that shapes everything else in it — the movement is analytic and lag-compensated,
and the server and its clients agree because there is exactly one motor to agree about.

## Validating changes

```bash
# The eight addon links, from this project's own .gitignore. Do not hand-make them.
godot/dot-bootstrap/bootstrap.sh --links

cd godot/game-arena
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/headless_match.tscn
godot --headless --path . res://examples/headless_presentation.tscn
godot --headless --path . res://examples/headless_net.tscn
godot --headless --path . res://examples/dedicated.tscn
```

273 + 56 + 116 + 91 checks.

**`headless_presentation` is reachable from none of the other three.** `headless_match`
plays a whole deathmatch with no client in it and `dedicated` boots a real server and never
connects one — which is exactly the shape this game has already been bitten by, when its
module looked a session up by the wrong key and **nobody could ever join a dedicated arena
server** while `dedicated.tscn` passed its twenty-one checks throughout.

**Filter `--check-only` for the lines that mean a parse failed, not against the lines
that do not.** `tools/check.sh` elsewhere in this family subtracts shutdown noise by
exact wording and went stale the moment 4.7 reworded "ObjectDB instances leaked at
exit" — a guard that cries wolf about correct files is a guard people stop reading.
Grep for `SCRIPT ERROR`, `Parse Error` and `Failed to load script` instead.

`tools/screenshot.sh <map>` renders a map from three angles into `screenshots/`
(gitignored). It needs `xvfb-run`, because it needs a real rendering context — under
`--headless` every frame it saves is empty, which is worse than no screenshot because
it looks like one. **A map is a rendered thing**: this family has shipped a 0 x 0
`Control` twice and a black screen once, and every assertion available about a map
passes just as happily for a pile of boxes in the same place.

**Re-run `--import` after adding any script with a new `class_name`.** Without it the
identifier does not resolve, the scene fails to load, and the process *hangs* rather
than exiting — nothing reaches `get_tree().quit()`. That happened while writing this
and cost two timed-out runs before the log was read.

**Run both examples after changing any dot-* addon.** That is what this project is for.

## The detector, turned on this project's own new code

The family's rule is that **an exported setting whose name occurs exactly once in its
repository is a setting nothing reads**. The same grep over *methods* is worth as much
and had never been run: a public method whose name occurs once is a method nothing
calls. Turned on the twenty-six-addon pass, it found four, and three were real:

- **`ArenaProps.phys_gun` and `grav_gun`.** dot-props' two tools were built, configured
  per player and reachable from nothing. `ArenaProps.act` is the door now, and
  `ArenaEvents.Ask.PROP_TOOL` is how a client reaches it — an *intent*, because a
  rigid body's contact solver is not reproducible across machines, so the aim is a
  claim the client makes and the origin is a fact the server already has.
  `DotPhysGun.hold` also has to be called every tick: a layer that only called `grab`
  gives a player a prop that stays exactly where it was picked up, which reads as the
  physics gun not working rather than as a missing call.
- **`ArenaAvatars.make_rig`.** dot-user-avatar built documents, `ArenaIdentity`
  resolved them, and `ArenaPlayer` drew a coloured capsule — a value produced correctly
  and consumed by nobody, at the size of a whole addon. Remote players wear their
  avatar now, and fall back to the capsule when the schema itself will not build.
- **`ArenaClientExtras.receive_line`.** The client's `DotChatClient` was a history
  nothing fed. `ArenaServices` routes a line through dot-chat and then hands it to
  dot-server's manager to put on the wire, so on the client it arrives on
  `DotClientLink.chat_received` — not on anything dot-chat owns. Empty scrollback, zero
  unread, and chat working perfectly on screen.

The fourth was the detector's own bug and is worth as much as the three: **`addons/` is
a symlink per addon and `grep -r` does not follow one**, so every override of an addon's
virtual read as dead code. A guard reporting its healthy case while blind is the shape
this family stopped reading `tools/check.sh` over; `find -L` is the fix.

## The characters are Kenney's, and scaling them was the whole job

`avatars/arena_{body,head}_kenney_<a..r>.tscn` are 18 characters from Kenney's Blocky
Characters (CC0), generated by `tools/build_avatar_parts.gd` out of `avatars/kenney/`.
The two primitives that came first stay at the FRONT of `BODIES` and `HEADS`, because
`[0]` is the schema's default: a deployment without the art directory still resolves a
default part, and so does an avatar document written before the art arrived. A capsule
is a worse character and a better fallback.

**Generated rather than authored, because the kit is one mesh set.** All 18 GLBs carry
byte-identical geometry — `leg-left`, `leg-right`, `torso`, `arm-left`, `arm-right`,
`head` — and differ only by the 1024x1024 atlas they sample. Hand-writing 36 scenes that
differ by one texture reference is 36 chances to get one wrong, and a nineteenth
character would mean noticing.

**Three things a straight import gets wrong, and all three are invisible in the file.**

- **A Kenney character is 2.70 m and this game's capsule is 1.8 m.** Imported as-is it is
  half again the size of the thing it represents, head above the camera, shoulders
  through every doorway — with every property of every node correct. The generator
  measures the kit and scales it, rather than carrying a constant that would be wrong the
  first time somebody drops in a different pack.
- **`Transform3D.scaled()` scales the origin as well as the basis.** Doing that and then
  multiplying the origin again scales the *layout* twice while scaling each mesh once:
  limbs drift apart from a body that is the right size. It measures as a part 8% too tall
  and it reads as a slightly wrong model.
- **`ArenaAvatars` mounts a slot at a point and the stock capsules are centred on it**,
  which floats a capsule invisibly and leaves a character with legs standing in mid-air.
  The head stays centred; the body is aligned so its feet land on the floor. The rig is
  not changed for this, because g2gfast mounts the same way and its parts are still
  primitives: the art fits the rig.

Every one of those was found by rendering a frame and looking at it, which is this
family's fourth or fifth time. `tools/avatar_preview.tscn` in game-g2gfast draws the
parts inside a wireframe of the hull they have to fit, because "is this the right size"
is not a question an eyeball on a character alone can answer.

**game-g2gfast has the same 18 characters and its own copy of the generator**, with its
own numbers — it is a genre-units game whose hull is 72 units, so the same kit scales by
0.508 there and 0.667 here. Duplicated rather than shared, per the family rule, and the
two files have already diverged in exactly the place that matters.

## Objectives, effects and spectating

Three addons joined this game in one pass, and each answers something it had been
missing since it was written.

### Modes that are not about killing people

`ffa`, `tdm` and `siege` are all scored on kills, which is why `DotMatch` alone had
always been enough. **`koth` and `ctf` are not**, and the difference is not a score
limit — it is a capture curve where the second player is worth half a player, a block
that pauses rather than undoes, a partial capture that decays over a minute, and a
king-of-the-hill clock that **freezes** rather than resetting when the point changes
hands. That last one is the whole tension of the mode and it is what every hand-written
version gets wrong. dot-objective has all four and this game has none of them.

**The layout comes from the map's own numbers.** `ArenaMap` is constants — an extent, a
floor height, a list of boxes — which is what lets a dedicated server that has never
drawn the level still know where everything is. So `ArenaObjectives.build` puts the
flags at the ends of the longest axis and the hill at the centre, derived rather than
authored: a map added later gets a working layout without anybody remembering to place
two more things in it. It is also why `ArenaMode.objective_layout` is an **id** rather
than a list of definitions — a mode carrying definitions would carry `dm_atrium`'s flag
positions into every map it was ever played on.

### `resolver.adjust`, which nothing had ever filled

dot-combat has offered that seam since it was written, documented as "the extension
point for a game mode's own arithmetic: a damage boost pickup, a round-start immunity, a
mode where the leader takes double". Nothing in this game had ever assigned it.
`ArenaEffects` does, and that one line is the entire integration: an attacker's crit and
a victim's resistance meet the damage at the one point every hit already goes through,
after friendly fire and falloff and before the clamp.

`ArenaEffects` owns no health value. dot-effects reports an amount and this applies it
through `DotHealth`, which is what puts an afterburn tick through the same armour, the
same rules and the same kill feed as a rifle round.

**Spawn protection is an effect rather than `DotHealth.invulnerable`**, and the reason is
one field: `no_capture`. A player standing untouchable on a control point is not a fight
anybody can have, and `DotObjectivePresence.may_capture_fn` is where that is answered.

### Where a dead player looks

Until `ArenaSpectate` existed, the camera stayed where the body fell — the corpse is on
the floor, so the view is on the floor, and the seconds before a respawn are spent
looking at a wall from ankle height. The camera is four lines; the part that matters is
that the **server** decides who may watch whom. A team mode gets `force_camera 1`, so a
dead player cannot call out the other side's positions; a free-for-all has no sides to
restrict to and gets `0`, because a restriction that means nothing is one an operator
reading the log has to work out.

The camera is driven once a **frame** rather than once a tick, for the reason this
family measured at 47% in g2gfast: a camera moved on the tick timeline steps at the tick
rate however smoothly the thing it is following is interpolated.

### Two bugs the integration found

- **A map change silently unhooked the effects layer.** `change_map` builds a *new*
  `DotCombatManager` and a new resolver, so the `adjust` hook was left on an object about
  to be freed. The layer kept running, kept expiring effects, kept reporting burn damage
  — and stopped scaling a single hit, from the first `changelevel` onwards. This
  family's most repeated shape exactly, and `ArenaEffects` now rebinds on `map_changed`
  with a check that fails without it.

- **`DotMatch` collected spawn points from the whole scene tree**, and this project had
  never noticed because it had never had two games in one process. `DotMatch.setup` calls
  `refresh_spawns`, which with no `spawns_ref` walks `get_tree().current_scene` — so a
  second `ArenaGame` in the tree contributed ten spawn points to this one's match, and
  players spawned in a map they were not in. Nothing errored: a spawn point is a spawn
  point and dot-match had been handed exactly what it asked for. `_build_match` now
  scopes the search to the game with a `DotNodeRef` in `PARENT` mode — **not** `SELF`,
  which resolves against the match node rather than the game and finds only the team
  manager.

  The same fault reaches a `changelevel` on its own: `queue_free` is deferred, so the
  outgoing map's points are still children for the rest of the frame in which the new
  match calls `refresh_spawns`.

### `arena_mode`, and the layers a mode change forgot

Adding `koth` and `ctf` was not finishing them. `ArenaGame.mode_id` is an export read
once at `setup`, so a deployment had **a game with five modes and one of them** — the two
new ones were reachable from a suite and from nothing else. `arena_mode` is the cvar, and
it goes through `change_map`, which is the only re-entrant path this game has.

Wiring it found the half that was actually missing: **`_build_world_layers` ran at setup
and never again.** Switching to `koth` produced a game whose mode said it had objectives
and whose `objectives` was null; switching to `siege` produced one with no monsters in it.
Nothing errored — a null layer is a legitimate thing for a mode with no layer to have, and
the only symptom is a mode that does not do what it says.

`_reconcile_world_layers` runs on every map change and does both directions: build what
the new mode asks for, take away what it does not. The builder is idempotent and each
layer is built **once** and then left alone, because a rebuilt layer is a layer whose
signal connections have to be remade, and a connection to a freed object is an error at
the next emit rather than at the disconnect that was skipped.

The cvar is also **put back** when a mode is refused. A cvar reading `koth` on a server
playing free-for-all is worse than one that refused, because an operator believes it — and
the put-back is guarded against its own `changed` signal, which would otherwise be a
second mode change that fails for the same reason and undoes itself.

## The chat box, and the line that was drawn as `": "`

This game could be talked to and could not talk back. `DotChatClient` held the history, the HUD drew the notice line, and there was no key anywhere that opened anything to type in. The note this replaces called that "a level of ambition rather than an oversight" on the grounds that a scrolling window with an input field is a `DotScreen` — and it is not. A screen is modal and takes the whole display; a chat box is eight lines in a corner that has to leave the game visible behind it, which is a HUD widget. It is `DotChatWindow`, in dot-ui, and `ArenaPresentation` builds it beside the console.

**And what it was drawing was blank.** `ArenaClientExtras.receive_wire` hands dot-server's payload to `DotChatClient.receive`, expecting it to refuse — the comment said "the fallback is not a failure path, it is the other deployment" — and `DotChatMessage.from_dictionary` gave every field a default, so `{kind, userid, name, text, admin}` parsed as a perfectly valid message with no text, no sender and no channel. `receive` returned ok, the fallback never ran, and **every line any player typed reached the HUD as `": "`**. Nothing errored, because nothing was wrong: the receiving code was handed a message that had parsed. dot-chat refuses a dictionary with no `m` now, and the fallback that had been unreachable since it was written is what draws chat here.

Three settings decide the box, all `ACCOUNT`-scoped because which key opens chat is about the person rather than the machine:

| | |
| --- | --- |
| `chat_window` | `auto` / `on` / `off`. `auto` hides the box on a server already carrying chat somewhere the player can see it; `on` draws it regardless, which is how a relayed server and an in-game box run at once; `off` never draws it. |
| `chat_open_key` | `Y` by default. |
| `chat_team_key` | `U` by default. |

**Off never means "you are out of the conversation".** The log keeps drawing what other people said in all three cases; what the setting decides is whether there is anywhere to type.

**`auto` is answered by the server, because only the server can answer it.** `ArenaServices` points `DotChatManager.watch_relay` at the relay it built, dot-server tells each joining client, and `ArenaClientExtras` turns that payload into `chat_relay_changed`. A client cannot work out on its own whether the room it is in also exists on a web page.

Two lines of wiring in `ArenaClient` that are not obvious:

- **`ArenaPresentation.swallows_input()` covers the box as well as the console**, for the reason the console note already gives: typing `noclip` walking the player forward is the single most reported bug in every game that ships a console and forgets it. Chat is that bug with a much wider audience.
- **`DotFpsSampler.suspended` is set on `opened` and cleared on `closed`**, and `swallows_input` is not enough on its own. Movement here is *polled* — `sample()` reads the device every physics frame and does not care what consumed an event — so without it, typing "sw" walks you backwards off whatever you were standing on. The field is documented in dot-player-controller as "for a chat box or a menu" and nothing in this game had ever set it.

## The website chat relay

`ArenaServices` builds a `DotChatRelay` when `relay_config.enabled` is set, joining this
server's chat to its room on the website. Every seam it uses already existed:

- the backbone client is `ArenaIdentity`'s, which is why the module assigns
  `services.backbone` **before** `setup` — a client handed over afterwards is one the
  relay has already decided it does not have, the ordering that left dot-server's audit
  log unopened in every default configuration;
- the permission answer is `DotAdminManager.uid_has_permission`, the method written for
  exactly this question — what somebody may do when they are not connected;
- the command runner is `DotServer.run_command_as_uid`, which builds a context the way
  RCON does but with **that uid's own flags** rather than root.

**Relayed commands are off by default and audited either way.** A line typed on a web
page by somebody who is not in the game is a privilege path, and `Source.CHAT` — which
dot-server documents as the least trusted — is the right classification for it. The
refusals are the half worth recording: they are somebody trying to drive the server from
the website without the rights to.

## The chat commands that did nothing

`ArenaServices` hooks `player_command` as well as `player_chat`, and without it **none of
this game's own chat commands existed.**

dot-server's chat manager checks for a command prefix *before* it fires `player_chat`,
and `_handle_command` returns on every path — including the unknown-command one, which is
silently ignored rather than answered. Its `chat_command_prefixes` are `["!", "/"]`,
identical to `DotChatRules`'. So a `!` line never reached `DotChatRouter`, and
`command_entered` — which `_build_chat` connects and `ArenaModule._on_chat_command`
switches on — **could not fire.**

`!nominate`, `!timeleft`, `!score` and `!stats` have no console equivalent and did nothing
at all. `!rtv` and `!vote` looked like they worked because dot-server has commands of
those names of its own, which is what hid the rest: **a dead handler behind a name
something else answers is the hardest kind to find.**

`player_command` is fired before the console lookup and is cancellable, so the game gets
first refusal and claims what it knows; anything it does not claim carries on to the
console exactly as before, which is what keeps `!kick` working.

**The map commands stay console-only.** A map change ends every round in progress, and
g2gfast's suite asserts the same thing for the same reason. A command relayed from the
website arrives as `Source.CHAT` and is refused here too;
`DotChatRelayConfig.command_source` is the operator's switch.

## What the first live map change found

`arena_map dm_atrium` over RCON on a running demo server, which is the first time a hot
changelevel here has been driven by anything other than a suite. It worked — the map
swapped, the match rebuilt into warmup, the audit log recorded it — and it turned up two
things that had been true the whole time:

- **`arena_maps` said "No hot changelevel yet."** It has been wrong since
  `ArenaGame.change_map` was written, and it sits four lines from `arena_map`, which does
  exactly that. An operator reading the command's own output would have restarted the
  server rather than used the command beside it.
- **The client rebuilt the map it was already showing.** `ArenaClient._on_map_changed`
  is handed the new `DotMapDef` and read `game.map` instead — and `ArenaGame.map` is
  assigned in exactly three places, every one of them on the **server**. A mirroring
  client never calls `change_map`; `DotMapSyncClient` telling it is the only notice it
  gets. So the client tore down its level and rebuilt the same one, leaving the player
  standing in geometry the server no longer had, with its collision somewhere else.

  **It reads as the client freezing**, because every move is refused by a wall nobody can
  see. Nothing errored at either end: the server was right, the protocol completed, and
  `map.sync all peers have the map` was logged — the client really had loaded it, it just
  drew the wrong one. Found by a person standing in it on a live server, which is the only
  place it could have been found: `headless_net` has no renderer, so there is no level for
  a client to rebuild and nothing to be wrong about.

- **`no spawn points found` on every boot and every map change.** `DotMatch.setup` calls
  `refresh_spawns` during `add_child(match_node)`, and this game — like every code-built
  map in the family — adds its points with `add_spawn_point` on the *next lines*. So the
  warning is about a condition corrected microseconds later, and it is indistinguishable
  from the real fault it exists for. `refresh_spawns` takes `announce_empty` now and
  `setup` passes false.

## The presentation layer, and the gap this project was the sharpest case of

`ArenaPresentation` holds dot-settings, dot-audio, dot-fx and dot-console on the client.
**This was the game where the missing audio was most obviously wrong**: a camera rig,
input sampling, a renderer, a HUD and menus, and firing produced no sound and drew nothing
for the gun in your own hands — the only feedback was the crosshair and the ammunition
counter.

What was missing was never the files. It was the decision about **what is audible, how
many at once, how loud, and how far away it stops mattering**, which is a document:

- Every weapon sound is positional with a real cull distance, because **a shot you cannot
  place is a shot you cannot answer** — the one thing audio contributes here that the HUD
  cannot. A hit marker is flat, because it is information about your *own* shot and would
  otherwise get quieter the further away you hit somebody.
- `max_concurrent` is 3 on a rifle. Twelve in one tick is not twelve gunshots; it is one,
  twelve times as loud, with comb filtering.
- The shot is predicted on the client that fired it. Waiting for the server's confirmation
  would put the bang a round trip after the click, and it is safe for exactly the reason
  dot-fx is built the way it is: **a sound never changes the simulation**, so a shot the
  server later refuses cost a noise.

**dot-effects and dot-fx are not the same thing and this game has both.** `ArenaEffects` is
burning, slows, invulnerability and being down — things that happen over time to an entity
and change the simulation. `ArenaPresentation` is what any of that *looks* like, and an
effect there never changes the simulation, which is what lets a frame budget drop one.

### The camera is written in exactly one place

`ArenaPlayer.present` already said so in its own comment, so the shake is handed to the
player as `camera_offset` / `camera_roll` rather than written onto the camera by whoever
computed it. dot-fx computes a displacement and touches no camera — dot-spectate's rule —
and one implementation then serves the play rig, a spectator's and a headless suite.

`attach_camera` is idempotent and now re-applies the field of view when called again,
because a player who moves that slider and sees nothing happen has a setting that is stored
and read by nobody.

### `field_of_view` is why `SERVER_CLAMPED` exists

A wide field of view is a competitive advantage, so a server capping it is a legitimate
rule. A server *reading* it — or the sensitivity, or the bindings, or the audio device —
would be assembling a fingerprint that survives a new account and every ban a moderator
issues. So there is no read direction at all, and a clamp is a **bound**: a player who
prefers 90 keeps 90 under a cap of 100, and what is saved is their choice rather than the
cap.

## A private match files nothing

`ArenaParty` is dot-peer-to-peer at `Trust.SANDBOXED`, and that is the decision this game
makes that the lobby does not. This one reports to dot-stats, unlocks dot-achievements and
files to dot-leaderboard; a peer-to-peer host is a player's own machine and can lie about
all of it. **A host who can cheat and a leaderboard are not two features. They are one
exploit**, and the only honest answers are a dedicated server or a sandbox.

`reporting_allowed()` is asked in one place rather than by four reporters, because the one
that is forgotten is the one that files a peer-to-peer host's score to a real board.

**Migration is off**, where the lobby's and hungario's are on. A round-based deathmatch's
host holds the match clock, the score and every hitbox, and handing that over mid-round
produces a round nobody can agree about. A private match whose host left has ended, and
saying so is better than continuing wrongly.

## "Settings" opened the interface's settings

`DotUiConfig` is the scale, the safe area, the transition time and how many chat lines the HUD keeps. All of those are real settings and **not one of them is what a player means by the word** — the volume, the field of view and the sensitivity are in `ArenaPresentation.settings`, a `DotSettingsManager`. So a player who opened the pause menu to turn the game down found a slider for the interface scale.

`settings` is the player's document now, on dot-ui's shared `DotSettingsScreen`; the old screen is `interface` and has its own button — **also `DotSettingsScreen`, which is what `id_override` and `title_text` exist for.** This client is the only one in the family with two settings screens in one stack, and it is the case that made those settings configurable at all; carrying a hand-written copy for the second of them was the duplication dot-ui had already been written to end. This file listed "A settings screen" under *things deliberately not here* on the grounds that `to_config()` made one a single `DotSettingsPanel` away — which was true, and the half that was missing is the way back: `to_config()` hands out a **snapshot**, so a screen that called only the panel's apply would report success and change nothing. `absorb_config()` is the second step and had no caller anywhere in the family.

**With no manager the button is greyed out** rather than opening nothing, which is what `headless_match` drives: that fixture builds the menus without a presentation layer, and asserting the disabled button is what stops the missing case from silently becoming an empty screen.

## The pause menu is dot-ui's now, and two of its buttons went nowhere

dot-ui grew `DotPauseScreen` because four clients here had written the same forty lines — a centred `PanelContainer`, a heading, a column of `Button`s, a focus path — and differed only in the words on the buttons. **Three of the four never moved onto it, and this was one of them.** What is this game's own is `ArenaMenus.PAUSE_BUTTONS` and what happens when one is pressed; the ids are derived from the labels, because a list of labels and a parallel list of ids is two lists that can disagree.

Doing that made two things visible that had been true since the client was written, both of them this family's own "a value produced correctly and consumed by nothing":

- **Leave was wired to nothing.** `ArenaClient` ended `_build_menus` with `var _unused := pause` — the button was drawn, pressed, and answered by nobody. It emits `leave_requested` now, announced rather than acted on for the lobby's reason: what leaving means belongs to whatever loaded this client, and a client that called `get_tree().quit()` itself would be one that cannot be embedded in anything.
- **Nothing could open the server browser.** `ArenaBrowser.BrowserScreen` registers under `&"servers"` and **no `push(&"servers")` existed anywhere in this repository** — a whole server list, with sources, a filter, favourites and a join, built on every launch and unreachable. There is a Servers button now.

**The Servers button is greyed until there is a browser, and that needs a second pass.** The browser is built *after* the menus and only when its list came up, so `install` cannot know; `ArenaMenus.note_screens` re-checks every button against the stack and the client calls it once the screen is registered. Greyed rather than removed, because a button that is absent on one build and present on another is a menu whose shape a player cannot learn, while one that is there and dimmed says this client does not have that thing.

## The menus, rendered and looked at

`tools/screenshot_menus.sh` renders the pause menu, the **interface** screen, the rebinder, the scoreboard and the HUD with the chat box over it. The interface screen was not in that list and is the one that most needed to be: it is generated from a document rather than laid out, so the only thing that can be wrong with it is its *shape* — and `DotUiConfig` is eleven rows across four groups, the longest document any screen in this family binds. dot-ui's own screenshot found exactly that case, a panel growing past the bottom of the window and taking Apply, Revert and Back with it, with every property correct throughout. That last frame is about where the two are relative to *each other*: the box goes in the bottom-left corner by default and so do health and armour, so it is placed at `margin_bottom = 110` to clear them, and the only thing that can tell you whether 110 is the right number is the picture. It is separate from `screenshot.sh`, which renders maps: a map wants a camera framing a world and a menu wants a viewport-sized stack with nothing behind it, and one script doing both would spend itself deciding which it was doing.

It found three things on its first run, none of which any assertion here could reach:

- **The rebinder listed nothing, and always had.** `DotBindingsPanel.prefix` filters the `InputMap`, `ArenaMenus` set it to `"arena_"`, and **there has never been an `arena_` action**. The bindable actions here are the movement ones, registered by `DotFpsSampler.register_default_actions` and therefore named `dot_fps_forward` and so on; fire, reload and the scoreboard are matched on a keycode in `_unhandled_input` and are not actions at all. A Controls menu with a title, a Defaults button, a Back button and no controls — and nothing errored, because a filter that matches nothing is a legitimate filter.
- **The scoreboard drew one column.** Kills, deaths, assists, score and ping were all zero-width. That one is dot-ui's, in `DotTableView`, and it applied to every scoreboard and every server browser in the family.
- **The rebinder's rows were in interned-pointer order.** Also dot-ui's, and the same trap that gave two peers two different wire ids in dot-net.

**The tool refuses to save a grey rectangle.** If `push` fails it says so and skips the shot, because a picture of an empty viewport is indistinguishable from a renderer that is not working — which is exactly how dot-ui's blank pause menu looked before the cause was found.

## `dm_pit`, and the filter that had never said no

The third map is small (28 m against `dm_box`'s 48 and `dm_atrium`'s 60), built around a
sunken floor with a catwalk ring at 3.6 m and a bridge across the middle, and it is
reached three ways that are deliberately unequal: two stairs of ten 0.36 treads, and a
pair of crates that is two jumps and a hop.

**Every spawn on it is untagged, and that is the point rather than an oversight.**
`ArenaMaps.supports_mode` answers no for a team mode on it, and it is the first map here
that can. `dm_box` and `dm_atrium` both tag their spawns, so the three places that ask
the question — the ballot, the mode half of the ballot, and the refusal in
`ArenaMapSession` — had only ever been told yes. A filter with nothing to filter is a
filter nobody has run, and adding the first map that answers no found two things:

- **The refusal read the wrong mode.** `ArenaMapSession` checked `_mode_for(map)`, which
  is only ever non-null when the map def *names* a mode in its meta — and no map in this
  game does. So the guard was covering a case that never arose while the case that does
  arise walked past it: a free-for-all-only map could be loaded into a running team game,
  both sides drawing from one pool, which is the symptom that comment warns about.
  `_mode_after` is the question worth asking — the map's own mode if it names one, and
  otherwise the one already being played.
- **The rotation had no idea modes existed.** Correctly: dot-map filters on player count
  and cooldown, and "what a mode needs from a map" is a game's question. But nothing on
  this side was answering it either, so the rotation could have handed a team game a map
  that then refused to load. `ArenaMapDirector.restrict_rotation` narrows
  `DotMapRotation.order` to what the current mode can host, before every ask rather than
  once at setup, because the mode changes under a running server. It never empties the
  order: a mode no map can host is a configuration mistake, and "the map did not change"
  says so where an empty rotation is a server that sits still and never explains why.

## The south arcade, and the map that only had one answer to its own roof

`dm_atrium` is built around three ways UP and, until the arcade, had nothing to say
about being DOWN. The ring overhangs, sees the whole yard, and the south-west bunker was
the only square of ground it cannot see — a corner to hide in with nowhere to go from
it. The arcade is the missing half: 25 m of roofed ground running east from a doorway
cut in that bunker's east wall to the foot of the south-east crates, so the route from
the map's safest corner to its fastest way up is under cover for all of it.

**A colonnade rather than a tunnel, and that is the whole balance of it.** The piers
stand at the two long edges only, so the arcade is opaque from above and open from the
sides: it beats the ring and it does not beat a player standing in the yard beside it. A
solid box there would have been a safe corridor across the middle of the map, which is a
worse map than no corridor at all. Its roof is the second thing it is for — top face
3.6, deliberately 0.4 **under** the ring, so whoever holds the ring still holds the map
and now has somewhere to be shot at from. Reached by a ten-tread stair at the back of
the yard, or by stepping across from the crates.

**No spawn was added, and that is a decision rather than an omission.** This map's
spawns are tagged by the sign of z and are deliberately five red to five blue; the
arcade is entirely in the south, so every spawn it could carry would be a blue one. A
map whose two sides start six against five to describe a corridor is a worse trade than
a corridor you walk to, and both the bunker and the crates already have a spawn near
them.

**Versions are per map now.** `ArenaMaps.MAP_VERSION` was one constant for the whole
catalogue and its own comment said "bumped per map when its geometry changes" — which it
could not do. A record and a rotation cooldown are both about a map *at* a version, so
bumping one shared constant for the arcade would have declared `dm_box` and `dm_pit` to
be new maps as well, invalidating two sets of records to describe a change neither map
had. `MAP_VERSIONS` is the per-map override and `dm_atrium` is at `1.1.0`; a map absent
from it is at `MAP_VERSION`, which is the common case.

## What a bot in here actually travels at

**9.00 m/s holding forward. 1.20 m/s holding forward and jump.** Measured on this map's
open yard, printed by `headless_match` under *what a bot actually travels at*, and it is
a factor of seven and a half that nothing in this family had ever put a number on.

The mechanism is not a bug and must not be "fixed". With `auto_hop` on and jump **held**,
the player leaves the ground on the tick it lands, so `accelerate` never gets a grounded
tick to work in; and air acceleration cannot make up the difference because
`max_air_wish_speed` is 1.2 — which is exactly the cap that makes air-strafing a skill,
and is what `arena_tunables()` already documents as the classic formula. A bot holding
one direction cannot strafe, so it bleeds to the cap. 1.20 m/s is the cap, to the
centimetre.

What is wrong is only ever the **assertion** written on top of it. A check of the form
"the bot hopped" passes for a bot crawling at a metre a second, and a map check that
assumes a bot covers ground is weaker than it reads. **So the rule for this project is
that an arena bot that has to cover ground does not hold jump** — every map check here
drives a walking bot, and that measurement is what says why. The number is printed
rather than only asserted, because a check's detail line is shown only when it fails and
an assertion alone would hide the measurement again the moment it started passing.


## Things deliberately not here

- **Projectiles.** The rocket launcher is declared as `Delivery.PROJECTILE` and
  dot-combat records the launch vector without spawning anything. A projectile is a
  replicated entity with a lifetime; the bridge now exists to give it one.
- **Pickups in the world.** dot-loadout ships `DotPickup` and `DotPickupField`; the map
  places none. An arena with weapon and armour pickups is most of what makes map
  control matter, and it is a level-design decision rather than a wiring one.
- **Any actual audio files, and a viewmodel.** dot-audio is wired, the catalogue is
  written and every id resolves to a path in `audio/` that does not exist yet — which is
  the right way round, because what this game was missing was the decision rather than the
  files. Dropping eight `.ogg`s in changes nothing else. Nothing is still drawn for the
  weapon in your own hands.
- **Bots worth the name.** `_commands_for_tick` aims at the nearest opponent and holds
  the trigger. It is a test fixture, not an opponent.
- **A master server.** `DotBrowserSourceBackbone` reads a listing that nothing is yet
  publishing, and there is no heartbeat — so the browser finds what somebody typed
  into it and nothing else. That gap is the family's rather than this game's.
- **Joining from the browser.** `ArenaBrowser.BrowserScreen` lists servers, favourites
  them and reports which one was picked; connecting means tearing down this client's
  netcode, opening a transport at a new address and going through signon again, which
  is a launcher's job — and this game is loaded *by* one.
