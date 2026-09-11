class_name ArenaContent
extends RefCounted

## Every weapon, item, damage type and ruleset the game ships, built in code.
##
## [b]In code rather than as `.tres` files, deliberately, and only for this
## project.[/b] A real game ships resources an artist edits without touching code, and
## every class these build is `@tool`-annotated and inspector-editable for exactly
## that. What a *reference* game wants is the opposite: one file you can read top to
## bottom and see the whole content set, with the reasoning next to the numbers.
##
## The weapon set is the classic four. Not for nostalgia — they are four genuinely
## different answers to "how do I close distance", and a deathmatch with fewer than
## that is a deathmatch with one right answer.

const DAMAGE_BULLET := &"bullet"
const DAMAGE_BLAST := &"blast"
const DAMAGE_FALL := &"fall"
const DAMAGE_WORLD := &"world"

const AMMO_RIFLE := &"rifle_ammo"
const AMMO_SHELL := &"shells"
const AMMO_ROCKET := &"rockets"


# --- Damage types ----------------------------------------------------------

static func bullet() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_BULLET, "Bullet")
	type.armour_share = 0.5
	type.armour_wear = 1.0
	# Falloff starts well beyond a duel and ends beyond the map's diagonal, so it
	# punishes cross-map plinking without making a mid-range fight feel weak.
	type.falloff_start = 24.0
	type.falloff_end = 60.0
	type.falloff_floor = 0.55
	type.self_scale = 0.0
	return type


static func blast() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_BLAST, "Explosion")
	type.armour_share = 0.75
	type.armour_wear = 1.5
	# Hit groups off: a rocket at someone's feet must not do head damage because the
	# splash sphere happened to touch a head hitbox first.
	type.uses_hit_groups = false
	# Rocket jumping. Half damage to yourself is the number every game that has this
	# arrived at independently.
	type.self_scale = 0.5
	type.knockback_per_point = 0.35
	return type


static func fall() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_FALL, "Fall")
	# Armour does not soften a landing, and a fall has no hit group.
	type.armour_share = 0.0
	type.uses_hit_groups = false
	type.self_scale = 1.0
	return type


static func world() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_WORLD, "The world")
	type.armour_share = 0.0
	type.uses_hit_groups = false
	return type


static func damage_types() -> Array[DotDamageType]:
	return [bullet(), blast(), fall(), world()]


# --- Weapons ---------------------------------------------------------------
#
# A weapon is a DotWeaponDef naming a behaviour script by path, plus a
# DotWeaponBallistics carrying the numbers that behaviour reads. Until dot-weapon
# existed these were one fat DotWeapon resource with every gun field on it; the split
# is what lets this game add a bow, a grappling hook or a mine layer later without
# either editing an addon or pretending the new thing is a gun.
#
# Every duration is in ticks. Seconds would make the pistol fire at two different
# rates on a 64 Hz server and a 128 Hz one, which is two different games.

const TICK_RATE := 64

const HITSCAN := "res://addons/dot_weapon/behaviour/dot_weapon_hitscan.gd"
const PROJECTILE := "res://addons/dot_weapon/behaviour/dot_weapon_projectile.gd"


## Ticks between shots for a weapon quoted in rounds per minute.
##
## Rounds per minute is what a designer tunes in and ticks are what the simulation
## runs on, so the conversion lives here once rather than in four hand-computed
## numbers that drift the first time somebody changes the tick rate.
static func rpm_ticks(rpm: float) -> int:
	return maxi(1, int(round(60.0 / rpm * float(TICK_RATE))))


static func sec_ticks(seconds: float) -> int:
	return maxi(0, int(round(seconds * float(TICK_RATE))))


