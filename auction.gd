extends PartyMode
## Auction: everyone starts with coins and a level of their own (a random arena).
## Each round, items are auctioned in the auction room (auction_room.gd); then,
## level after level, the owner traps their level with what they bought and the
## others race through it while the owner watches. The bank pays: reaching the
## flag pays the runner, every robot that doesn't make it pays the owner, and
## when nobody makes it everyone gets something. The party ends after a number
## of rounds (most coins) or when someone reaches a number of coins (rules).
##
## Everything lives in Party.session.auction; coins are the party's scores, so
## the usual scoreboard shows them.

const ROOM := "auction_room.tscn"


func _init() -> void:
	name = "Auction"
	description = "Everyone gets coins and a level. Bid for traps in the auction room, trap your level, then race through the others'. Reaching a flag, or every robot lost on your level, pays."
	custom_flow = true
	hidden_rules = ["target", "coins"]


func rule_defs() -> Array:
	return [
		{"key": "auction_end", "name": "Ends", "default": "rounds",
			"choices": [["rounds", "After rounds"], ["coins", "Coin target"]],
			"info": "After rounds: the most coins after the last round wins.\nCoin target: the first to have that many coins wins."},
		{"key": "auction_rounds", "name": "Rounds", "default": 3, "min": 1, "max": 10, "when": {"auction_end": "rounds"},
			"info": "Auctions (each followed by a race through every level)."},
		{"key": "auction_target", "name": "Coin target", "default": 300, "min": 150, "max": 1000, "step": 25, "when": {"auction_end": "coins"},
			"info": "Coins needed to win."},
		{"key": "auction_start", "name": "Start coins", "default": 100, "min": 0, "max": 500, "step": 10,
			"info": "Coins everyone starts with."},
		{"key": "auction_lots", "name": "Items", "default": 0, "min": 0, "max": 12,
			"info": "Items in each auction (0: two more than there are players)."},
		{"key": "auction_time", "name": "Bid time", "default": 10, "min": 5, "max": 30, "unit": " s",
			"info": "Seconds on the clock for each item. A bid with less than 5 s left adds 5 s."},
		{"key": "auction_pass", "name": "Flag pays", "default": 20, "min": 0, "max": 100, "step": 5,
			"info": "Coins for reaching the flag of someone else's level."},
		{"key": "auction_death", "name": "Loss pays", "default": 10, "min": 0, "max": 100, "step": 5,
			"info": "Coins the owner gets for every robot that doesn't make it through their level."},
		{"key": "auction_nobody", "name": "Nobody pays", "default": 10, "min": 0, "max": 100, "step": 5,
			"info": "Coins for everyone when nobody gets through a level."},
	]


func rule_defaults() -> Dictionary:
	return {"round_time": 40}


# --- The party ---------------------------------------------------------------------

func party_started(session: Dictionary) -> void:
	var levels := {}
	var used := []
	for s in session.players:
		# A random level each (different ones while there are enough).
		var a: Array = Party.random_arena()
		for tries in 6:
			if not str(a[0]) + str(a[1].get("name", "")) in used:
				break
			a = Party.random_arena()
		used.append(str(a[0]) + str(a[1].get("name", "")))
		var items: Array = Party.map_items(a[1], int(session.get("next_uid", 1)))
		session.next_uid = int(session.get("next_uid", 1)) + items.size()
		levels[str(s)] = {"arena": a[0], "map": a[1], "items": items}
		session.scores[str(s)] = int(session.rules.get("auction_start", 100))
	session.auction = {"levels": levels, "won": {}, "round": 1, "order": [], "index": -1, "lots": [], "lot": 0,
		"room": (get_script() as Script).resource_path.get_base_dir().path_join(ROOM)}
	session.arena = room_path()
	session.erase("map")


## The auction room's scene (next to this script, wherever the mod is).
static func room_path() -> String:
	return str(Party.session.auction.room)


## A level's name ("Steps", or the map's).
static func level_name(level: Dictionary) -> String:
	var m = level.get("map", {})
	if m is Dictionary and m.has("name"):
		return str(m.name)
	var i := Party.ARENAS.find(str(level.get("arena", "")))
	return Party.ARENA_NAMES[i] if i >= 0 else "Level"


## After the auction: on to the levels, one after another.
static func start_levels() -> void:
	var a: Dictionary = Party.session.auction
	var order: Array = Party.session.players.duplicate()
	order.shuffle()
	a.order = order
	a.index = -1
	next_level()


