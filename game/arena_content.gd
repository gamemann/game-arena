extends RefCounted

## Every weapon, item, damage type and ruleset the game ships, built in code.
##
## [b]In code rather than as `.tres` files, deliberately, and only for this
## project.[/b] A real game ships resources an artist edits without touching code, and
## every class these build is `@tool`-annotated and inspector-editable for exactly
## that. What a *reference* game wants is the opposite: one file you can read top to
## bottom and see the whole content set, with the reasoning next to the numbers.
##
## [b]The weapons are zee-dot-weapons', all twenty-seven, and none of them is defined
## here.[/b] This file used to carry four of its own — a pistol, a rifle, a shotgun and a
## rocket launcher — which drew nothing in anybody's hands, because dot-weapon refuses to
## draw and this game never filled that half in. The pack is that half, already tuned in
## ticks and validated as one document; what is left for the game is which of them a
## loadout may name and what each costs, which is below.

## A bullet: what the horde's gunner fires. Not a player weapon's type any more — the
## pack's darts are — but monsters still shoot bullets, so it stays registered.
const DAMAGE_BULLET := &"bullet"
## The pack's explosion type. One id with the pack, so a rocket and a grenade and a
## monster's death blast all answer to the same rule.
const DAMAGE_BLAST := ZeeWeaponIds.DAMAGE_BLAST
const DAMAGE_FALL := &"fall"
const DAMAGE_WORLD := &"world"


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


## Every damage type the game registers: its own three, and the pack's four.
##
## [b]Built once and shared[/b], and the reason is identity rather than speed. dot-combat
## registers the objects it is handed, and [method weapon_catalogue] hands the SAME objects
## to the pack, so a launcher's splash and the registered "blast" are one rule. Two copies
## built independently would agree today and drift the first time somebody tuned one.
static var _damage: Dictionary = {}


static func damage_table() -> Dictionary:
	if _damage.is_empty():
		_damage = ZeeWeaponDamage.table()
		_damage[DAMAGE_BULLET] = bullet()
		_damage[DAMAGE_FALL] = fall()
		_damage[DAMAGE_WORLD] = world()
	return _damage


static func damage_types() -> Array[DotDamageType]:
	var out: Array[DotDamageType] = []
	for type: DotDamageType in damage_table().values():
		out.append(type)
	return out


# --- Weapons ---------------------------------------------------------------
#
# Every duration is in ticks. Seconds would make the pistol fire at two different
# rates on a 64 Hz server and a 128 Hz one, which is two different games — the pack
# says the same and is tuned at this rate.

const TICK_RATE := 64

## What a player spawns with when nothing else says: a knife in the melee slot, so the
## number keys always have something under 1, a pistol and a rifle, and one frag.
##
## [b]A list of ids, not a second table of weapons.[/b] The pack is the only place a
## weapon is defined, and everything this game decides about one is which ids it hands
## out — so a mode that wants shotguns for everybody edits this and nothing else.
const DEFAULT_LOADOUT: Array[StringName] = [
	ZeeWeaponIds.KNIFE, ZeeWeaponIds.PISTOL, ZeeWeaponIds.RIFLE, ZeeWeaponIds.FRAG,
]

## The slot a fresh spawn is holding: the primary.
const DEFAULT_SLOT := ZeeWeaponIds.SLOT_PRIMARY


## The pack's weapons, against this game's damage types.
static func weapons() -> Array[DotWeaponDef]:
	return ZeeWeaponPack.weapons(damage_table())


## The whole weapon table, validated as one document.
##
## A server checks this at boot, headless, before anybody joins — which is the only
## moment anybody is watching.
static func weapon_catalogue() -> DotWeaponCatalogue:
	return ZeeWeaponPack.catalogue(damage_table())


## Weapons by id, for a module that has an item id and needs the weapon.
static func weapon_table() -> Dictionary:
	return ZeeWeaponPack.table(damage_table())


# --- On the wire -------------------------------------------------------------
#
# A weapon travels as its place in `ZeeWeaponIds.all()`, plus one, so nothing is 0. The
# same addon is compiled into both ends — the server and the client shell — so the list is
# the same list on both, and a number is five bits where a StringName would be a string.