## The starting weapon. Always available, never runs out, and always loses a fair
## fight — which is what makes picking something up worth doing.
static func pistol() -> DotWeaponDef:
	var def := DotWeaponDef.new()
	def.id = &"pistol"
	def.display_name = "Pistol"
	def.behaviour_path = HITSCAN
	def.slot = 1
	def.fire_mode = DotWeaponDef.Fire.SEMI
	def.use_interval_ticks = rpm_ticks(380.0)
	def.magazine = 0
	def.infinite_reserve = true
	def.cost_per_use = 0
	def.deploy_ticks = sec_ticks(0.2)
	def.holster_ticks = sec_ticks(0.15)

	var b := DotWeaponBallistics.new()
	b.damage = 18.0
	b.damage_type = bullet()
	b.spread = 0.4
	b.spread_moving = 1.6
	b.bloom = 0.35
	b.bloom_max = 3.0
	b.recoil_pitch = 0.5
	b.max_range = 120.0
	def.tuning = b
	return def


## The all-rounder. Wins at range, loses in a corridor.
static func rifle() -> DotWeaponDef:
	var def := DotWeaponDef.new()
	def.id = &"rifle"
	def.display_name = "Rifle"
	def.behaviour_path = HITSCAN
	def.slot = 2
	def.fire_mode = DotWeaponDef.Fire.AUTO
	def.use_interval_ticks = rpm_ticks(620.0)
	def.magazine = 30
	def.reserve = 90
	def.reserve_max = 180
	def.ammo_type = AMMO_RIFLE
	def.reload_ticks = sec_ticks(2.1)
	def.deploy_ticks = sec_ticks(0.3)
	def.holster_ticks = sec_ticks(0.2)

	var b := DotWeaponBallistics.new()
	b.damage = 22.0
	b.damage_type = bullet()
	b.spread = 0.5
	b.spread_moving = 2.2
	b.spread_airborne = 4.5
	b.spread_crouched = 0.55
	b.bloom = 0.28
	b.bloom_max = 4.5
	b.bloom_recovery = 9.0 / float(TICK_RATE)
	b.recoil_pitch = 0.35
	b.recoil_yaw = 0.14
	b.max_range = 200.0
	def.tuning = b
	return def


## The corridor answer. Nine pellets in a learnable ring, so range is a skill rather
## than a dice roll.
static func shotgun() -> DotWeaponDef:
	var def := DotWeaponDef.new()
	def.id = &"shotgun"
	def.display_name = "Shotgun"
	def.behaviour_path = HITSCAN
	def.slot = 3
	def.fire_mode = DotWeaponDef.Fire.SEMI
	def.use_interval_ticks = rpm_ticks(75.0)
	def.magazine = 6
	def.reserve = 24
	def.reserve_max = 48
	def.ammo_type = AMMO_SHELL
	def.reload_per_round = true
	def.reload_ticks = sec_ticks(0.45)
	def.reload_start_ticks = sec_ticks(0.3)
	def.deploy_ticks = sec_ticks(0.35)
	def.holster_ticks = sec_ticks(0.25)

	var b := DotWeaponBallistics.new()
	b.damage = 11.0
	b.damage_type = bullet()
	b.pellets = 9
	b.fixed_pattern = true
	b.spread = 4.5
	b.spread_moving = 0.5
	b.recoil_pitch = 2.2
	# Well short of the map's diagonal, so a shotgun across the arena does nothing
	# rather than doing a little — which is a clearer rule to play against.
	b.max_range = 24.0
	def.tuning = b
	return def


## Area denial, mobility, and the reason the raised middle is worth holding.
##
## Direct damage is deliberately low and the splash is deliberately high: a rocket that
## kills on a direct hit is a hitscan weapon with travel time, and the interesting part
## of a rocket launcher is what it does to the floor.
static func rocket_launcher() -> DotWeaponDef:
	var def := DotWeaponDef.new()
	def.id = &"rocket"
	def.display_name = "Rocket Launcher"
	def.behaviour_path = PROJECTILE
	def.slot = 4
	def.fire_mode = DotWeaponDef.Fire.SEMI
	def.use_interval_ticks = rpm_ticks(70.0)
	def.magazine = 4
	def.reserve = 12
	def.reserve_max = 20
	def.ammo_type = AMMO_ROCKET
	def.reload_ticks = sec_ticks(2.6)
	def.deploy_ticks = sec_ticks(0.45)
	def.holster_ticks = sec_ticks(0.3)

	var b := DotWeaponBallistics.new()
	b.damage = 30.0
	b.damage_type = blast()
	b.splash_type = blast()
	b.speed = 42.0
	# Not a charged weapon, so the minimum and the maximum are the same number: a
	# rocket launcher that fired slower rockets when tapped would be a different gun.
	b.min_speed = 42.0
	b.min_charge_damage = 1.0
	b.radius = 0.2
	b.life_ticks = sec_ticks(5.0)
	b.splash_radius = 4.5
	b.splash_damage = 85.0
	b.splash_hurts_owner = true
	b.spread = 0.0
	b.spread_moving = 0.0
	b.spread_airborne = 0.0
	b.recoil_pitch = 3.0
	b.max_range = 220.0
	def.tuning = b
	return def


