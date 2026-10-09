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
the fight        dot-player-controller  dot-combat  dot-weapon  dot-loadout  dot-match
                 zee-dot-weapons (the weapons, and everything about them anybody sees)
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
| loadout → combat | `ArenaPlayer.give_loadout`, item ids that are the pack's weapon ids |
| weapons → player | `ArenaPlayer._build_rig`, a `ZeeWeaponRig` handed the player's own arsenal by `arsenal_ref` |
| weapons → wire | `ArenaPlayerNet`: `ZeeWeaponNet.all_specs()`, `net_weapon` for everybody, `net_carry` for the owner |
| projectiles → clients | `ArenaProjectiles.launched` → `ArenaEvents.Kind.LAUNCH` → a copy flown by `client_tick` |
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
| match → vote | `ArenaVote.leading_score` polled each tick into `note_score`; dot-match's `round_ended` → `note_round_end` |
| vote → clients | `ArenaVote.cue_due` → `ArenaEvents.Kind.VOTE` → `ArenaPresentation.on_vote_cue` and the HUD's notice line |
| vote → console | `ArenaVote.install_commands`, dot-vote's `DotVoteCommands` on the module |
| npc → combat | `ArenaHorde._register_combat`, hitboxes and health under one entity id |
| npc → game | the brain reaches `ArenaHorde` through `DotRegistry`, never by name |
| chat → server | `ArenaServices._on_player_chat`, which **cancels** dot-server's own |
| voice → wire | `ArenaNetLink.send_voice`, on a channel of its own |
| moderation → everything | two registry names nobody imports: `dot_mute_source`, `dot_ban_source` |
| moderation → the world | `ArenaModTools.handlers`, one callable per admin ability; `DotModToolCommands` on the module for the commands |

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

**An imported combat surf map is the one exception, and it keeps the rule.** It has no box list, so `ArenaMap.movement_body()` hands every player a `DotFpsPhysicsBody` bound to the map's brushes, which `ArenaGame` puts in the tree on the server and on every client alike. Both ends then query the same convex hulls through the same solver, which is the condition the rule is about; the body is still a shape query from a plain `Node3D`, not `Mode.PHYSICS`. See the section on the combat surf maps.

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

