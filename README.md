This is the **reference game** for TMC's **Dot** collection. If you want to see the assets working together before you commit to any of them, start here.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This project is built out of them, so it doubles as a worked example of what they look like in a real game rather than in a demo.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## The Reference Game
A 3D dev-textured arena deathmatch, built entirely out of the
[dot-*](https://github.com/modcommunity) family. Four weapons, one map, a match that ends on its score
limit, and a HUD and menus with no art assets anywhere.

**This is the reference game.** It exists to prove the addons compose, to show what the
bridges between them look like, and to be the thing a new game is copied from.

## Running it

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core          # and the other seven
godot --headless --path . res://examples/headless_match.tscn   # a whole deathmatch
godot --headless --path . res://examples/headless_net.tscn     # the netcode
godot --headless --path . res://examples/dedicated.tscn        # a real DotServer
```

Or, once [dot-serve](https://github.com/modcommunity/dot-serve) is installed:

```bash
dotserve --game res://examples/dedicated.tscn --name "My arena"
```

## What it is made of

| | |
| --- | --- |
| [dot-core](https://github.com/modcommunity/dot-core) | Everything shared. |
| [dot-fps-controller](https://github.com/modcommunity/dot-fps-controller) | Movement. Classic strafe acceleration, air-strafing, auto-hop. |
| [dot-combat](https://github.com/modcommunity/dot-combat) | Health, weapons, hit registration. |
| [dot-loadout](https://github.com/modcommunity/dot-loadout) | What you take in, and what you may take. |
| [dot-match](https://github.com/modcommunity/dot-match) | Rounds, scoring, spawning, respawning. |
| [dot-ui](https://github.com/modcommunity/dot-ui) | HUD, pause menu, settings, controls, scoreboard. |
| [dot-server](https://github.com/modcommunity/dot-server) | The dedicated server, through one module. |

## The four files that matter

**`maps/arena_map.gd`** — a level is a list of boxes, and that list becomes three
things: meshes, physics bodies, and analytic geometry for a headless server. Building
them separately means three descriptions that drift, and the drift is invisible until
shots start passing through something clients can see.

**`game/arena_player.gd`** — movement, weapons, health and hitboxes on one body. Every
addon says this wiring belongs in the game, because an addon that did it would dictate
a scene shape.

**`game/arena_game.gd`** — the seam. Six addons, each correct alone; this is the fifty
lines where a combat kill becomes a match score and a match respawn becomes a loadout.

**`game/arena_module.gd`** — the only file that names dot-server. About forty lines,
and it is the entire dedicated-server integration.

## The weapons

Four, because they are four genuinely different answers to "how do I close distance",
and a deathmatch with fewer has one right answer.

| | |
| --- | --- |
| **Pistol** | Never runs out, always loses a fair fight. Which is what makes picking something up worth doing. |
| **Rifle** | Wins at range, loses in a corridor. Bloom punishes holding the trigger. |
| **Shotgun** | Nine pellets in a *learnable* ring, so range is a skill rather than a dice roll. |
| **Rocket Launcher** | Low direct damage, high splash. The interesting part is what it does to the floor — and to your own feet. |

Loadouts are two weapons on a six-point budget: a rifle and a shotgun, or a rocket
launcher and a pistol, and not a rocket launcher and a shotgun. Four numbers instead of
an enumeration.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/headless_match.tscn
godot --headless --path . res://examples/headless_net.tscn
godot --headless --path . res://examples/dedicated.tscn
```

`headless_match` — 75 checks. Plays an entire deathmatch: four bots, real movement,
real shots, real kills, real respawns, ending on the score limit. Then builds the HUD
and the menus and drives them.

`headless_net` — 62 checks. Runs a server and a client in one process over a loopback
that drops packets: the wire round-trips, a spawn is mirrored, movement replicates, the
client moves on the tick it presses, and the two stay together under loss.

`dedicated` — 21 checks. Boots a real `DotServer`, binds a port, loads the module,
runs its console commands, unloads it and loads it again.
