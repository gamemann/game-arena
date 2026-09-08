# game-arena

The reference game. Read `../../CLAUDE.md` first for the family-wide rules; this file
is what is specific to using them together.

## Why this project exists

Nine addons each pass their own suite, and **every one of those suites runs one addon
with the others absent**. dot-platform makes the point in its own notes and it is the
lesson of every bug this family has found: *a code path only one deployment shape
reaches is a code path nothing has run.*

game-arena is the deployment shape where dot-fps-controller, dot-combat, dot-loadout,
dot-match and dot-ui are all present at once. It is a game, and it is also the only
test of the joins between them.

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
| game → server | `ArenaModule`, the only file that names dot-server |

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
smoothing will fix that". Found from `dot-2d-hungry`, whose bridge was written from this
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
`dot-2d-hungry`'s `sandbox` now runs it with a game's own RPCs on top. Repeating it here
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
cd godot/game-arena
for pair in dot_core:dot-core dot_net:dot-net dot_server:dot-server \
            dot_fps_controller:dot-fps-controller dot_combat:dot-combat \
            dot_loadout:dot-loadout dot_match:dot-match dot_ui:dot-ui; do
  ln -s "../../${pair##*:}/addons/${pair%%:*}" "addons/${pair%%:*}"
done

godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/headless_match.tscn
godot --headless --path . res://examples/headless_net.tscn
godot --headless --path . res://examples/dedicated.tscn
```

75 + 62 + 21 checks.

**Re-run `--import` after adding any script with a new `class_name`.** Without it the
identifier does not resolve, the scene fails to load, and the process *hangs* rather
than exiting — nothing reaches `get_tree().quit()`. That happened while writing this
and cost two timed-out runs before the log was read.

**Run both examples after changing any dot-* addon.** That is what this project is for.

## Things deliberately not here

- **Netcode over a real socket.** `ArenaNetBridge` exists and `headless_net` runs it over
  a loopback, but nothing here opens a socket or wires the bridge into `ArenaModule` —
  the dedicated server still ticks `ArenaGame` directly. `dot-2d-hungry` does the whole
  thing, `HungryModule` included, and is what this would copy from.
- **Projectiles.** The rocket launcher is declared as `Delivery.PROJECTILE` and
  dot-combat records the launch vector without spawning anything. A projectile is a
  replicated entity with a lifetime; the bridge now exists to give it one.
- **Pickups in the world.** dot-loadout ships `DotPickup` and `DotPickupField`; the map
  places none. An arena with weapon and armour pickups is most of what makes map
  control matter, and it is a level-design decision rather than a wiring one.
- **A real client.** No camera rig, no viewmodel, no sound, no input sampling into
  `ArenaGame`. `DotFpsSampler` is the seam; there is no scene a person can play yet.
  `dot-2d-hungry` has the 2D equivalent of all of it — launcher, camera, renderer, HUD,
  chat, touch — and is the shape this would take.
- **Bots worth the name.** `_commands_for_tick` aims at the nearest opponent and holds
  the trigger. It is a test fixture, not an opponent.
- **More than one map.** `ArenaMap.dm_box()` is the only level. A second one is a
  static function.