## Bits a weapon index takes: room for the pack's twenty-seven and four more.
const WEAPON_INDEX_BITS := 5


## [param id]'s wire number, or 0 for nothing and for anything the pack does not define.
static func weapon_index(id: StringName) -> int:
	if id == &"":
		return 0
	return ZeeWeaponIds.all().find(id) + 1


## The weapon [param index] names, or `&""`.
static func weapon_at(index: int) -> StringName:
	var ids := ZeeWeaponIds.all()
	return ids[index - 1] if index >= 1 and index <= ids.size() else &""


## Bits the carried set takes: one per weapon in the pack.
static func carry_bits() -> int:
	return mini(ZeeWeaponIds.all().size(), 62)


## Everything [param arsenal] carries, one bit per weapon.
static func carry_mask(arsenal: DotWeaponArsenal) -> int:
	if arsenal == null:
		return 0

	var mask := 0
	var ids := ZeeWeaponIds.all()

	for i in range(mini(ids.size(), 62)):
		if arsenal.carries(ids[i]):
			mask |= 1 << i

	return mask


## Makes [param arsenal] carry exactly what [param mask] says. Returns how many weapons
## it gave or took.
##
## [b]What a client's arsenal is filled from, and it was filled from nothing.[/b] A
## loadout is resolved from a store on the server, and nothing sent its result, so a
## connected client's own arsenal was empty for the whole of every match: it predicted no
## shot, drew no flash, played no report, its HUD read zero and its number keys selected
## nothing — while the server, which had the weapons, fired them correctly. Takes before
## gives, because a give replaces a slot and a take of the replaced weapon afterwards
## would empty it.
##
## [b]Full magazines on a give[/b]: the ammunition is corrected from the snapshot right
## after, and a weapon given empty would read as a reload the player did not ask for.
static func apply_carry(arsenal: DotWeaponArsenal, mask: int) -> int:
	if arsenal == null or not arsenal.is_ready():
		return 0

	var ids := ZeeWeaponIds.all()
	var changed := 0

	for i in range(mini(ids.size(), 62)):
		var def := arsenal.catalogue.get_def(ids[i]) if arsenal.catalogue != null else null
		if def == null:
			continue

		var held := arsenal.slot_at(def.slot)
		if (mask & (1 << i)) == 0 and held != null and held.id() == ids[i]:
			var _taken := arsenal.take(def.slot)
			changed += 1

	for i in range(mini(ids.size(), 62)):
		if (mask & (1 << i)) != 0 and not arsenal.carries(ids[i]):
			if arsenal.give(ids[i]).ok:
				changed += 1

	return changed


# --- Loadout ---------------------------------------------------------------

## Which loadout slot each of the pack's arsenal slots goes in.
##
## [b]`primary` and `secondary` keep the names they had[/b], because a stored loadout is a
## document keyed on slot ids and a player's saved choice should survive this game
## changing its weapons. The heavies go in `primary` with the rifles: a launcher is
## something you carry INSTEAD of a rifle, and the budget is what makes that a choice.
const LOADOUT_SLOT_FOR := {
	ZeeWeaponIds.SLOT_MELEE: &"melee",
	ZeeWeaponIds.SLOT_SIDEARM: &"secondary",
	ZeeWeaponIds.SLOT_PRIMARY: &"primary",
	ZeeWeaponIds.SLOT_HEAVY: &"primary",
	ZeeWeaponIds.SLOT_THROWN: &"thrown",
}

## Points per arsenal slot. Melee is free because everybody always has one.
const COST_FOR_SLOT := {
	ZeeWeaponIds.SLOT_MELEE: 0,
	ZeeWeaponIds.SLOT_SIDEARM: 1,
	ZeeWeaponIds.SLOT_PRIMARY: 2,
	ZeeWeaponIds.SLOT_HEAVY: 4,
	ZeeWeaponIds.SLOT_THROWN: 1,
}

## The one item a player has to have unlocked. Everything else is free.
##
## Kept rather than made free with the rest, because it is the only thing exercising
## dot-loadout's entitlement path in this game, and a path nothing exercises is one
## nobody knows still works. The game's entitlement source grants it to everybody.
const PAID_WEAPON := ZeeWeaponIds.LAUNCHER