## The next level (or the end of the round once every level was raced).
static func next_level() -> void:
	var a: Dictionary = Party.session.auction
	a.index = int(a.index) + 1
	while int(a.index) < a.order.size() and not int(a.order[a.index]) in Party.players():
		a.index = int(a.index) + 1  # its owner left
	if int(a.index) >= a.order.size():
		_round_over()
		return
	var owner := int(a.order[a.index])
	var level: Dictionary = a.levels[str(owner)]
	Party.session.arena = level.arena
	if level.get("map", {}) is Dictionary and not level.map.is_empty():
		Party.session.map = level.map
	else:
		Party.session.erase("map")
	Party.session.items = level.get("items", []).duplicate(true)
	Party.save()
	Party.get_tree().root.get_node("Transition").change_scene(level.arena,
		"%s's level\n%s" % [Party.label(owner), level_name(level)], 1.2)


static func _round_over() -> void:
	var a: Dictionary = Party.session.auction
	var best := 0
	for s in Party.players():
		if best == 0 or Party.score(s) > Party.score(best):
			best = s
	var done := false
	if str(Party.rule("auction_end")) == "coins":
		done = best != 0 and Party.score(best) >= int(Party.rule("auction_target"))
	else:
		done = int(a.round) >= int(Party.rule("auction_rounds"))
	if done:
		Party.end_game("%s wins the auction with %d coins!" % [Party.label(best), Party.score(best)])
		return
	a.round = int(a.round) + 1
	a.lots = []
	a.lot = 0
	Party.session.round = a.round
	Party.session.arena = room_path()
	Party.session.erase("map")
	Party.session.items = []
	Party.save()
	Party.get_tree().root.get_node("Transition").change_scene(room_path(), "Auction, round %d" % a.round, 1.2)


# --- In a level ----------------------------------------------------------------------

var _owner := 0


func start_level(ctl: Node) -> void:
	var a: Dictionary = Party.session.auction
	_owner = int(a.order[a.index])
	Party.session.round = int(a.round)
	ctl.runners.assign(ctl.slots.filter(func(s): return s != _owner) if ctl.slots.size() > 1 else ctl.slots)
	ctl._set_title("Auction, round %d: %s's level" % [a.round, Party.label(_owner)])
	var won: Array = a.won.get(str(_owner), [])
	a.won[str(_owner)] = []
	if won.is_empty():
		ctl.say("%s's level" % Party.label(_owner))
		ctl.note("Nothing new to place")
	else:
		ctl.say("%s traps their level" % Party.label(_owner))
		ctl.note("%d item%s to place" % [won.size(), "" if won.size() == 1 else "s"])
	ctl.place_cards({_owner: won})


func score_round(ctl: Node, gains: Dictionary) -> void:
	for s in gains:
		gains[s] = 0  # coins, not the usual points
	ctl.note("")
	var lost := 0
	for s in ctl.runners:
		if s == _owner:
			continue
		if s in ctl.finished:
			gains[s] += int(Party.rule("auction_pass"))
		else:
			lost += 1
	if gains.has(_owner) and ctl.slots.size() > 1:
		gains[_owner] += lost * int(Party.rule("auction_death"))
	var raced: Array = ctl.runners.filter(func(s): return s != _owner)
	if not raced.is_empty() and ctl.finished.is_empty():
		for s in gains:
			gains[s] += int(Party.rule("auction_nobody"))
		ctl.say("Nobody got through!")
	elif lost == 0 and not raced.is_empty():
		ctl.say("Everyone got through")
	else:
		ctl.say("%d lost on %s's level" % [lost, Party.label(_owner)])


func goal_text() -> String:
	var a: Dictionary = Party.session.get("auction", {})
	if str(Party.rule("auction_end")) == "coins":
		return "Coins (first to %d wins)" % int(Party.rule("auction_target"))
	return "Coins (round %d of %d)" % [int(a.get("round", 1)), int(Party.rule("auction_rounds"))]


func score_goal() -> int:
	if str(Party.rule("auction_end")) == "coins":
		return int(Party.rule("auction_target"))
	var most := 1
	for s in Party.players():
		most = maxi(most, Party.score(s))
	return int(most * 1.25)


func after_score(_ctl: Node) -> bool:
	var a: Dictionary = Party.session.auction
	a.levels[str(_owner)].items = Party.session.items.duplicate(true)
	next_level()
	return true
