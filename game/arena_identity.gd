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
## server.modules.load_module(identity.platform_module())
## [/codeblock]


func _init() -> void:
	avatar_schema = ArenaAvatars.schema()
	stock_avatar_fn = ArenaAvatars.stock_avatar