**The extent is 512 since the combat surf maps**, which reach 312 m from the origin; at 128 every position on the far half of one was clamped to the quantiser's edge (`headless_net`'s imported-map check, armed: the client pinned at x = 128.0, 66 m from the server). Moving it moved the quantisation step and exposed the flat body's depenetration fault (fixed in dot-player-controller v0.1.5, below).

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
- **Their positions do not.** A position is a place in a room, and the room was replaced. Until 2026-09-27 a change kept everybody where they stood, so a player whose spot was a box on the next map was inside it and the flat body pushed him down through the floor (found building `dm_atrium`'s keep). `_respawn_for_new_map` now puts every present, non-spectating player through `_on_respawn_due` after `map_changed` — the round start's path, so the director, team sides, spawn protection and loadouts all apply — on the authority only; a client follows through the predictor's rewind. `headless_match` builds a box on the spot a player is standing and asserts nobody is inside a box, everybody is at a spawn, and each side is at its own; `headless_net` asserts the client's predicted player follows.
- **The director did not know about sides until then.** `ArenaPlayerStack.refresh_spawns` copied dot-match's points into dot-spawn sites without their team tag, and the roster kept the previous mode's sides across a change, so once the director was choosing, a team mode spawned both sides out of one pool again. Sites carry the side of the match team whose `spawn_tag` claims them, and `_adopt_match_sides` re-reads dot-match's assignment on every map change.
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
godot --headless --path . res://examples/headless_lossy.tscn
godot --headless --path . res://examples/dedicated.tscn
godot --headless --path . res://examples/headless_admin.tscn
godot --headless --path . res://examples/headless_imported.tscn
```

`headless_match` 502 checks over 32 sections, `headless_net` 192 over 17 (183 without g2gfast-maps linked), `headless_lossy` 62 over six (about 50 seconds: it plays in real time), `headless_presentation` 135, `dedicated` 114, `headless_stack` 60 over six sections, `headless_admin` 46 over ten, and `headless_imported` 56 over eleven (it skips, and says so, without the link).

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

`tools/screenshot.sh <map> [--admin] [--view <name> <x,y,z> <x,y,z>]... [--fx <eye> <aim at>]` renders a map from three angles (and one more per `--view`; `--fx` instead renders six rifle shots from `<eye>` at a wall, through the eye, beside the wall, and a death) into `screenshots/`
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

**Until 2026-09-25 none of that reached a networked client.** The spectate layer was built in `_build_world_layers`, which returns on a non-authority, so a client had no layer; and had it had one, it was fed by `player_killed` (only the authority emits it — dot-combat resolves no death on a mirror) and ticked by `game.tick` (a networked client never calls it — the bridge simulates the predicted player itself). Every check about the death camera ran on an authoritative game, where the same code is fed and ticked, so a dead player in a browser looked at the floor for the whole of every death while `headless_match` passed. A client now builds the layer (`_build_spectate`), the bridge feeds it the KILL event (`ArenaSpectate.on_kill_event`) and ticks it (`client_tick`), and a respawn is read off the replicated health: a viewer seen dead and alive again is playing. The client's manager is **authoritative over its own camera**: this server sends no spectator views, and a dot-spectate mirror runs no timers, so a mirror here would hold the death camera until the respawn (and dot-spectate now refuses `on_death` on one, loudly). `headless_net`'s "the death camera on a client" is the check, and it fails without the fix (four of its six checks, then an abort).

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

### The effect scenes, which did not exist until 2026-09-27

`fx_catalogue()` named `muzzle_flash`, `impact_spark`, `bullet_hole` and `death_burst` under `scenes/fx/` from the day it was written, and **the directory did not exist**. dot-fx refuses a scene it cannot find and says so at DEBUG, because a client whose pack is still arriving legitimately asks for scenes it does not have — so every flash, spark, hole and gib in this game was refused, silently, while `headless_presentation` asserted that the catalogue validates (it does, with no scenes, by design) and that the gib at tier 3 was refused *for the missing file*, which had made a check out of the bug. Found from mg-buses-from-hell's barrel (e60edff), the first game in the family that shipped its effect scenes.

The four are plain scenes with no script and no external resource, so a delivered pack has no path inside them to rewrite: `CPUParticles3D` for the flash, the spark and the gibs (CPU rather than GPU so the headless and Dummy renderers run them like anything else), a small `OmniLight3D` on the flash, and a `Decal` with a generated radial texture for the hole. **Every one is built against one frame, `ArenaPresentation.facing(at, direction)`: -Z along the shot.** The flash sprays along it, the spark flies back up it, and the hole's decal is turned so it projects along it — which is what lets a hole land on a wall, a floor or a ceiling with only the point the shot stopped at, since a `DotShot` carries no surface normal. The client used to hand the presentation an identity basis, so a decal would only ever have projected downward. `ArenaPresentation.on_used(outcome)` is that loop now, moved out of `ArenaClient._on_local_used` so the suite drives the exact path; the flash is placed half a metre along the aim and a little below and right (`MUZZLE_OFFSET`), because a shot starts at the eye and a flash drawn there is drawn round the camera. `_build_fx` warns when a scene is missing, the way buses' `BfhFx.setup` does.

`headless_presentation`'s *a shot is drawn* asserts `missing_scenes()` is empty, that `on_used` puts a flash in front of and below the eye, a spark and a hole at the impact, that the hole's decal projects along the shot (and straight up onto a ceiling), and that a death bursts. Armed: a scene removed (four checks), the decal's turn removed (two), the muzzle offset removed (one). Rendered with `tools/screenshot.sh dm_box --fx 18,1.7,11 30,1.4,11.6` and looked at, which is what changed the flash from six additive white squares to a soft round glow (untextured particle quads are squares) and the sparks from white to orange.

**A one-shot shorter than a frame is not drawn.** `CPUParticles3D` ages a one-shot by the whole delta of its first frame, so the 80 ms flash is gone before it is drawn on a frame longer than that. Safe by dot-fx's rule and irrelevant at 60 fps; it is why `--fx` slows the particles to a twentieth and restarts them, because a software renderer under xvfb is well past 80 ms a frame.

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

## Four things the first rendered offline frame showed

A frame of `tools/screenshot.sh game-arena out.png --wait 35 -- --offline`, looked at, and every suite green throughout:

- **The round clock and the leader line started at the middle of the screen instead of being centred on it.** A centre-top preset is a zero-width box, and a `Label` wider than its box grows by `grow_horizontal`, which defaults to END. `ArenaHud._make_label` grows both ways now.
- **A pale slab across the bottom of every offline frame was the local player's own nose.** `add_player` emits `player_added` synchronously and `_on_player_added` gives everybody it does not recognise a body; offline, `_watch_id` was still -1, so that included the player the camera sits in. `_start_offline` names the player before creating it, which is the order HELLO and JOIN already give a networked client.
- **The crosshair measured spread through a hardcoded 75 degree lens.** The camera is the player's `field_of_view`, horizontal at 4:3, which is 83.6 vertical at the default of 100 — so every gap was 17% wider than the cone the shots leave in, and 69% at 120. `ArenaHud.match_view` reads the camera's own `fov` once a frame, because the camera is the one place a slider, a server clamp and the first `attach_camera` all end.
- **`sensitivity`, `invert_pitch` and `crosshair` were on the Settings screen and read by nothing.** The view turned at `DotFpsTunables`' default whatever the slider said. `ArenaPresentation.bind_look` and `bind_crosshair` push them — at bind time as well as on `changed`, because a value loaded from disk has not changed — and the client binds again when it hands the sampler its player's tunables, which is a new object carrying the default. Sensitivity converts at 0.022 degrees per count, the same as game-g2gfast, because it is an `ACCOUNT` setting in the shared namespace and one number has to mean one turning speed. `circle` draws the cross: `DotCrosshair` has no ring.

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

**It meets over a real HTTP rendezvous in a check, awaited end to end (`[p2p-await-games]`).** The sandboxed check uses the loopback signaller, which answers inside the call, so a caller that forgot `await` would pass against it. `headless_presentation`'s **a private match that meets over HTTP** (ported from game-playground's d4ff040, on ports 38800-38860 so the two suites can run together) stands up `RendezvousStub`, a four-route rendezvous on a local TCP port answering four frames after each request, hosts with one `ArenaParty` and joins with another through `DotP2PSession` and `DotP2PSignallerHttp`, and asserts each answer is the one the stub sent and arrived only after it answered, that the rendezvous was told the host's code and name, that the joiner learns who is there and does not elect itself, that a 403 leaves the party closed with a reason, and (arena's own addition) that a match hosted this way still files nothing. Trust and migration change nothing on the signalling path, so every playground assertion applies here as written. Armed by answering every join with an empty peer list (one check fired) and by refusing everything with a 500 (seven fired).

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

## `dm_pit` gained a crossing and a third tier

**Extended 2026-09-18.** A second bridge east to west turns the ring's one chord into a
crossing: with a single bridge the high ground is one decision wide and the middle of
the map is a place you pass through, and with two it is a junction four ways lead to,
with the island underneath as the only square on it out of everybody's sight.

And a **shelf** in the south-west corner carrying a **perch** at 5.4 — the map's third
tier, two 0.9 m hops up from the ring, which is under the 1.25 m `arena_tunables()`
jumps. The perch sees the whole pit and every metre of the ring sees the perch, which
is the trade. Nine spawns now, one of them on the shelf, and **still not one of them
tagged** — the property this map exists for has to survive anything added to it or it is
not a property.

**The one number in it that is load-bearing is not a height.** The shelf is flush with
the inner edges of the west and south arms, at x = -11 and z = 11. Set half a metre
clear of them instead — which looks tidier written down — it leaves a 0.5 m slot between
the block and the catwalk, and 0.5 m is narrower than the 0.8 m a player is. That is a
gap nothing that plays this map can pass, it looks from above exactly like a corridor,
and it is `[gate-sweep-1]`'s second question: not "can the player get through every
gap" but "is there anywhere here the player cannot reach at all". `headless_match`
measures both offsets off the map's own boxes rather than trusting the constants.

The east-west gantry is driven by a bot **separately** from the north-south one rather
than assumed from it: they are different boxes meeting different arms of the ring, and
this family's whole `[gate-sweep-1]` file is times a shape was checked in one instance
and believed about the others.

## `dm_pit` gained a lookout, so the perch has somebody to look at

**Extended 2026-09-26 (dm_pit 1.4.0).** The perch saw the whole pit and nothing on the map could look back at it from above the ring, so whoever held it held the map. **The lookout** is a 1.5 x 2 m block at 4.5 on the east arm, against the east wall, one 0.9 m hop off the ring. The perch is still the higher of the two, but it is now one of two places that watch each other, and the ring between them is in both sightlines. One high point is a throne; two are a duel.

It stands against the wall so the arm keeps 1.5 m of walkway, nearly twice the 0.8 m a player is: the ring is a loop, and a lookout that closed it would make it two dead ends. It sits between the east-west bridge (z -1..1) and the south-east stair's landing (z 7.5..10.5), so neither arrival lands on it. No spawn was added.

`headless_match` has a bot on the east arm hold east and jump until it is grounded on the lookout (armed: without the box it ends at 3.73 m), and traces eye to eye from the lookout to the perch against every box. The survey still reports 0 closed slots, everything reached, and 0 trapped. Rendered: `tools/screenshot.sh dm_pit`, roof view.

## `dm_atrium` gained a keep, so red's half has somewhere the ring cannot see

**Extended 2026-09-27 (dm_atrium 1.4.0).** Spawns on this map are tagged by the sign of z, and every piece of ground cover the ring cannot see — the bunker, the arcade — was in the south, blue's half. Red started in a 60 x 20 m north yard with the ring on one side and the perch on the other and nothing to stand behind. **The keep** is a 6.5 x 12 m block in the north-west (x -18.5..-12, z -18..-6): a roofed 4.5 x 10 m room inside it with a 2.5 x 3 m doorway at each end, north to the yard and south to a lane at the foot of the north-west stair, and a roof at 5.5 on top, 0.9 over the ring. It is not the arcade again: a closed room rather than a colonnade, and a roof that is a high point rather than a tier under the ring.

**The two 2 m gaps are the load-bearing numbers.** The alley between the keep and the building and the lane between the keep and the stair are both 2 m: a walkable passage from below, and from the ring's north arm one 0.9 m-up jump west onto the roof (declared as a climb, 2.0 m against 4.64 m of reach). Flush with the building, the roof would be a step off the ring and part of it; under 0.8 either gap is a slot. Nothing on the ground climbs the roof.

**The west wall has a firing slit, because the first render showed a block.** Solid, the default eye frame was a blank 12 m wall. The slit is 4 m long, sill at 1.2 (over the 1.125 climb limit, so nobody vaults through it) and 0.8 of opening (under the 0.9 a crouching player needs, so the sill is not a shelf). At 1.0 of opening the survey finds 3 m² of sill it can reach, which is why the number is what it is. No spawn was added: five red and five blue is what this map ships.

`headless_match`'s *dm_atrium* section asserts the room is roofed and the ring cannot see into it, the roof is open sky, the slit is open at eye height and wall at the knee and over the head, a bot walks in at the north door and out at the south at running speed (printed: 18.6 of the 18.6 m route, 9.04 m/s door to door against 9.00), and a bot runs the ring's north arm and jumps the alley onto the roof (printed: took off at 9.00 m/s). Armed: the alley widened to 5 m (the roof drive, the climb sweep and the survey all fail), the south doorway blocked, the bot at 0.6 of forward (in-and-out passes, speed fails at 5.41 m/s), the roof removed, the slit closed. Survey: 3578 m² standable, 0 unreached, 0 trapped, 0 closed slots. Rendered with `tools/screenshot.sh dm_atrium --view <name> <from> <at>`, which is new: one extra frame per `--view`, because the three fixed frames are for comparing nights and a new piece of a map is usually somewhere none of them points.

## `dm_box` gained two nest stairs, a walked way onto the upper loop

**Extended 2026-09-29 (dm_box 1.3.0).** Every way onto the upper loop was a chain of four jumps up a crate stack, and both stacks stand at the x walls, so the loop could only be joined at its ends and never from the middle of the room. **The nest stairs** are ten treads of 0.36 (under the 0.4 `step_height`, so held forward climbs them; the number is dm_atrium's and dm_pit's) and 0.9 deep, 3 m wide, running along each gantry's outer face (north: x -6.5..2.5, z -13.5..-10.5) and climbing toward the nest pillar. The top tread is at 3.6, level with the gantry beside it, and 0.9 under the nest step. The south stair is the north one's half-turn, computed from the boxes, so the map is still its own half-turn about the origin. No spawn was added or moved.

**Ending against the pillar is the load-bearing decision.** A stair beside a gantry that ends anywhere else ends in air, and a player running up it at 9 m/s leaves the top tread before turning onto the walkway. Armed with the stair 2.5 m short of the pillar, the bot runs off the end and lands on the floor. Flush means the run stops at a wall and the gantry is one sidestep away. It is also the trade: the stair climbs straight at the nest, so whoever holds the nest looks down all 9 m of it, and the quickest way to the third tier is the most watched one. Stopped 0.5 m short instead, it leaves a 0.5 m slot between the tread and the pillar, which the survey reports as two closed slots.

`headless_match`'s *dm_box: the upper level, climbed* walks a bot up each stair separately without pressing jump (printed: 7.9 m of stair in 0.86 s, 9.14 m/s against 9.00, both stairs), asserts that pace is within 1.5 of `max_speed`, that half a second more of running leaves it standing on the top tread against the pillar, that it then steps onto the gantry, and that a chest-height line from the nest's eye reaches every tread. Armed four ways: south stair removed (the half-turn check and the south drive fail), a 1 m parapet on the nest edge (the sightline fails on all ten treads), bot at 0.6 of forward (pace fails at 5.45 m/s), and the stair 0.5 m and then 2.5 m short of the pillar (two closed slots; the run-off). Survey: dm_box 2680 m² standable, 18 unreached (the two declared pillar tops), 0 trapped, 0 closed slots. Rendered: `tools/screenshot.sh dm_box --view nest_stair -13,2.2,-19 1,3,-11 --view stair_from_nest 4,6.6,-12 -6,1,-12`.

## `dm_pit` gained a shelf stair, so the pit floor has its own way to the perch

**Extended 2026-09-30 (dm_pit 1.5.0).** The third tier could only be reached from the second: a player on the pit floor who wanted the perch went up onto the ring, round to the west arm and hopped, so the fight for the map's best view was between people already on the ring. **The shelf stair** runs from the south-east stair's foot at x = 2 west up the shelf's east face in the same lane (z 7.5..10.5): one tread at 0.72, a landing at 1.08, and nine treads 0.58 deep from 1.44 to 4.32, 0.18 under the shelf. Every rise is the 0.36 a bot walks, so the two stairs make one valley — down off the east arm, through a dip at 0.36, up onto the shelf, held in one direction — and the perch is one hop from the top. The spawn that stood at (0, 8.5) in the lane is at (0, 5.5); still nine, still none tagged.

**The north-south bridge crossing the lane is the load-bearing number.** Its underside is at 3.0, so anything a player stands on while any part of the hull is under it can be no higher than 1.2. Twelve even treads walked into the bridge's side at 1.44; a landing exactly the bridge's width stopped the bot at its west edge, because the step up off it happens with the hull still 0.35 under the bridge. The landing runs 0.8 past the bridge's west edge for that reason, and `headless_match` checks `stand_height` of headroom over every tread.

`headless_match`'s *dm_pit* section reads the eleven boxes back off the list (every rise, the shelf lip included, under `step_height`; flush from the shelf to the other stair's first tread), steps a bot off the floor into the valley and up, runs one from the east arm through the valley without jump (printed: 18.1 m east arm to shelf in 2.20 s, the 9.1 m stair in 1.02 s, 8.99 m/s against 9.00, asserted within 1.5), holds it on until it stops against the perch still on the shelf, hops it onto the perch, and traces a chest on every tread west of the bridge from the perch's eye (the one tread east of it is behind the bridge, the valley's only cover). Armed three ways: the landing ended at the bridge edge (six checks, the bot stuck at 1.09), the treads removed (the count check, and the section's total), and the bot at 0.6 of forward (pace fails at 5.41 m/s). Survey: dm_pit 974 m² standable, 0 unreached, 0 trapped, 0 closed slots, 3 tight. Rendered: `tools/screenshot.sh dm_pit --view shelf_stair 6,3.2,4.5 -8,2.5,9.5 --view from_perch -10,7.2,10.5 2,0.5,8.5`.

## `dm_atrium` gained an east stair, so the east yard has its own way up

**Extended 2026-10-01 (dm_atrium 1.5.0).** The 14 x 10 m east yard between the perch and the landing (spawn (26, -4) stands in it) was the one part of the map with no way up of its own: the north-west stair was 40 m away and the crates were five jumps round the corner. **The east stair** is twelve treads of 0.36 (walked, the number every stair here uses), 0.83 deep and 3 m wide at x 13..16, climbing south from the yard floor at z = -4 to the landing's north face at z = 6. The top tread is 4.32, 0.18 under the landing, so held forward walks onto the landing and the landing's 0.1 step is the ring. It stands 3 m off the building's east wall, so the east doorway opens onto a 3 m corridor rather than closing, and 2 m clear of the perch's first steps, so its foot is a pocket rather than a slot. No spawn was added or moved.

**Ending flush against the landing is the load-bearing decision**: stopped 1 m short, the bot runs off the top tread into the corridor and lands on the floor. **The trade is the perch**, 2.4 m over the top tread: from its south-west corner it looks down every tread, so the walked way up from the east yard is the most watched one. (From the middle of the perch its own edge hides the lower eight treads, which is the edge doing its job; the check stands where a player watching the yard stands.)

`headless_match`'s *dm_atrium* section reads the twelve treads back off the box list (every rise and the landing lip under `step_height`, top flush with the landing), walks a bot from the yard up the stair onto the landing without jump (printed: 10.1 m foot to landing in 1.11 s, 9.07 m/s against 9.00, asserted within 1.5), and traces a chest on every tread from the perch's corner. Armed three ways: the stair ending 1 m short of the landing (the flush check and the drive fail, the bot ends on the floor at z 5.6), the bot at 0.6 of forward (pace fails at 5.42 m/s), and a 1 m parapet round the perch (the sightline fails on four treads, and the survey reports the perch top unreached). Survey: dm_atrium 3572 m² standable, 0 unreached, 0 trapped, 0 closed slots, 2 tight. Rendered: `tools/screenshot.sh dm_atrium --view east_stair 27,2.2,3 13,2,0 --view from_perch 16.4,8.3,-4.4 14.5,2,3`.

## `dm_box` gained two corner stairs, so the ledges' stubs are ways in

**Extended 2026-10-02 (dm_box 1.4.0).** The gantries meet the ledges at |z| 8..10.5 and the ledges run on to |z| 18, so each ledge carried 7.5 m of high ground past its last junction that led nowhere, and the floor at the two ends of the room (three of the eight spawns) had only the nest stairs, which climb toward the middle. **The corner stairs** are ten treads of 0.36 (walked), 0.9 deep and 3 m wide along the north wall (x -17.5..-8.5, z -24..-21) climbing west to a **landing** (x -24..-17.5, z -24..-18, top 3.6) that carries the west ledge on into the corner; the south-east one is its half-turn, computed from the boxes, so the map is still its own half-turn. The NE and SW corners keep their stubs, which is what a half-turn rather than a mirror gives. No spawn was added or moved.

**The landing is the load-bearing box**: the top tread meets it flush and it runs on to the west wall, so a run up the stair ends against a wall at ledge height and the ledge is one turn south. Without it the bot runs off the top tread and drops 3.6 m into the corner. It is a box from 3.0 like the ledge, so the corner under it stays floor, a 3 m pocket open to the south. **The trade** is the nest on the same side, which looks down every tread.

`headless_match`'s *dm_box: the upper level, climbed* reads the ten treads and the landing back off the box list (every rise under `step_height`, top tread flush with the landing, landing flush with the ledge), walks a bot up each corner stair separately without jump (printed: 7.9 m of stair in 0.86 s, 9.14 m/s against 9.00, both corners, asserted within 1.5), holds it on a second more until it stands against the side wall still at ledge height, turns it onto the ledge's old stub, and traces a chest on every tread from the nest's eye. Armed three ways: the north-west landing removed (half-turn, flush, run-on and onto-ledge checks fail; the bot ends on the floor at y 0), the bot at 0.6 of forward (pace fails at 5.44 m/s), and a 1.5 m parapet on the nest's west edge (the sightline fails on all ten treads). Survey: dm_box 2737 m² standable, 18 unreached (the two declared pillar tops), 0 trapped, 0 closed slots, 2 tight. Rendered: `tools/screenshot.sh dm_box --view corner_stair -1,3.2,-15 -16,2,-22.5 --view from_nest 4,6.6,-12 -14,2,-22.5`.

## `dm_atrium` gained a rampart, so the keep roof goes somewhere and the perch has a second way on

**Extended 2026-10-04 (dm_atrium 1.6.0).** The perch (6.7) was reached only from the ring's east arm up its two steps, so whoever held it watched one approach; the keep's roof (5.5) was a high point a player jumped onto and could only leave by dropping. **The rampart** is a 3 m walkway across red's half joining the two: x -12..21, z -15..-12, top 5.86, from the keep roof's east edge to the perch's north face, on three 1 m piers 8 m apart (x -4.5, 3.5, 11.5) so the north yard under it stays open floor. Every number is one the map already uses: the step off the roof is the 0.36 every stair here walks, the perch is a 0.84 hop off its east end, and from the ring's north arm it is 1.26 up across a 2 m alley, over the 1.125 climb limit — so it is joined at its two ends and nowhere along its length, a route rather than a second ring. No spawn was added or moved.

**The trade** is the one every way onto a high point here makes: it runs straight at the perch, so whoever holds the perch sees all 33 m of it, and the keep-roof end is the far end of a duel rather than a back door onto the throne.

`headless_match`'s *dm_atrium* section reads the walkway, the keep roof, the perch and the north arm back off the box list (flush with the roof's east edge and the perch's north face, the step off the roof under `step_height`, the perch over it and under `climb_limit()`, the ring over `climb_limit()`), walks a bot off the keep roof along the rampart without jump (printed: 30.0 m roof edge to x 18 in 3.33 s, 9.02 m/s against 9.00, asserted within 1.5, never below the walkway's top), hops one off its east end onto the perch, and traces a chest every 3 m along it from the perch's north-west corner. Armed three ways: the walkway raised to 0.6 over the roof (the step check, the drive and the pace fail; the bot stops at the roof's edge), the bot at 0.6 of forward (pace fails at 5.41 m/s), and a 2 m parapet on the perch's west edge (the sightline fails on nine of ten points, and the survey reports the parapet top). A parapet on the perch's NORTH edge hides only the nearest point, because the perch's eye looks west along the walkway rather than across it. Survey: dm_atrium 3656 m² standable, 0 unreached, 0 trapped, 0 closed slots, 2 tight. Rendered: `tools/screenshot.sh dm_atrium --view rampart_from_keep -17,7.6,-13.5 18,6,-12 --view rampart_from_yard 6,3,-27 2,5,-13 --view rampart_from_perch 18,8.4,-10.5 -12,6,-13.5`.

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


## `dm_box`'s upper level is a loop now, and every map is surveyed as a rule

**Extended 2026-09-24 (dm_box 1.2.0).** The crates of 2026-09-22 made the two ledges reachable and left them dead ends: 36 m of high ground with one way on. Two **gantries** at ledge height now cross the room north and south of the raised middle, so the upper level is ledge, gantry, ledge, gantry — and each gantry carries one 0.9 m step against the pillar it passes, which makes the pillars at (4, -12) and (-4, 12) a third tier at 5.0: two **nests** over the middle that see everything and are seen by everything. The two pillars beside the crate stacks stay out of reach on purpose and are declared so (`ArenaMap.add_out_of_reach`). The map stays **its own half-turn about the origin**, which is the property it ships for, and `headless_match` now asserts that of the whole box list rather than of a comment.

Driving it found two things the arithmetic sweep had passed. **The crate gaps were 1.0 m and a bot could not climb them**: auto-hop plus the 1.2 m/s air cap means a player hopping up with jump held carries about 0.6 m per hop, so it fell into the gap between the first two crates. They are 0.5 m now, like the other maps'. The top crate was a metre from the ledge for the same reason, and could not move toward the wall because the x-axis spawns stand at ±18 — so the ledges are 6.5 m deep instead of 6, and those spawns stand under the lip. And a bot turning in mid-hop keeps all its old speed, because air control only adds along the wish direction: the climb test stands still for a quarter of a second on the top crate before turning, which is what a player does.

**`ArenaMapSurvey` is `[gate-sweep-1]` as a rule over the box list** (`maps/arena_map_survey.gd`), asserted per map in `headless_match`'s *every map: slots and reach* section:

- `slots(map)` — every pair of boxes whose facing sides are under 0.8 m apart, running side by side for at least 0.8 m, both walls at the floor between them, nothing in the gap, and **not a declared climb** (a `Climb` now keeps its two boxes, because 0.5 m of air between two crates is a jump and the declaration is the only thing that says so). 0.8 is the family's width; the motor's hull is 0.7 (`radius` 0.35), so the rule errs toward calling a slot closed.
- `reach(map)` — a 0.25 m grid of every surface a crouching player fits on, walked under `STEP_HEIGHT`, fallen off anywhere, and jumped under `climb_limit()` within `jump_reach(rise)` along an arc that passes through no box; flood-filled from the spawns forward (reached) and backward (can get back). `unexplained()` is what is unreached and not declared `out_of_reach`; `trapped` is reached with no way back. Since `[reach-3]` `ArenaMap.climb_limit()` and `ArenaMap.jump_reach(rise)` keep no arithmetic of their own: they ask `DotFpsTunables.climb_limit()` / `jump_reach(rise)` of the static `ArenaPlayer.arena_tunables()` (loaded lazily and cached, since the player script preloads the map), and the numbers are unchanged — 1.125 m climb limit, 6.07 m reach flat, 4.64 m onto a 0.9 m rise.

First run: **five closed slots on two maps**, all fixed — dm_atrium's last piers stood 0.5 m short of the crate column (two slots that looked like the arcade's east way out; piers now at 5.5 m spacing, flush), its north-west stair stopped 0.75 m short of the building (a slot from the yard to the west doorway; stair now flush at x = -10, which also takes the air out of the step onto the ring), and dm_pit's pillars stood 0.75 m off both stairs' sides (moved from ±6 to ±5.75). dm_atrium and dm_pit are at 1.3.0. Numbers now: dm_box 2696 m² standable, 18 unreached (both declared pillar tops), 0 trapped; dm_atrium 3560 / 0 / 0; dm_pit 985 / 0 / 0; each map has two **tight** gaps between 0.8 and 1.05 m, all passable, printed rather than failed. The section is armed by a fixture map with a 0.5 m slot, a tower nothing climbs and a courtyard you can drop into and not leave, and was armed for real by putting the atrium's old pier spacing and stair back (three closed slots reported).

## An administrator's live tools

`ArenaModTools` is what dot-moderation's handler table means in a deathmatch, and **every verb in it is somebody else's seam**: noclip, freeze, speed and gravity are dot-player-controller's `DotFpsAdminModifiers`; god and buddha are `DotHealth.invulnerable` and `cannot_die`; slay and slap are ordinary `DotDamage` through the combat manager, so the kill feed, the scoreboard and the stats hear about an admin's slay exactly as they hear about a rocket; respawn is `ArenaGame.respawn_player`, which is the match's own respawn path with the queue cancelled; burn is `ArenaEffects.BURNING`. The commands are `DotModToolCommands`, installed on the module so they go when it does.

Three decisions worth not undoing:

- **`admin_abilities` is on for every `ArenaPlayer`, server and client alike.** The admin modifiers register after the game's own and their indices travel on the wire, so a client that had not registered them would read a forced noclip as some other modifier. `headless_net` measures what this buys: a player an admin noclips is predicted flying by their own client with no tick out of noclip and a worst gap of a quarter of a metre, where the same flight set as a bare `state.mode = NOCLIP` spends 61 of 64 ticks predicted falling, up to 2.9 m from the server. That second half is the check's negative control.
- **A slay turns god, buddha and spawn protection off for exactly one damage event.** A slay that god mode refused would make god a way to be unslayable; the flags are put back, because the tools re-apply god on the respawn.
- **A respawn clears a freeze and a noclip and keeps god**, through `player_spawned`, which fires for a match respawn and an admin's alike because `respawn_player` takes the same path. **Blind and beacon are kept too** (`ArenaModTools.PERSIST_ON_RESPAWN`): they are about the person rather than the body, and a death is what a player being punished would otherwise use to end one.

**Blind and beacon were refused as "no client overlay" until 2026-09-24, and are two flags now.** `ArenaPlayer.blinded` and `ArenaPlayer.beacon` are set by the handlers on the server and replicated as per-player state in `ArenaPlayerNet` — `net_blind` **owner-only**, the way the ammunition is, because nobody else's screen changes and an opponent who could read it would know the moment somebody could not see them; `net_beacon` to everybody. State rather than an event because a joiner, a lost snapshot and a map change are all a baseline the next snapshot corrects, where an event sent once is missed. The client draws them: `ArenaHud.blind_overlay` fades a near-black rect in over a quarter of a second, **under** the HUD's widgets so the clock and the kill feed still say the match is going on, and sized to the whole viewport rather than to the HUD — `DotHud` insets itself by the safe area, and the first rendered blind left a sixteen-pixel frame of the world round the edge. `ArenaBeacon` is a ring at the feet that sends out a ripple once a second and a thin column drawn through walls (not on your own beacon: a camera inside it is a smear over the screen), placed at the drawn position; each ripple is `ArenaPlayer.beacon_pulsed`, which the client plays as `ArenaPresentation.BEACON_SOUND`, a positional BLIP an octave under the hit marker that carries 160 m. A beaconed player's entity is also `always_relevant`, so the beacon reaches a client however far away they are. `blind <player> <seconds>` is dot-moderation's (`TIMED_TOGGLES`), lifted through the same handler.

**A slay inside spawn protection was refused, and it was found writing this.** `slay` switched off god, buddha and `DotHealth`'s spawn window — one of spawn protection's three records — and `ArenaEffects.adjust_damage` then vetoed it on the other two, the `PROTECTED` effect and dot-spawn's ledger: "The slay was refused: invulnerable", for the first second and a half of every life, which is exactly the spawn-camping griefer an admin reaches for slay to stop. The slay's damage carries `ArenaEffects.ADMIN_KILL` in its context now and the hook lets it through; `headless_admin` slays a player who has just respawned, and fails without it.

`headless_admin`'s **blind and beacon** drives both through chat and asserts the flags, the entity the netcode sends, the timed lift, the relevance and the respawn; `headless_net` asserts the audience over the lossy link — the owner's client blinded, the other client never told, both drawing the beacon — and was armed by dropping `to_owner_only()`, which two checks caught; `headless_presentation` asserts the ping happens once a second rather than once a frame, the marker goes when the flag or the player does, and the blind covers the viewport (armed with the HUD-sized rect). `tools/screenshot.sh dm_box --admin` renders a beacon on open floor, one behind a pillar with only its column showing, and a first-person view through the real HUD before and after a blind.

`headless_admin` is the suite, on a real `DotServer` with the module loaded by path. Two things it found while being written, neither a bug in the code under test and both worth knowing: **`dm_box` has a platform at the origin**, so a body teleported there is pushed out by the motor's depenetration and a frozen player appears to drift — every position check here starts on a spawn point; and **an adopted session has no peer**, so the netcode's own sends were 1,287 engine RPC errors in one run until the suite pointed `send_fn` at nothing.

## The map vote: one set of commands, one clock, and a score it is actually told

Three things were written and not joined, and a fourth ran twice.

- **dot-vote's commands were never installed.** The module's chat handler answered `!rtv`, `!nominate`, `!vote`, `!nextmap` and `!timeleft` itself, and `setnextmap`, `nominate_addmap`, `forcertv` and `votereload` did not exist on this server at all. `ArenaVote.install_commands` puts `DotVoteCommands` on the module now, and the chat handler claims none of the five unless the vote failed to load, so an unclaimed `!rtv` reaches the console's `rtv` — one path. Two things make them this game's: `resolve_fn` turns the `dm_atrium` a player types into the ballot's `map:dm_atrium`, and `voter_fn` keys a voter as the bare session id, which is what `voters_fn` lists and what a disconnect forgets — dot-vote's default is `u<userid>`, and two spellings of one voter is a player who rocks the vote twice. `vote` keeps its name rather than dot-vote's `votefor`, because `!vote 2` is what players here already type.
- **Two clocks ran and the first to expire won.** The map director's `DotMapTimeLimit` and the vote's `DotVoteClock` were both thirty minutes from boot. The map director's reached `_on_map_over`, which opened a second ballot over a winner the players had already chosen and was waiting for its moment. With a vote, only the vote's clock is advanced; the map director's is the fallback for a server whose vote did not load. `dedicated` asserts one moves and the other does not.
- **Nothing called `note_score` or `note_round_end`.** `ArenaVote.note_round_end` existed and was called by nothing, so this game's rule that a winner waits for the end of a round reached the director only as the clock running out. `ArenaVote` now polls the leading score each tick — the best player's frags, or the leading team's total in a team mode, whatever dot-match's own limit is measured on — and follows dot-match's `round_ended`, rebinding on every map change because a map change builds a new match. A score is **per match**, because dot-match zeroes the scoreboard every round: a vote `score_limit` is a frag limit on one match, the way the old choosers read the frag limit. An extend that raises the vote's score limit raises the match's too. `headless_match` rides a score-limited vote on the real deathmatch and asserts the ballot opened off the bots' own frags while the round was live; it was armed by removing the poll and the connection, and three checks fired.
- **The cues went nowhere.** `ArenaVote.cue_due` carries each `cue` and each countdown second, the module sends it as a `VOTE` event (appended last in `Kind`, because a kind is its index on the wire), and the client plays the id through `ArenaPresentation`'s catalogue and draws the countdown on the HUD's notice line. The four ids are `ArenaVote.CUE_*`, named by the rules and defined in the catalogue from the one constant, with synthesised stand-ins like every other sound here. Chat still carries what the ballot says; this is what chat cannot carry. The rules give a ten-second countdown before a ballot, so the countdown cue has something to count.

## No message preloads itself

`arena_event.gd` and `arena_request.gd` each began by preloading themselves, for a typed `of()` factory. mg-buses-from-hell measured that line (8ed866c) as enough to leak the whole script graph at exit on Godot 4.7.2: a script that `extends DotNetMessage` and preloads ITSELF, first loaded by a module inside a running `DotServer` — which is how every deployed server loads a game. Both are built with `new(kind, body)` now, an `_init` whose arguments default because dot-net's registry decodes with a bare `new()`.

`dedicated`'s last section, **exiting clean**, reads every `DotNetMessage` script under `game/` as text and fails on a self-preload. It is on the source deliberately: the leak is printed by the engine after `quit()`, where no assertion can reach.

**Here it was not the cause, and the leak is still open.** `dedicated` exits with 23 ObjectDB instances and 6 resources, exactly as many before the change as after (2026-09-23) — too few to be the whole script graph, so a different shape from the one buses had.

## The horde fights as a squad, and one of it shoots (2026-10-05)

Four kinds now. Grunts, brutes and stalkers close in, but only three of the horde attack one player at a time (`"attackers"` in `ArenaNpcs`, dot-npc-ai's attack slots); the rest wait on a ring just out of reach, shared out so they stand apart, and the stalkers — the most tactical — end up behind you. The **gunner** builds a ranged branch from its definition's `range_damage`: it breaks off to cover when badly hurt, one per player takes the flank role and goes round, and the rest hold a 9-18 m band, strafing, and fire through `ArenaHorde.npc_shoot` — a `DotShot` dot-combat resolves against real hitboxes, so armour, the kill feed and lag compensation all apply. Its accuracy is set to about half, deliberately: a hard preset's 0.85 at three shots a second is a gunner nobody can cross the room against.

The monsters **hear**: every player shot is a combat sound owned by the shooter, every rocket in the air is a danger with its splash as the reach (they dodge), every detonation an explosion. And they **learn the map**: `ArenaHorde.heat` samples where players walk twice a second, the monsters with the tactics for it patrol those places and wait facing the way players come, and a real server — `ArenaModule` turns it on — keeps what it learned per map in `user://npc_heat` across restarts. `ArenaGame.persist_npc_heat` is off by default because every suite builds an ArenaGame.

**Monsters are still not replicated.** `ArenaNetBridge` sends nothing about them, so all of this is seen offline and on a listen server, and a remote client sees no monsters at all. That is the next piece of work for the horde mode to be playable online, and dot-npc's `DotNpcNetSync` is what it was written for.

## Things deliberately not here

- **Pickups in the world.** dot-loadout ships `DotPickup` and `DotPickupField`; the map
  places none (the only pickups are what a critical kill drops; see "Coins out of a body"). An arena with weapon and armour pickups is most of what makes map
  control matter, and it is a level-design decision rather than a wiring one.
- **Any actual audio files.** The catalogue is written and every id still resolves to a path in `audio/` that does not exist — which is the right way round, because what this game was missing was the decision rather than the files. It is no longer silent, though: `sound_recipes()` maps each of the nine ids to a `DotAudioSynth` voice, and `DotAudioSinkGodot` falls through to that bank when a path resolves to nothing. The three weapons deliberately get three *different* voices, because a rail that is a quieter rifle is the one thing weapon audio must not be — the point of hearing somebody else's shot is knowing what they are holding before you come round the corner. Dropping nine `.ogg`s in still changes nothing else, and now it also switches the stand-ins off one id at a time. The weapons themselves are zee-dot-weapons' now and bring their own baked reports, so these stand-ins are only what a client shell too old to carry `ZeeShotFx` falls back to.
- **Bots worth the name.** `_commands_for_tick` aims at the nearest opponent and holds
  the trigger. It is a test fixture, not an opponent.
- **A master server.** `DotBrowserSourceBackbone` reads a listing that nothing is yet
  publishing, and there is no heartbeat — so the browser finds what somebody typed
  into it and nothing else. That gap is the family's rather than this game's.
- **Joining from the browser.** `ArenaBrowser.BrowserScreen` lists servers, favourites
  them and reports which one was picked; connecting means tearing down this client's
  netcode, opening a transport at a new address and going through signon again, which
  is a launcher's job — and this game is loaded *by* one.

## The map vote is drawn on the client shell (2026-10-04)

The vote wrapper owns a `DotVoteBallotFeed` and polls it every `advance`; the module points its `ballot_fn` at `server.send_notice`, one copy per playing session with that session's voter id as `you`, under the topic `map_ballot`. dot-server-deploy's shell draws it as a dot-ui `DotBallotPanel` beside the server's own `game_ballot` — number keys, F3 and a click, or both, and every voter's avatar on their choice — and a click goes back as the same `!vote`-style command a player could type. Standalone, with no shell, nothing draws it and chat still carries the ballot. Defaults moved with dot-vote's: the map clock is forty-five minutes (`duration_sec` 2700, and the map director's fallback `map_seconds` with it) and the ballot opens 150 s before it. `round_based` is on, because dot-match's `round_ended` already reaches the director, so an operator's `time_up: finish_round` plays the round in progress out before the map changes.

