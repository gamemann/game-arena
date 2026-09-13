extends Node

## A private deathmatch among friends, with nothing persistent coming out of it.
##
## [b]The arena takes dot-peer-to-peer with the trust turned down, and that is the whole
## decision.[/b] This game reports to dot-stats, unlocks dot-achievements and files to
## dot-leaderboard. A peer-to-peer host is a player's own machine and can lie about all of
## it — so the answer is not "try to catch them", it is **nothing persistent leaves a
## peer-to-peer match**:
##
## [codeblock]
## config.trust = DotP2PConfig.Trust.SANDBOXED
## [/codeblock]
##
## A host who can cheat and a leaderboard are not two features. They are one exploit, and
## the only honest answers are a dedicated server or a sandbox. game-simple-lobby takes the
## same addon at `HOST_AUTHORITATIVE` because it has no score at all, and game-g2gfast
## refuses to host a ranked run outright — three games, three answers, one addon.
##
## [method reporting_allowed] is what the rest of the game asks before it files anything.
## It is a method rather than a flag so that there is one place to look, and so that a
## future "verified" mode is one branch rather than a search.

const CHANNEL := "arena.party"

signal open(code: String)
signal closed(res: DotResult)

var session: DotP2PSession = null

@export var signalling_url: String = ""

var _http: DotHttp = null


func setup() -> DotResult:
	session = DotP2PSession.new()
	session.name = "P2P"
	session.config = _config()
	add_child(session)

	var res := session.setup()
	if not res.ok:
		return res.wrap("the arena's party session")

	session.signaller = _make_signaller()
	session.ended.connect(func(r: DotResult) -> void: closed.emit(r))
	return DotResult.success(null)


func _config() -> DotP2PConfig:
	var c := DotP2PConfig.new()
	# Twelve, which is what dm_atrium is laid out for. A domestic uplink carries a
	# deathmatch of that size; sixty-four is a dedicated server's problem.
	c.max_peers = 12
	c.trust = DotP2PConfig.Trust.SANDBOXED
	# Off. In a lobby a host leaving is an inconvenience and migrating is kind; in a
	# deathmatch the host holds the match clock, the score and every hitbox, and handing
	# that to somebody mid-round produces a round nobody can agree about. A private match
	# whose host left has ended, and saying so is better than continuing wrongly.
	c.migrate_host = false
	c.signalling_url = signalling_url
	return c


func _make_signaller() -> DotP2PSignaller:
	if signalling_url.is_empty():
		return DotP2PSignallerLoopback.new(session.local_id)
	_http = DotHttp.new()
	_http.name = "PartyHttp"
	add_child(_http)
	return DotP2PSignallerHttp.new(signalling_url, session.local_id, _http)


func host(display_name: String) -> DotResult:
	if not DotP2PSession.available():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"this build cannot host a private match",
			DotP2PSession.unavailable_reason()
		)
	var res := session.host(display_name)
	if res.ok:
		open.emit(str(res.value))
		DotLog.info(
			CHANNEL,
			"a private match is open; nothing from it will be filed anywhere",
			{"code": str(res.value)}
		)
	return res


func join(code: String, display_name: String) -> DotResult:
	return session.join(code, display_name)


func leave() -> void:
	session.leave()


func active() -> bool:
	return session != null and session.state() != &"idle"


## Whether statistics, achievements and leaderboard entries may leave this match.
##
## [b]Asked rather than assumed, and asked in one place.[/b] The alternative is every
## reporter checking a flag, which is four places to forget — and the one that is
## forgotten is the one that files a peer-to-peer host's score to a real board.
func reporting_allowed() -> bool:
	if not active():
		return true
	return session.config.trust != DotP2PConfig.Trust.SANDBOXED


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if session == null:
		return PackedStringArray(["no party"])
	out.append_array(session.describe_lines())
	out.append(
		"  reporting %s" % ("allowed" if reporting_allowed() else "refused: this match is sandboxed")
	)
	return out