## The items a loadout can name. One per weapon, plus armour.
##
## Note that the item ids match the weapon ids. That is a convention this game chose,
## not something dot-loadout requires — it is what makes `weapon_table()[item.id]` the
## whole of the mapping, and dot-loadout's `arsenal_slot` hint the whole of the rest.
static func catalogue() -> DotItemCatalogue:
	var items: Array[DotItem] = []

	for weapon in weapons():
		var item := DotItem.make(weapon.id, DotItem.KIND_WEAPON, weapon.id != PAID_WEAPON)
		item.display_name = weapon.display_name
		# One loadout slot per weapon, from the pack's arsenal slot. A knife in the
		# primary slot would be a player who spawns with nothing to shoot.
		item.slots = [LOADOUT_SLOT_FOR.get(weapon.slot, &"primary")]
		item.tags = weapon.tags.duplicate()
		item.cost = int(COST_FOR_SLOT.get(weapon.slot, 2))
		items.append(item)

	var armour := DotItem.make(&"armour", DotItem.KIND_EQUIPMENT, true)
	armour.display_name = "Armour"
	armour.slots = [&"gear"]
	armour.cost = 2
	items.append(armour)

	return DotItemCatalogue.of(items)


## The loadout schema: a melee, a sidearm, a primary, a throwable and a gear slot, on a
## small points budget.
##
## Points rather than an explicit list of legal combinations, because "a launcher, or a
## rifle and armour" is a handful of numbers rather than an enumeration that grows as
## the square of the weapon count — and there are twenty-seven weapons now.
static func loadout_schema() -> DotLoadoutSchema:
	# [b]Required, like the throwable below, and that is what puts them in anybody's
	# hands.[/b] dot-loadout's default loadout fills REQUIRED slots only, so as optional
	# slots a player who never chose a loadout spawned with a rifle and a pistol and
	# pressed 5 to nothing — rendered, not reasoned: the grenade was in the class's
	# loadout and the store's default replaced it a frame later. A loadout saved before
	# these slots existed is not refused for lacking them: this game conforms on load
	# (`DotLoadoutConfig.conform_on_load`), and conforming fills an empty required slot
	# with its default before it trims to the budget.
	var melee := DotLoadoutSlot.make(&"melee", true, ZeeWeaponIds.KNIFE)
	melee.display_name = "Melee"
	melee.kinds = [DotItem.KIND_WEAPON]
	melee.arsenal_slot = ZeeWeaponIds.SLOT_MELEE
	melee.order = 5

	var primary := DotLoadoutSlot.make(&"primary", true, ZeeWeaponIds.RIFLE)
	primary.display_name = "Primary"
	primary.kinds = [DotItem.KIND_WEAPON]
	primary.arsenal_slot = ZeeWeaponIds.SLOT_PRIMARY
	primary.order = 10

	var secondary := DotLoadoutSlot.make(&"secondary", true, ZeeWeaponIds.PISTOL)
	secondary.display_name = "Sidearm"
	secondary.kinds = [DotItem.KIND_WEAPON]
	secondary.arsenal_slot = ZeeWeaponIds.SLOT_SIDEARM
	secondary.order = 20

	var thrown := DotLoadoutSlot.make(&"thrown", true, ZeeWeaponIds.FRAG)
	thrown.display_name = "Throwable"
	thrown.kinds = [DotItem.KIND_WEAPON]
	thrown.arsenal_slot = ZeeWeaponIds.SLOT_THROWN
	thrown.order = 25

	var gear := DotLoadoutSlot.make(&"gear")
	gear.display_name = "Gear"
	gear.kinds = [DotItem.KIND_EQUIPMENT]
	gear.order = 30

	var schema := DotLoadoutSchema.of(
		&"arena", [melee, primary, secondary, thrown, gear], catalogue()
	)
	# Melee 0, sidearm 1, primary 2, heavy 4, a grenade 1, armour 2. Seven buys a rifle,
	# a pistol, a frag and armour with one to spare, or a heavy with a sidearm and a
	# grenade and no armour — and not a heavy WITH armour, which is the combination
	# nobody can answer.
	schema.point_budget = 7
	return schema