static func weapons() -> Array[DotWeaponDef]:
	return [pistol(), rifle(), shotgun(), rocket_launcher()]


## The whole weapon table, validated as one document.
##
## A server checks this at boot, headless, before anybody joins — which is the only
## moment anybody is watching.
static func weapon_catalogue() -> DotWeaponCatalogue:
	var catalogue := DotWeaponCatalogue.new()
	for def in weapons():
		catalogue.add(def)
	return catalogue


## Weapons by id, for a module that has an item id and needs the weapon.
static func weapon_table() -> Dictionary:
	var table := {}
	for def in weapons():
		table[def.id] = def
	return table


# --- Loadout ---------------------------------------------------------------

## The items a loadout can name. One per weapon, plus armour.
##
## Note that the item ids match the weapon ids. That is a convention this game chose,
## not something dot-loadout requires — it is what makes `weapon_table()[item.id]` the
## whole of the mapping, and dot-loadout's `arsenal_slot` hint the whole of the rest.
static func catalogue() -> DotItemCatalogue:
	var items: Array[DotItem] = []

	for weapon in weapons():
		var item := DotItem.make(weapon.id, DotItem.KIND_WEAPON, weapon.id != &"rocket")
		item.display_name = weapon.display_name
		# No slot restriction on the item: the schema's `kinds` decides that a weapon
		# slot takes weapons, and the points budget decides which combination is
		# legal. Locking each weapon to one slot instead would mean four slots, and a
		# player carrying a shotgun could never also carry a rifle.
		item.cost = weapon.slot
		items.append(item)

	var armour := DotItem.make(&"armour", DotItem.KIND_EQUIPMENT, true)
	armour.display_name = "Armour"
	armour.slots = [&"gear"]
	armour.cost = 2
	items.append(armour)

	return DotItemCatalogue.of(items)


## The loadout schema: two weapon slots and a gear slot, on a small points budget.
##
## Points rather than an explicit list of legal combinations, because "a rifle and a
## shotgun, or a rocket launcher and a pistol" is four numbers rather than an
## enumeration that grows as the square of the weapon count.
static func loadout_schema() -> DotLoadoutSchema:
	var primary := DotLoadoutSlot.make(&"primary", true, &"rifle")
	primary.display_name = "Primary"
	primary.kinds = [DotItem.KIND_WEAPON]
	primary.arsenal_slot = 2
	primary.order = 10

	var secondary := DotLoadoutSlot.make(&"secondary", true, &"pistol")
	secondary.display_name = "Sidearm"
	secondary.kinds = [DotItem.KIND_WEAPON]
	secondary.arsenal_slot = 1
	secondary.order = 20

	var gear := DotLoadoutSlot.make(&"gear")
	gear.display_name = "Gear"
	gear.kinds = [DotItem.KIND_EQUIPMENT]
	gear.order = 30

	var schema := DotLoadoutSchema.of(
		&"arena", [primary, secondary, gear], catalogue()
	)
	# Costs are 1/2/3/4 for pistol/rifle/shotgun/rocket. Six buys a rifle and a
	# shotgun, or a rocket launcher and a pistol, and not a rocket launcher and a
	# shotgun -- four numbers instead of an enumeration that grows as the square of
	# the weapon count.
	schema.point_budget = 6
	return schema
