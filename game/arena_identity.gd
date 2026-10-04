extends DotPlatformIdentity

const ArenaAvatars := preload("arena_avatars.gd")

## Who a player is: content delivery, a profile, an avatar, and one admission flow.
##
## [b]The chain is dot-platform's [DotPlatformIdentity], and this is only what is arena's
## about it[/b]: the schema a capsule is dressed from, and the stock avatar a guest gets.
## This file was 262 lines before the layer was extracted, and game-g2gfast's was 215 —
## the same chain with the class names changed.
##
## [codeblock]
## var identity := ArenaIdentity.new()
## add_child(identity)
## await identity.setup()
## # By PATH: DotModuleHost constructs the module itself, and finds the hub this
## # registered. platform_module() is for a host that adds the node by hand.
## await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
## [/codeblock]


func _init() -> void:
	avatar_schema = ArenaAvatars.schema()
	stock_avatar_fn = ArenaAvatars.stock_avatar
	avatar_translate_fn = ArenaAvatars.from_site