## zee-dot-weapons, and the half of the weapons nobody could see (2026-10-05)

The four weapons this game wrote for itself (`ArenaContent.pistol()` and the rest) are gone, and all twenty-seven of zee-dot-weapons are what a player carries. `ArenaContent.weapons()` is `ZeeWeaponPack.weapons(damage_table())`. The damage table is the pack's four types plus this game's `bullet` (the horde's gunner still fires bullets), `fall` and `world`. It is built once and handed to the pack and to dot-combat, so the launcher's splash and the registered `blast` are one object rather than two that agree today. `addons/zee_weapons` is linked and in `.gitignore`. The CC0 art is vendored in `assets/` (1.9 MB, as playground and smash-copter do), and the client points `ZeeModelCache.set_asset_root` at `ArenaPaths.root()` on `_ready` and back at `res://` on `_exit_tree`.

**The rig drives the player's own arsenal, and that is what let it be rebuilt.** `ArenaPlayer._build_rig` hands a `ZeeWeaponRig` the existing `Arsenal` node by `arsenal_ref` rather than letting it build its own. A rig's role, which decides what it draws, is fixed at `setup()`, and a player is built before anybody knows whether it is the one at this keyboard. So the client rebuilds the rig as LOCAL when it adopts its player (`arm_first_person`, with a `ZeeViewModel` under the camera), and everything carried survives, because it lives in the arsenal. Every reader of `player.arsenal` (the HUD, the netcode, the mod tools, the loadout) reads the same node it always did. Simulation goes through `weapons.simulate_tick`, which runs the arsenal and then the bash and keeps its own previous command. `used` is the rig's signal, so it carries the bash and is silent in a replay. Somebody else's gun is a `ZeeWorldModel` on a hand `ArenaPlayer.attachment()` answers for, because the avatar rig has a body, a head and a crest and no hand. It is driven from the snapshot on a mirror and from the rig on anything this machine simulates (an offline bot), on one code path. The camera's half of the recoil is added in `present`, the one place the camera is written, and through `has_method`: `view_punch` and `shot_fx` are newer than the client shell's zee-dot-weapons v0.1.3, and a call by name to a method the shell's copy lacks would not compile. On that shell the game still runs, with no punch and with arena's own flash and report in place of the pack's.

What wiring it found, in the order it was found:

- **A connected client's arsenal was empty for the whole of every match.** A loadout is resolved from a store on the server and nothing sent the result, so the client predicted no shot, drew no flash, played no report, its HUD read zero and its number keys selected nothing, while the server fired everything correctly. `headless_net`'s `[audience]` had written it down as "not asserted". `net_carry` (one bit per weapon, owner-only, for the ammunition's reason) fills the owner's arsenal through `ArenaContent.apply_carry` before the predictor replays, and `correct_ammo` follows. `net_weapon` (five bits, everybody's) says which weapon is in hand, which `net_slot` cannot once there are nine primaries in slot 3. Armed by skipping the `apply_carry`: four checks fail (`0 against 8322`).
- **Every reconciliation re-played every shot in the window it replayed.** dot-net's predictor calls `_net_simulate` for a replayed tick exactly as for a fresh one, and nothing marked which was which, so `used` fired again per correction: the sound, the flash and the kick several times per shot at a tenth of a second's latency. `ArenaPlayerNet._predict` wraps any tick at or below the newest one simulated in `begin_replay` / `end_replay`. Armed: a replayed shot is drawn twice.
- **Every rocket that went off more than 2.5 m from its owner exploded in the owner's face.** `ArenaProjectiles._detonate` went through `DotCombatManager.resolve_shot`, which corrects any shot whose origin is more than `max_origin_error` from where it believes the attacker is (right for a gun) and then re-traces, clearing the impacts set by hand. With `max_range` 0 the trace ends where it starts: at the owner's eye. The launcher hurt nobody but the person firing it for as long as it existed, and nothing could see it, because no check asked the shooter's health. Found by the first one that asked a thrower's. The believed origin is pinned to the blast for that one resolution and put back (`ArenaProjectiles.origin_of`). Armed: a frag thrown fifteen metres took exactly half its splash off the thrower.
- **Projectiles knew only contact.** A pack grenade has a fuse that starts when the pin comes out, so `ArenaProjectiles` now separates a fused spawn (bounces, rolls to rest, sticks if its definition says `sticks`, goes off on the fuse) from a contact one (the launcher). A grenade cooked past its fuse (no velocity, no fuse) goes off at once, where it used to float for twelve seconds. The thrower is ignored for eight ticks rather than one, because a grenade lobbed while running is overtaken by its own thrower.
- **Nothing drew a projectile, offline or connected, and a connected client was told nothing about one.** `ArenaEvents.Kind.LAUNCH` (kind 10, after the monsters' 8 and 9) carries who, which weapon, from where, how fast and the fuse. A client flies a copy through the same `ArenaProjectiles` against the same analytic map, from `client_tick`, and its copy decides nothing because its combat manager is not the authority. A mirroring client also swaps its combat trace on a map change now, or its copies bounced off the old map. `ArenaProjectileView` draws the list, and `ArenaPresentation.on_explosion` plays `scenes/fx/explosion.tscn` and a shake that falls off with distance.
- **The highest slot is the grenade.** `give_loadout` spawned a player holding whatever was in the highest slot, which was the launcher when there were four weapons and is the throwable in the pack's layout. `_better_hand` takes the heaviest gun.
- **Optional loadout slots are never in the default.** dot-loadout's `default_loadout()` fills required slots only, so with melee and the throwable optional, the store's default replaced the class loadout a frame after every spawn and the 5 key selected nothing. Found by rendering, not by a check. Both are required now. A loadout saved before they existed is filled in rather than refused, because this game conforms on load and conforming fills an empty required slot before it trims to budget (asserted in `headless_match`'s content section).
- **Three things only a rendered frame showed** (`tools/screenshot_weapons.sh`, which plays the offline client through its own input path): the explosion began as the death burst's scene, a spray of dark red gibs that reads as somebody dying; a resting frag at fourteen metres is two brown pixels, so a grenade carries a red fuse light; and the weapon's name was right-aligned over a magazine count drawn at the left of its box.

`headless_match`'s *zee-dot-weapons in the arena* (28 checks) and `headless_net`'s *[weapons over the wire]* (14) are the suites. `headless_match`'s horde gunner check now chooses a spot with line of sight and strips spawn protection from its target, because it had been passing or failing on how the deathmatch above it happened to end.

**Release order.** The pack works against the shell's zee-dot-weapons v0.1.3. The view punch and the pack's own tracers and reports need zee-dot-weapons tagged past 0d7a364 and the client shell rebuilt before they reach a delivered game.

## Sliding and the launch, and the rules that keep both ends agreeing (2026-10-06)

`ArenaPlayer.arena_tunables()` turns on dot-player-controller's slide (C, or Ctrl: crouch at a run) and launch (E, the movement command's first user bit, which the arena leaves free because its weapon buttons ride in their own command). **E is the prop tool's in a mode where players use props** (`ArenaClient.props_on_e`), and the launch moves to X there. **Shift dashes** (dot-player-controller's dash on the sprint bit, which this game leaves free because it has no sprint): `arena_dash`, `arena_dash_speed`, `arena_dash_lift`, `arena_dash_cooldown`, and the HUD's ability readout shows its cooldown under the launch's. A server owner changes the rest with `arena_slide`, `arena_slide_boost`, `arena_slide_min_speed`, `arena_slide_duration`, `arena_slide_friction`, `arena_slide_cooldown`, `arena_launch`, `arena_launch_velocity`, `arena_launch_forward` and `arena_launch_cooldown` (`ArenaModule.MOVEMENT_CVARS`); each defaults to what the tunables already say.

**A rule set on the server alone is a client that mispredicts every slide**, so `ArenaGame.set_movement_rules` keeps the changed keys (`movement_rules`), applies them to every player now and on `add_player`, and emits `movement_rules_changed`; the bridge sends `ArenaEvents.Kind.RULES` (appended after LAUNCH) to everybody, and to a joiner straight after HELLO and before any JOIN. `ArenaPlayer.apply_movement_rules` writes the class base too, or the next class change would put the old number back. `headless_net`'s *movement rules reach every client* (6 checks): a rule reaches the client's game, the fingerprints match, E throws the server's player 4.35 m up from a spawn and the client predicts it within a hand's width (0.42 m), and the negative control is the fingerprint left apart by a server-only change — **the gap cannot be one in this lockstep harness**, because a snapshot corrects a wrong impulse within a tick or two (0.38 m against 0.42 m). Building it found dot-player-controller's rewind keeping the client's own launch cooldown and buttons (3.2 m apart); the timers and `previous_buttons` travel in `net_flags` now. Run after the weapons section: this harness fires every eighth tick, and its windows spent the magazine the weapons section's fresh shot needs.

## Aiming, criticals, a body that comes apart, and your own body (2026-10-06)

**Right mouse aims** (zee's `ZeeViewModel.aim`: the hands come up, `ArenaPlayer` scales the camera's lens from the player's own field of view, never from the last zoom), and **F is the bash** ("quick melee"). The `right_mouse_aims` setting (controls, ACCOUNT scope) puts the bash back on right mouse. In a mode where F is the prop tool's freeze, the bash is right mouse's. The HUD draws zee's `ZeeScopeOverlay` at full aim with a scoped weapon and hides the crosshair under it.

**A critical is dot-combat's judgement** (`DotDamage.critical`: a headshot by default; `arena_crit_chance` and `arena_crit_scale` change dot-combat's rules on a running server), and the KILL event carries it as an optional trailing bit (`ArenaEvents.write_kill(..., critical)`; an older server's kill reads as none, which `headless_net` asserts). On a client, a kill whose rules say so breaks the victim's body (`ArenaPlayer.break_body` over dot-player-char's `DotPlayerBodyBreak`), seeded from victim and killer ids — **not the tick**, which each client receives at its own — and `_mend_body` puts it back on respawn. `arena_break` (0 whole / 1 limbs / 2 explode, default 1), `arena_break_limbs` and `arena_break_criticals` (default 1: only a critical breaks a body) travel in RULES with the movement rules (`ArenaGame.SHOW_RULES`), because a client draws them.

**Your own body in first person** is `arena_fp_body`, off by default. `ArenaPlayer.present_own_body` builds the local player a body on demand, hides the head, the crest and the whole upper body (the view model already draws arms and hands), and draws the waist and legs `FIRST_PERSON_BACK` behind the eye. **The first renders were a grey slab**: from the eye, the stock blocky avatar's shoulders and then its hip tops are boxes a hand's width under the camera. Hiding the upper body leaves the hip tops; it looks like boxes because the avatar is boxes, and it stays off until an avatar with legs worth seeing is the default.

**The HUD**, all render-checked (`tools/screenshot.sh dm_box --feel`): a red edge when health is under a third (a radial gradient sized to the whole viewport like the blind — the first render was a red rectangle over the HUD's safe area, and too strong in the middle), the launch's key and readiness or cooldown left of centre above the bars, and "C  Cancel slide" while sliding. `headless_presentation`'s *A critical breaks a body, a respawn mends it, the HUD shows the rest* (8 checks).

**`--feel` draws the weapon in the hands since it arms them on the first frame**: armed in the script's `_init`, before anything was in the tree, the rig's `get_path()` of the hands failed and every frame showed empty hands. With a weapon, the scope frame found the scope sized to the HUD's safe area, leaving strips of world at the top and left; it is sized to the viewport now, like the blind. Its break frame shows pieces in the air but the stair block hides most of the body.

## Coins out of a body (2026-10-06)

A lethal critical drops coins and a health pack: the genre's reward for a headshot, which the reference videos show as coins bursting out of the body and flying to whoever walks through them. `ArenaDrops` is one `Node3D` on both ends. On the authority it holds real one-shot `DotPickup`s in a `DotPickupField`, swept each tick (after the player stack, before the match) against every live player's simulated position: a coin adds to `coins[player]`, a pack heals, and only a hurt player takes a pack (`wants_fn`), so it is left for somebody who needs it. On a client it holds drawn copies (a gold disc, a green cross, no art): DROP (appended after RULES) bursts one out of the body to where it lands, TAKEN flies it to its taker or removes it when it expired (taker 0). An authority that also draws (offline, a listen server) draws its own. `_known` keeps every drop a client was told about whether or not it draws, because the coin tally the HUD shows (`ArenaHud.coins_label`) is counted from TAKEN.

It is rebuilt with the combat layer on a map change, and the owner's rules live on `ArenaGame.drop_rules` so a change keeps them: `arena_drop_coins` (5), `arena_drop_coin_value` (1), `arena_drop_health` (25, 0 for no pack), `arena_drop_any_kill` (0: criticals only) and `arena_drop_life` (10 s). The scatter is seeded from the victim and the tick. **Not done**: coins do not feed the match score or a power-up meter yet (dot-match has no per-player award; a meter is a game rule to design), and they are not a dot-stats stat. `headless_match`'s *a critical kill drops coins and a health pack* (9 checks); `headless_net` asserts a TAKEN lands on the client's tally; `tools/screenshot.sh dm_box --feel` draws them (`dm_box_feel_drops`).

## Gun Game and weapon pools, as mode data (2026-10-06)

`ArenaMode` grew a Weapons group: `weapon_pool` (zee ids, or `tag:<tag>` for every weapon carrying it), `pool_random` (one at random per spawn), `pool_keeps_melee` (the knife stays), and `gun_game` (the weapons in order). `ArenaGame.arm_for_mode` runs after a loadout is applied (both of `apply_loadout`'s branches, since it awaits a store) and replaces what the loadout gave; a gun game kill re-arms the killer straight after `report_kill`. **Gun game's level is the player's match score and its score limit is the list's length**, so "advance on a kill" and "win by finishing the list" are the scoreboard rather than a second counter that could disagree with it, and `validate()` refuses a gun game whose two numbers differ. Two shipped modes: `gungame` (fifteen weapons, heaviest to the knife) and `snipers` (`tag:scoped`, random per spawn). A "revolvers only" or "shotguns only" server is a copy of `only_snipers` with a different pool. A melee kill (any weapon tagged `melee`) also takes a point, so a gun, off the victim (`gun_game_melee_demotes`, on by default, never below the first gun), and the spawn banner names the mode's rule (HUD work, d9841ba). `headless_match`'s *gun game and a weapon pool* (12 checks).

**`ArenaDrops` takes a pickup out of the field as it goes, not at the end of the frame**: a server runs several ticks a frame, and a pickup still in the field's list after `queue_free` was swept as a freed object (four script errors in `headless_match`, every check still passing — read the stderr).

## Kill streaks, kill feedback and the death panel (2026-10-06)

**Streaks are counted on the server for rewards and on each client for the meter**, both from the same kills: `ArenaGame.streaks` (authority) and `ArenaHud.streaks` (from the KILL events every client gets), so the meter needs nothing new on the wire. A reward lands on the kill that reaches it: `arena_streak_rewards` is `streak:reward` pairs (`heal`, `armour`, `haste`, `empowered`, the last two being `ArenaEffects`), default `3:heal,5:haste,7:empowered`, empty for none; the module announces it to everybody (`ArenaServices.announce`). On the HUD: a drawn streak meter on the left with "Killstreak xN", a cross at the crosshair on a kill you made (red for a headshot), a "HEADSHOT!" `Label3D` rising off the victim, the death panel ("Killed by NAME (weapon)", and "NAME is your NEMESIS" after three deaths to them), and "REVENGE!" when you kill the last player who killed you. Rendered (`dm_box_feel_hud`).

**`ArenaHud.notice` did not exist.** The client had called it for chat lines and both map-change notices since the client was written; it is a centre line held four seconds now. Found because the parser refused the same call inside the HUD's own file. **A client never knew the mode**, which is why the banner waited, and it broke something built the same night: `ArenaClient.props_on_e` read `game.mode`, a client's is whatever it was built with, so in Siege E launched instead of grabbing. The server now puts the mode's catalogue index in RULES (`mode_index`, `ArenaGame._announce_mode` at setup and on every map change); a client keeps it as `shown_mode` (display only — its own `mode` is never replaced, because logic reads it), `displayed_mode()` is what the keys and the banner ask, and `mode_shown` puts "Gun Game  -  Every kill gives you a different gun..." on the notice line. **The end of a match** opens the scoreboard on every client and names the MVP on the notice line (best score, then kills, with deaths and assists), from the client's own MATCH handler on the transition into `MATCH_END`. **A hurt enemy shows a health bar** over their head for three seconds after a hit (`ArenaPlayer._present_health_tag`: two quads in a node turned to the camera each frame, so the fill stays on its background; health already replicates to everybody). **Not done**: challenges (a dot-achievements progress bar).

## Spawns keep away from enemies (2026-10-06)

Christian decided it, configurable: `arena_spawn_mode` is `avoid` (the default: dot-spawn's SAFEST, and never nearer an enemy than `arena_spawn_min_enemy` metres, 10, when anywhere else will do), `weighted` (SAFEST without the floor), `furthest`, or `random` (what the arena did before). `arena_spawn_sight_penalty` (500) is what a site an enemy can see costs, through dot-physics' `line_of_sight_3d` as `can_see_fn`; `arena_spawn_enemy_weight` (1.5) what each metre is worth. A mode can name its own (`ArenaMode.spawn_mode`). The enemy list is side-aware in a team mode and everybody in a free-for-all, and **whether there are sides is the MODE's answer** (`is_team_mode()`), not dot-match's team manager, which exists in a free-for-all too: the first version asked the manager and told a free-for-all respawner its old team-mates were friends (`headless_match`'s free-for-all scenarios). The spawning player is never their own enemy: dot-spawn now hands a two-argument `enemies_fn` the spawning key (dot-spawn 85331a2). `headless_stack`: an enemy put on a spawn point pushes the next spawn 47 m away. The roster used to keep a team mode's sides into a free-for-all, so dot-team's `are_allies` called old team-mates friends; `ArenaPlayerStack._adopt_match_sides` now asks the mode too and puts everybody on a side no more into `unassigned` (`headless_stack`: tdm to ffa, 3 on sides before, 0 after).

## The combat surf maps, from g2gfast-maps (2026-10-08, `[arena-combat-surf-1]`)

game-g2gfast imports compiled maps from the surf genre, and ten of them are not courses: small maps with buy zones, weapons on the floor and teleports back to a spawn, built to fight on. g2gfast marks them `"kind": "arena"` in its `maps/zones/<id>.json`, the importer copies the kind into each map's manifest, g2gfast keeps them out of its own rotation, and this game plays them as a deathmatch. Christian's words: "small maps that don't need a timer and should be used in game-arena, since they are intended for deathmatch".

**Where the files come from.** `maps/imported` is a link to `g2gfast-maps/maps` (the `# bootstrap-link:` line in `.gitignore`), at the same path game-g2gfast links it, so the `.import` markers committed there are right here too and the first `--import` is about fifteen seconds. `ArenaImportedMaps` scans it (and `user://maps`) for manifests whose `kind` is `arena` — discovered, never listed, so a map g2gfast re-classifies is picked up or dropped with nothing edited here. `ArenaMap.by_id` falls through to `ArenaMap.imported(id)`, `ArenaMap.imported_ids()` sits beside `ids()`, and `ArenaMaps.catalogue()` lists both; an imported def is local (no `content_id`) at version `0.0.0-<12 hex of its manifest's md5>`, so a server and a client holding different imports of one map disagree at the announce instead of colliding against different brushes. A checkout without the link plays the three built-ins and every check about the imports skips, saying so.

**A copy of g2gfast's loader, not a dependency and not an addon.** `maps/arena_bsp_map.gd` is the half of `G2GBspMap` arena needs: the mesh `.bin` (ten floats a vertex, one instance per 256 surfaces), the lightmap through two shaders (`maps/arena_bsp_{lightmapped,translucent}.gdshader`, opaque unless the map's material says translucent, because writing `ALPHA` at all moves a surface into the transparent pass), one `ConvexPolygonShape3D` per brush and one welded displacement trimesh, the spawns and the pits. A game cannot name another game's script, and a delivered pack cannot resolve a `class_name` at all. Lifting it into an addon is the right home eventually and was weighed: it would put the loader in the client shell, so arena's pack could not use it until the addon is tagged and the shell rebuilt, and the reusable half is tangled with g2gfast's genre units, timer zones, texture set, stand-ins, flashlight and dot-lighting. What arena needs is three hundred lines with none of that, duplicated deliberately per the family rule. A surface the map carried a texture for draws it; anything else draws arena's own generated grid (`ArenaMap.dev_texture`), one square to 64 units, tinted the colour the map's compiler measured for it (a measured black only when the material is named black, g2gfast's rule). The map's sky, sun and fog are not read (that is dot-lighting, which arena does not link); the surfaces are unshaded and lit by their own lightmap, so only the background is arena's.

**The solid is the game's, on every machine.** `ArenaGame._build_world_collision` adds `ArenaMap.to_collision()` (the brushes) as `WorldCollision` before the combat manager and before any player is built or re-bodied, on setup and on every `change_map`, and frees it (`free()`, not `queue_free()`) when the map goes. `movement_body()` and `shot_trace()` bind to it: `DotFpsPhysicsBody` and `DotTracePhysics`, where a built-in map still gets `to_fps_body()` and `to_trace()`. `to_scene()` of an imported map is the drawn mesh only, so a client never has two copies of a brush. Physics queries see a body the frame it is added, which `headless_imported` relies on.

**Spawns and teleport destinations are settled at load.** Every one of `surf_10x_final`'s 48 spawns is 44 units inside the floor brush it stands in, and dozens of pit destinations across the ten maps are inside solid, so the motor (which pushes out of solid at most a step a tick) showed a player rising through the floor. `ArenaMap.settle_spawns` lifts each one in 5 cm steps until a standing hull is clear, up to 2 m, before `_build_match` makes spawn points of them — the per-spawn shape query g2gfast's own notes name and leave open. Armed: without it `headless_imported`'s sweep fails `surf_10x_final` and a player in the deathmatch is found inside a brush.

**Pits are teleports, and the floor under the map catches.** `ArenaPlayer._follow_map_volumes` runs inside the simulated tick, on the server and in the owning client's prediction alike, so neither end has to tell the other: a player whose feet enter one of the map's RESPAWN zones is put at its destination facing its yaw (on these maps every teleport aims at a spawn, a jail or the top of a ramp), and one 10 m under the map's bounds is put back at a spawn. Armed: both checks fail without the call.

**The surf genre's air control on these maps, the arena's on its own.** `ArenaPlayer.SURF_TUNABLES` is `air_accelerate` 150 (what g2gfast runs them at), a 30 u/s wish cap, 800 u/s² of gravity, a 57-unit jump and the 3500 u/s limit, converted at 0.01905 m a unit; ground movement, slide, launch and dash stay the arena's. `ArenaGame.map_movement()` is derived on both ends from `ArenaMap.movement_profile` (`&"surf"` for a `kind: arena` map), and `ArenaPlayer.apply_map_movement` writes it and puts every key it is not given back to `arena_tunables()` — which is what takes it off again on the next built-in map. Applied before a player enters the tree and before `rebind_map`, so the controller that logs its movement logs the map's. `arena_surf` (1/0) and `arena_surf_airaccelerate` (150) are the server's choice and ride RULES (`SHOW_RULES`), because a client predicts with them. Christian's pick is the default and the arena's own movement is one cvar away. Armed: without the reset on `change_map`, dm_box keeps 150 / 0.57 / 15.24.

**Two in the rotation, all ten installed.** `ArenaMaps.imported_rotation` (`arena_imported_rotation`: `all`, `none`, or ids) defaults to `surf_10x_reloaded_fixed,surf_110b_austinpowers`, the two Christian named; the rest are `enabled = false`, which the rotation pool, dot-vote's ballot and nominations already read (g2gfast keeps the same maps out of its own rotation the same way), and stay loadable with `arena_map <id>`. `arena_maps` lists them with their authors. `ArenaMaps.supports_mode` keeps siege, king of the hill, capture the flag and every props mode off them (`needs_built_world`), because the monsters' navigation, the objective layout and the scattered props are built from a box list an imported map does not have; free-for-all, gun game and the weapon pools play. An imported map's spawns are untagged, so the team modes are refused by the existing rule.

**What it found.**

- **`DotFpsFlatBody.rest_contact` pushes a player out of a box along its deepest axis**, where its own comment says the smallest. Widening `NET_WORLD_EXTENT` moved the quantisation step, one flush-to-the-wall position in `headless_net` rounded 6 mm into dm_atrium's north wall instead of out of it, and the client's predicted player slid 2.8 m along the wall during a launch the server made straight up (0.42 m before). The fix went into the addon (dot-player-controller 308c0d7, tagged v0.1.5, in shell 20261009-1627) and arena's override copy `maps/arena_flat_body.gd` was deleted on 2026-10-09, so **arena must not be published onto a shell older than 20261009-1627** or the 2.8 m slide comes back for browsers.
- **An offline player never faced the way a spawn faced.** `DotFpsController.teleport` turns the controller's own sampler and the client samples with its own, so every spawn's yaw was overwritten by the next command and an offline player always looked along -Z: on dm_box a room, on a surf map the spawn room's back wall three metres away, which is what the first rendered frame showed. The client turns its sampler on the player's `spawned`. A connected client's respawn is the server's and still keeps the look the mouse left; not done.

**Checked.** `headless_imported` (nine sections, 41 checks, about five seconds): the catalogue, the rotation and the mode filter; the game loads `surf_10x_reloaded_fixed` with 608 brush shapes in the tree and the physics backends bound; six bots appear on the mapper's spawns, grounded, with floor under their feet; a free-for-all is played to a score limit of four with nobody leaving the bounds, falling through or ending up inside a brush; the surf air control on, off on dm_box with the solid gone, back on, and both cvars; a ramp face steeper than `max_slope_angle` is ridden for a second without one grounded tick, gaining speed; a pit sends a player to its destination and the floor under the map catches; a shot out of a spawn room hits walls and the floor; and a sweep that every one of the ten builds a solid and puts its (settled) spawns on a floor clear of solid. `headless_net` follows a client onto the same map over the lossy wire (seven checks): the client builds its own solid, predicts with the surf profile, follows a respawn 195 m out (armed at the old extent: 66 m apart), and predicts a jump on it within 0.09 m. Armed in all: the volumes call removed (two checks), the settle removed (two), the physics body swapped for the empty flat one (five), the movement reset removed (one), the extent put back (two), the flat-body override removed (`headless_net`'s launch, 2.80 m).

**Rendered.** `tools/screenshot.sh <imported map id>` plays 160 ticks of a deathmatch on it first (three bots standing on their spawns, two walking off onto the ramps) and writes `<id>_players` (over a standing player's shoulder at the nearest other one), `_eye`, `_spawns`, `_overview` and `_ramp`, with the sky below the horizon so a map floating in it does not read as standing on a plain. Looked at on `surf_10x_reloaded_fixed`, `surf_110b_austinpowers`, `surf_grave_reloaded` and `surf_fruits`: players stand on the spawn floors at the right size against the doorways and the 1.22 m grid, the maps' own textures (posters, signs) and lightmaps draw, the ramps read as ramps. `~/stack/game-dev/tools/screenshot.sh game-arena out.png --wait 26 -- --offline --map surf_10x_reloaded_fixed` is the real offline client with its HUD, which is how the spawn-facing bug above was found.

**Not done.**

- **Delivery.** Locally the maps are the link; a delivered arena pack does not contain them (the link is gitignored) and arena has no fetch. The way is g2gfast's: each map is its own signed pack `gamemann/<id>`, listed under the game's `maps:` in `game.yml` with the installer pinning versions, fetched through dot-cloud on a map change on server and client (`G2GGame.ensure_map_content` / `_mark_delivered` is the reference), with `ArenaImportedMaps` given the mount directory as a root. Release steps before that can work: the ten maps published by a g2gfast-maps tag (their zones notes say "Not published"), each author's permission for redistribution confirmed (g2gfast's rule for shipping extracted geometry), then arena's `ensure` path and its `maps:` list, then an arena tag. A dedicated server running from source with the link plays them today (`-- --map surf_10x_reloaded_fixed`, or `arena_map`).
- ~~**The map's mechanics.**~~ — done 2026-10-09; see the next section.
- **The hull is the arena's 1.8 m**, not the genre's 72 units (1.37 m), because the hitboxes and the avatars are built for it. Every spawn room and doorway the renders and the suite reached fits it; a 72-unit vent somewhere would not.
- ~~A connected client's respawn yaw~~ — done 2026-10-09: `ArenaClient._face_a_respawn` turns this client's own sampler to the nearest map spawn's yaw when its player is seen dead and then alive (the server's teleport turns only the server's controller, and its next command carries the client's old look). Pits are deliberately not turned there, because they run inside prediction replays. `headless_presentation`'s respawn section (2 checks, armed).

## The combat surf maps' own mechanics (2026-10-09)

Pushes and boosters, water, ladders, conveyors, gravity volumes and hurt volumes from each imported map's manifest `mechanics` block now run here. Across the ten maps: pushes on 9, water on all 10, ladders on 7, conveyors on 4, gravity on 1, hurt on 4, sinking blocks on none.

**Two copies of g2gfast's files, preloaded by path, no `class_name`**, for the loader's reason (a game cannot name another game's script, a delivered pack cannot resolve a `class_name`): `maps/arena_map_mechanics.gd` (from `G2GMapMechanics`) and `maps/arena_ladder_mode.gd` (from `G2GLadderMode`), in metres through `ArenaBspMap.METRES_PER_UNIT`. `ArenaMap.imported` reads the block into `ArenaMap.mechanics`, which is null on a built-in map, and that null is how every caller knows there is nothing to run.

**Inside the simulated tick, on both ends.** `ArenaPlayer.simulate_tick` runs `_run_map_mechanics` after the controller's move and before `_follow_map_volumes` (the pits), on the server and in the owning client's prediction alike, from the map each end loaded. Order: pushes, then gravity or a conveyor, then the ladder, then the water (a ladder wins over water, g2gfast's finding on a climb-out pit), then the pits. The node is moved after a push, as the controller's own publish moves it, so the muzzle and the hitboxes follow.

**The swim and ladder modes are registered on every player on every map**, server and client, in that order (`controller.extra_modes = [swim, ladder]`), because a mode's id travels in the state's flags and a client that registered them only on a map with water would read a swimmer's mode as something else. With no volumes neither is ever entered and `_run_map_mechanics` returns at once, so a built-in map moves exactly as before: every built-in suite passes with the same counts. The water is the genre's (200 u/s, a 60 u/s idle sink, so a pit full of water is climbed out of by holding jump), with the waist and float depth taken as the genre's proportions of the arena's 1.8 m hull.

**Decisions that differ from g2gfast, on purpose:**

- **Pushes are stateless.** g2gfast remembers which pushes held a player in a history keyed by `DotFpsState.tick`, which is not replicated: after a rewind a client's copy keeps counting from its newest tick, so a history keyed by it is read at the wrong tick on a replay. Here "was this player in it last tick" is asked of the hull where the tick STARTED, which a rewind restores. That alone missed nearly every exit, because a floor booster's own displacement carries the player off its end and the next tick starts outside; so a push that displaces a player out of its box hands its velocity over on that same tick (armed: the booster threw at 5.5 m/s instead of 47.6). Worth checking whether g2gfast's history mispredicts a booster on a connected client (not edited here: another session holds game-g2gfast).
- **The ladder's jump-off grace counts the game's tick** (`ArenaLadderMode.now`, written by the player each tick), not `DotFpsState.tick`, for the same reason.
- **Hurt is real damage.** g2gfast treats 100 or more as a death and ignores the rest, because a timer run has no health. Arena has health, so `ArenaGame._hurt_from_map` deals each volume as the engine these maps come from does: `damage` is per second, dealt every half second (`ArenaMapMechanics.HURT_INTERVAL`), the first pulse on entering. It goes through `DotCombatManager.apply_damage` as attacker 0 with the `world` type, so the resolver, spawn protection, the kill feed (killer "", the world), the scoreboard and the stats hear it like a fall. A negative amount heals, as it does there. On the authority only, after the shots and before the match ticks, so a hurt death is counted by this tick's win check. Not predicted: health is the server's and replicates, and the movement half is already predicted.
- **Sinking blocks are not ported.** None of the ten maps has one, and the mechanic is a timer map's: a per-player delay ending in a teleport the game performs, a second event path into the match for a map that does not exist. `ArenaMapMechanics.blocks_skipped` counts them, so a map that gains one says so in its `describe()` rather than standing still in silence.

**What the maps are like.** Most of these maps' water is a sheet a few centimetres deep lying over a pit, and most hurt volumes sit over a teleport (on `surf_fruits` all but one), so a player is sent away before a second pulse; the checks look for the deep pool and the pit-free volumes rather than taking the first. Water the map shipped no texture for (all of it, on the held maps) is drawn with `maps/arena_bsp_water.gdshader` since 2026-10-09: translucent, both sides, a slow ripple in world metres, the map's measured colour when it is not grey. Before that it was the opaque grid and a swimmer in a render stood in an empty pool. `headless_imported` asserts one water material per such surface on the drawn level (armed).

**Checked.** `headless_imported` gained two sections (53 checks over eleven, from 41 over nine): on `surf_10x_reloaded_fixed`, the mechanics are read, a 47.6 m/s floor booster throws a player at 47.6 m/s, a player put in water to the chest swims, sinks at 1.14 m/s, and comes up out of it holding jump, and a ladder is climbed 5.2 m in a second with 63 ticks on it; on `surf_xiv_v2a`, a 100-a-second volume takes 50 at once through dot-combat as world damage, the next 50 lands half a second later and not a tick sooner (and kills, which the kill feed reports as the world's), and a -5 volume heals 2.5. `headless_net` gained two checks in the imported-map window (192, from 190): a booster carries the server's player 35.6 m, and the client predicts it tick for tick, 0.017 m against the server's same tick. That check compares against the server's next tick because this lockstep harness has the client one tick ahead, which at 47 m/s is 0.74 m by itself (the jump check's 0.09 m is the same tick at a jump's speed). **Armed**, each fired and was put back: pushes off (the booster check), the displaced-out hand-over off (the booster, 5.5 m/s), the swim update removed (three water checks), the ladder update removed (the climb, 0 ticks on), `_hurt_from_map` not called (four hurt checks), the pulse every tick (the half-second check), the heal skipped (the heal check), and the client's prediction run without the mechanics (`headless_net`'s booster, 5.95 m from the server).

**Rendered.** `tools/screenshot.sh <imported map>` now also writes `<id>_water` (a bot put in the map's deepest pool and left to sink) and `<id>_booster` (a bot put on its strongest floor booster, thrown off the end). Looked at on `surf_10x_reloaded_fixed`: the swimmer is in the pool 1.44 m under its surface in swim mode, and the rider is in the air past the end of the booster at 47.6 m/s; the existing frames are unchanged.

## Real loss: `headless_lossy` (2026-10-09, `dual-stack-follow-1`)

**It is not in `./game.sh test`, because it is not deterministic** -- though since 2026-10-09 (dot-core's ENet peer timeouts, five input copies, a 35 s drain that is ENet's own contract) it passed 19 and 20 of 20. The relay's drops are seeded but its thread and the engine's timing are not, and over twelve runs on 2026-10-09 (after dot-core's bandwidth fix, port sharing on and off) about one in four failed, each differently: a 2.04 m prediction error at 5% loss (twice, with the UDP port shared through the demux), a 1,018 ms freeze of B on A's screen at 20%, and at 20% the last 17 numbered notices and 4 kills not arriving inside the window (reliable traffic stalled, not lost). Those are real behaviours under heavy loss and are queued as `lossy-stalls-1`; the suite is the tool to chase them, run by name: `./game.sh test headless_lossy`.

Servers listen on ENet as well as WebSocket now, and over WebSocket "unreliable" is TCP: nothing here had ever had a datagram arrive late, out of order, twice or not at all, or a reliable message retransmitted. `headless_net`'s loss is its own loopback dropping one in five, in order and instantly. `examples/headless_lossy` puts dot-net's lossy UDP relay (`res://addons/dot_net/testing/dot_net_udp_relay.gd`, by path; see dot-net's CLAUDE.md) between a real `DotClientLink` on ENet and a real dual-stack `DotServer` running `ArenaModule`, and plays. Client **A** goes through the relay and is measured: it runs, strafes and turns every tick. Client **B** connects straight to the server and runs a circle, the smooth reference A's drawing is held to. A dummy the server seats is slain every 1.2 s for the kill feed. Each end has its own `MultiplayerAPI` (`SceneTree.set_multiplayer`), so one process holds all three.

It measures A's first three seconds on their own, then three windows: a steady 55 ms each way, and 5% and 20% loss each way with 30..80 ms of delay (uniform, so packets reorder), 16 checks each: still connected; the relay injected the loss; A's clock error settled within 3 ticks with no snaps; the share of the server's ticks that had A's command; that A drew B every frame, never froze more than 100 ms while B moved, never jumped more than 0.5 m past B's own motion, was within 10 cm of where the server had B at that render time for 95% of frames, that the render timeline went back at most twice by a tick at most, and at most a quarter of frames extrapolated; A's prediction against the server's A tick for tick; `DotNetStats.loss_rate()` against the relay's measured loss; and every numbered notice, kill and chat line (down, and A's own up and back) exactly once and in order; then a leave. `--verbose` prints the diagnostics every finding below was made with.

**Measured, three runs, 2026-10-09** (64 ticks, 32 snapshots; ENet round trip 121-136 ms):

| | steady 55 ms | 5%, 30..80 ms | 20%, 30..80 ms |
| --- | --- | --- | --- |
| A connected throughout | yes | yes | yes |
| clock error once settled | 0 ticks | +-1 | +-1 |
| real input lead (needed ~5) | 7 ticks | 8-9 | 8-9 |
| server ticks with A's command | 100% | 98.3-100% | 98.6-99.9% |
| A's prediction vs server, p95 / max | 7 mm / 8 mm | 8 mm / 11 mm | 8-9 mm / 0.15-0.30 m |
| replays that corrected | 0.5-1% | 0.4-1.1% | 0.8-1.7% |
| B drawn vs server at render time, p95 / max | 5 mm / 0.12-0.18 m | 8-9 mm / 0.03-0.04 m | 11 mm / 0.05-0.19 m |
| longest freeze / largest jump | 0 / 0.05-0.10 m | 15-33 ms / 0.03-0.04 m | 14-45 ms / 0.04-0.17 m |
| frames extrapolated | 0% | 11-13% | 12% |
| render timeline steps back | 0 | 0-1 (0.02 tick) | 0 |
| `loss_rate()` vs injected | 0.000 / 0.000 | 0.06-0.07 / 0.05 | 0.17-0.20 / 0.21 |
| notices, kills, chat down, A's chat | 24, 5, 15, 2 | 40, 8, 25, 3 | 40, 8, 25, 3 |

and in A's first three seconds the server had its command for 100% of 192 ticks.

**What it found, in the order it was found, every one armed:**

- **`DotNetStats` reported half of every clean link lost** (dot-net #22): it counted ticks, and arena snapshots every second tick. 0.55 against 0.04 injected, 0.60 against 0.21, 0.50 against nothing.
- **No input was ever resent** (dot-net #25): every lost input packet was a tick the server ran on the previous command, with the view turning every tick. `ArenaNetBridge.encode_input` sends this tick's command and the two before it (`INPUT_COPIES`), and `receive_input` skips the copies already simulated so they do not count as late. Armed (`INPUT_COPIES := 1`): the server had A's command for 80.0% of its ticks at 20% loss and 94.4% at 5%, and corrected him on 9% of snapshots. `inputs_from` (per peer, in `describe()`) is what told one client's uplink from the other's.
- **The clock's round trip came from a two-second heartbeat that is -1 until it first answers** -- eight seconds after connecting, once. Until then the clock left the flight time out of its input lead and the commands arrived after their ticks. `ArenaNetBridge.link_rtt_ms(link)` reads ENet's own round trip (by duck typing; a web build has no ENet class) and falls back to `ping_ms`; `ArenaClient` uses it. Armed (`--ping-rtt`): 45.9% of A's first three seconds in time, 102 commands late.
- **The render timeline went backwards with every late packet, and the interpolation delay had the flight time taken out of it** (dot-net #23 and #24). Armed: 38-48 steps back per window by up to 3 ticks; 93-100% of frames extrapolated and B drawn 0.65 m from where the server had him.
- **A Godot engine bug made every native client drop its commands at connect, and the fix belongs in dot-core.** `ENetMultiplayerPeer.create_server` passes its `max_channels` argument to ENet as the host's incoming bandwidth (`modules/enet/enet_multiplayer_peer.cpp`: `create_host_bound(bind_ip, port, max_clients, 0, max_channels + SYSCH_MAX, out_bandwidth)`; checked in the 4.8-dev source, and measured on 4.7.2). dot-core's `DotTransportENet` passes its four channels, so every dot-server tells every ENet client it can take **six bytes a second**. The client's ENet believes it: its bandwidth throttle caps the packet throttle at 1/32 and drops 31 of every 32 unreliable packets -- the commands -- until the server's first bandwidth pass corrects it, and then the RTT throttle climbs back 2/32 at a time; measured, 1/32 for about two seconds and not back to 32 for up to twenty. Reliable traffic is slowed with it: at 20% loss some notices and chat lines took more than three seconds to arrive (none was lost, and all were in within six). **The fix, for DotTransportENet `_create_server`: pass 0 as the channel count.** The same engine call always passes 0 as ENet's channel limit, so the channels a client asks for are granted either way and the only thing it changes is the bandwidth (0, unlimited). **Fixed in dot-core 2026-10-09** (`dual_transport_selftest`'s throttle section, armed: the old call drops the client's throttle limit to 1 and 110 of 247 packets arrive), so the harness now runs on dot-core's own transport; before the fix, with dot-core's call, the measurement was: 17-20% of A's first three seconds in time and 61-85% of the steady window, and A's prediction corrected on up to 18% of snapshots. A `throttle_configure` on the client does not help -- the cap is the bandwidth limit, not the RTT throttle -- and on a peer that is still connecting it stops the connect completing.

**What is left, not fixed:**

- ~~Lag compensation never rewinds in this game.~~ **Fixed 2026-10-09:** each command carries the client's view lag (`ArenaNetCommand.view_lag_q`, quarter ticks, only with a button down: input tick minus the receive timeline less the interpolation delay), the server records every player's position per tick (`ArenaGame._unlag_record`, a ring of 128, restarted on a jump over 10 m in a tick) and dot-combat's `rewind_fn` stands every other living player where the shooter drew them for the trace, then puts them back. `arena_max_unlag_ms` (500; 0 off) is the limit. `headless_match`'s *lag compensation* (7 checks: a shot where B was 12 ticks ago hits, the same against the present misses, 0 and a 50 ms limit rewind nothing) and `headless_net` (the field on the wire, and the server rewound for real clients' shots; armed).
- The ten other games' bridges send one command per input packet and feed the clock `ping_ms`; each wants `DotNetInput.write_batch` and its own `link_rtt_ms`.
- ~~dot-server's `SCOREBOARD` kept whichever arrived last~~: it carries a `seq` the client checks since 2026-10-09 (dot-server). Every other unreliable message in the family is order-free (dot-net's CLAUDE.md has the audit).
- The input lead runs 2-4 ticks over what the transit needs (dot-net's clock has no jitter source on ENet; the arrival filter covers it by leaning early), and 12% of frames extrapolate at 5-20% loss because the interpolation buffer adapts to jitter, not to loss.


## The scoreboard is dot-menu's (2026-10-09)

`ArenaMenus.ScoreboardScreen` draws a `DotMenuScoreboard`, the family's Tab board, rather than its own `DotTableView`. The columns are this game's (K, D, A, Score, then the board's own Time and Ping), the rows come from dot-match's scoreboard sorted by match rank, and on a connected client the server's roster (`DotClientLink.want_scoreboard`, sent only while Tab is held) is merged in by player key for the connected time and the ping. A team mode groups the rows under `DotTeamManager`'s sides; a free-for-all draws one list. `follow(key)` highlights the local player once the client adopts it. Offline, Time and Ping read "-", because there is no server to have measured them. Rendered with `tools/screenshot_menus.sh` and looked at.
