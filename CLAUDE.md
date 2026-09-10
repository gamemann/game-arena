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
the fight        dot-fps-controller  dot-combat  dot-loadout  dot-match
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
None of it is dot-fps-controller's default — the addon ships numbers that feel like a
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
of dot-fps-controller's own note on it: *it gives the same answer on a client replaying
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

`dot-server-setup-test` vendors it — `setup.sh` copies `game/`, `scenes/*.tscn` and
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

**A monster's combat entity id is its instance id plus `ArenaHorde.ENTITY_BASE`.**
`ArenaPlayer` uses the dot-server session id as its entity id, which is a small integer;
a monster using its own would eventually collide with one, and the symptom of that
collision is a shot at a monster killing a player. That is the fourth id space in this
project and the only one that is not the player id, which is why it is a constant.

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

**Voice has its own channel on the link.** A talk spurt is fifty frames a second per
speaker relayed to every listener; on the state channel it would sit in the same ordered
queue as the snapshots, so somebody holding the talk key would add a frame of latency to
everybody's movement. The speaker id is stamped from the transport's sender and never
read out of the payload — a client that could name its own could put words in anybody's
mouth, and the only symptom is words coming out of the wrong player.

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

## Validating changes

```bash
# The eight addon links, from this project's own .gitignore. Do not hand-make them.
godot/bootstrap/bootstrap.sh --links

cd godot/game-arena
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/headless_match.tscn
godot --headless --path . res://examples/headless_net.tscn
godot --headless --path . res://examples/dedicated.tscn
```

186 + 116 + 65 checks.

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

## Things deliberately not here

- **Projectiles.** The rocket launcher is declared as `Delivery.PROJECTILE` and
  dot-combat records the launch vector without spawning anything. A projectile is a
  replicated entity with a lifetime; the bridge now exists to give it one.
- **Pickups in the world.** dot-loadout ships `DotPickup` and `DotPickupField`; the map
  places none. An arena with weapon and armour pickups is most of what makes map
  control matter, and it is a level-design decision rather than a wiring one.
- **Sound, and a viewmodel.** `ArenaClient` has the camera rig, the input sampling, the
  renderer, the HUD and the menus. It has no audio whatsoever — nothing in `game/` names
  an `AudioStream` — and nothing is drawn for the weapon in your own hands, so the only
  feedback a shot gives is the crosshair and the ammunition counter. `game-hungario`
  generates its sound rather than shipping any, and is the shape this would take.
- **Bots worth the name.** `_commands_for_tick` aims at the nearest opponent and holds
  the trigger. It is a test fixture, not an opponent.
- **A chat window.** `DotChatClient` holds the history, the channels and the unread
  counts on the client the moment anybody writes one; what the player gets today is
  the HUD's notice line. A scrolling window with an input field is a `DotScreen`, and
  nobody has written it.
- **A server browser screen.** dot-browser's client half — sources, filters,
  favourites, history — is not wired into `ArenaClient`. The *server* half is:
  `ArenaModule` contributes a query provider so a browser has something to read, and
  `dedicated` asserts what it says. Nothing has yet asked a real `DotServer` for it.
- **A viewmodel, and sound.** `ArenaClient` has the camera rig, the input sampling, the
  renderer, the HUD and the menus. It has no audio whatsoever beyond voice chat, and
  nothing is drawn for the weapon in your own hands.
