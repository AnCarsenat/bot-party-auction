extends Control
## The auction room: the items of this round are sold one at a time.
##
## Up / Down: the price you'd pay (Left / Right: 10 at a time), Jump: bid it.
## A bid must beat the highest one by at least 1 coin. The clock runs for each
## item; a bid with less than 5 seconds left adds 5 seconds. When the clock runs
## out, the highest bidder pays and gets the item, to place in their own level.
##
## The host (or the only computer) runs it; online, clients show what it sends
## (net_state / net_apply) and their players' keys reach the host as usual.

const Mode := preload("auction.gd")
const TEX_BODY := preload("res://player/player_body.webp")
const TEX_FACE := preload("res://player/player_face.webp")
const TEX_COIN := preload("res://party/art/coin.webp")
const TEX_TILE := preload("res://levels/tile.webp")

const INTRO := 1.4          # an item comes out
const SOLD := 2.4           # "Sold!" shows
const EXTEND_UNDER := 5.0   # a bid with less than this left...
const EXTEND_BY := 5.0      # ...adds this
const REPEAT_AFTER := 0.35  # holding Up / Down

# What's shown (the host's state; clients get it).
var slots: Array = []
var lots: Array = []        # item ids for sale this round
var lot := 0                # the one on the pedestal
var price := 0              # highest bid (0: none yet)
var leader := 0             # who made it
var time_left := 0.0
var offers := {}            # slot -> the price they'd bid
var stage := "intro"        # intro, bid, sold, done
var stage_time := 0.0
var buyers: Array = []      # per item sold so far: [slot, price] ([0, 0]: no bid)
var bid_at := {}            # slot -> msec of their last bid (a little bounce)
var extended_at := -100000  # msec of the last "+5 s"
var round_no := 1
var won := {}               # slot -> item ids bought this round

var _client := false
var _held := {}             # slot -> [action, seconds held, next repeat]
var _bots := {}             # bot slot -> {value, think}
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _icons := {}            # item id -> texture (kept: one loaded in _draw would be freed before it's drawn)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST  # pixel art stays sharp
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("net_sync")
	get_parent().add_to_group("pausable")
	_rng.randomize()
	_client = NetCheck.client(self)
	if _client:
		return  # the host sends everything
	var a: Dictionary = Party.session.auction
	slots = Party.players()
	round_no = int(a.round)
	if a.lots.is_empty():
		a.lots = _new_lots()
		a.lot = 0
		a.buyers = []
		a.won = {}
	lots = a.lots
	lot = int(a.lot)
	buyers = a.get("buyers", [])
	won = a.won
	Party.save()
	if lot >= lots.size():
		_finish()
		return
	_start_lot()


## The items for sale: placeable ones (no bombs: you only place in your own level).
func _new_lots() -> Array:
	var count := int(Party.rule("auction_lots"))
	if count <= 0:
		count = slots.size() + 2
	var skip: Array = Party.ITEMS.keys().filter(func(k): return Party.ITEMS[k].get("bomb", false) or Party.ITEMS[k].get("card", false))
	var out := []
	for i in count:
		var id := Party.pick_item(_rng, skip)
		if _rng.randf() < Party.special_odds():
			var sp := Party.pick_special(_rng)
			if sp != "" and not sp in skip:
				id = sp
		if out.count(id) >= 2:
			id = Party.pick_item(_rng, skip + [id])
		out.append(id)
	return out


func _start_lot() -> void:
	stage = "intro"
	stage_time = 0.0
	price = 0
	leader = 0
	time_left = float(Party.rule("auction_time"))
	for s in slots:
		offers[s] = mini(1, _coins(s)) if _coins(s) > 0 else 0
	_bots.clear()
	for b in Party.bots():
		if b in slots:
			_bots[b] = {"value": _bot_value(b, lots[lot]), "think": _rng.randf_range(0.8, 2.5)}


func _coins(slot: int) -> int:
	return Party.score(slot)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _client:
		if stage == "bid":
			time_left = maxf(0.0, time_left - delta)  # smooth between the host's news
		stage_time += delta
		return
	stage_time += delta
	match stage:
		"intro":
			if stage_time >= INTRO:
				stage = "bid"
				stage_time = 0.0
		"bid":
			_read_keys(delta)
			_bots_think(delta)
			time_left -= delta
			if time_left <= 0.0:
				time_left = 0.0
				_sell()
		"sold":
			if stage_time >= SOLD:
				lot += 1
				Party.session.auction.lot = lot
				Party.save()
				if lot >= lots.size():
					_finish()
				else:
					_start_lot()


func _sell() -> void:
	stage = "sold"
	stage_time = 0.0
	buyers.append([leader, price])
	if leader != 0:
		Party.session.scores[str(leader)] = _coins(leader) - price
		var list: Array = won.get(str(leader), [])
		list.append(lots[lot])
		won[str(leader)] = list
	Party.session.auction.buyers = buyers
	Party.session.auction.won = won
	Party.save()


func _finish() -> void:
	stage = "done"
	stage_time = 0.0
	await get_tree().create_timer(1.5).timeout
	if is_inside_tree():
		Mode.start_levels()


# --- Bidding --------------------------------------------------------------------------

func _read_keys(delta: float) -> void:
	for s in slots:
		if Party.bots().has(s):
			continue
		var p := "p%d_" % s
		for pair in [["move_up", 1], ["move_down", -1], ["move_right", 10], ["move_left", -10]]:
			var action: String = p + pair[0]
			if Input.is_action_just_pressed(action):
				_nudge(s, pair[1])
				_held[action] = [0.0, REPEAT_AFTER]
			elif Input.is_action_pressed(action) and _held.has(action):
				var h: Array = _held[action]
				h[0] += delta
				h[1] -= delta
				if h[1] <= 0.0:
					h[1] = 0.04 if h[0] > 1.2 else 0.08  # faster the longer it's held
					_nudge(s, pair[1])
			else:
				_held.erase(action)
		if Input.is_action_just_pressed(p + "action_1"):
			bid(s, int(offers.get(s, 0)))


## The lowest bid that counts now.
func min_bid() -> int:
	return price + 1


func _nudge(slot: int, by: int) -> void:
	offers[slot] = clampi(int(offers.get(slot, 0)) + by, mini(min_bid(), _coins(slot)), _coins(slot))


## `slot` bids `amount` coins (if it beats the highest bid and they have it).
func bid(slot: int, amount: int) -> bool:
	if stage != "bid" or slot == leader or amount < min_bid() or amount > _coins(slot):
		return false
	price = amount
	leader = slot
	bid_at[slot] = Time.get_ticks_msec()
	if time_left < EXTEND_UNDER:
		time_left += EXTEND_BY
		extended_at = Time.get_ticks_msec()
	# Everyone's price goes at least to the new lowest bid.
	for s in slots:
		if s != slot:
			offers[s] = clampi(maxi(int(offers.get(s, 0)), min_bid()), 0, _coins(s))
	return true


## What a bot would pay for an item: traps are worth the most (they pay when
## someone falls in your level), helping items little.
func _bot_value(slot: int, id: String) -> int:
	var def: Dictionary = Party.ITEMS.get(id, {})
	var base := 28.0 if def.get("kind", "") == "trap" else 8.0
	if Party.is_special(id):
		base += 14.0
	var purse := float(_coins(slot))
	var v := base * _rng.randf_range(0.6, 1.5) * clampf(purse / 100.0, 0.6, 1.8)
	var left := maxi(1, lots.size() - lot)
	return int(minf(v, purse * (0.6 if left > 2 else 0.9)))


func _bots_think(delta: float) -> void:
	for b in _bots:
		var mind: Dictionary = _bots[b]
		mind.think -= delta
		if mind.think > 0.0:
			continue
		# Quicker near the end of the clock.
		mind.think = _rng.randf_range(0.3, 0.9) if time_left < 3.0 else _rng.randf_range(0.8, 2.2)
		if b != leader and min_bid() <= mini(int(mind.value), _coins(b)):
			var amount := mini(min_bid() + _rng.randi_range(0, 2), mini(int(mind.value), _coins(b)))
			offers[b] = amount
			bid(b, amount)


# --- Online ------------------------------------------------------------------------------

func net_state() -> Dictionary:
	var ages := {}
	var now := Time.get_ticks_msec()
	for s in bid_at:
		ages[s] = now - int(bid_at[s])
	return {"s": slots, "l": lots, "i": lot, "p": price, "ld": leader, "t": snappedf(time_left, 0.1),
		"o": offers, "st": stage, "b": buyers, "ba": ages, "ex": now - extended_at, "r": round_no, "w": won,
		"c": Party.session.get("scores", {})}


func net_apply(d: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	if d.get("st", "") != stage or int(d.get("i", -1)) != lot:
		stage_time = 0.0
	slots = d.get("s", [])
	lots = d.get("l", [])
	lot = int(d.get("i", 0))
	price = int(d.get("p", 0))
	leader = int(d.get("ld", 0))
	time_left = float(d.get("t", 0.0))
	offers = d.get("o", {})
	stage = str(d.get("st", "bid"))
	buyers = d.get("b", [])
	for s in d.get("ba", {}):
		bid_at[int(s)] = now - int(d.ba[s])
	extended_at = now - int(d.get("ex", 100000))
	round_no = int(d.get("r", 1))
	won = d.get("w", {})
	Party.session.scores = d.get("c", {})


# --- Drawing ------------------------------------------------------------------------------

const GOLD := Color("ffd65a")
const VELVET := Color("8f1d2c")
const VELVET_LIGHT := Color("b52f40")
const WALL := Color("3a2b45")
const WOOD := Color("7a4a2b")
const WOOD_DARK := Color("5b3420")


func _draw() -> void:
	var v := get_viewport_rect().size
	var font: Font = UiTheme.FONT_BOLD
	var thin: Font = UiTheme.FONT_MEDIUM
	_draw_hall(v)
	if lots.is_empty():
		return
	var id: String = lots[mini(lot, lots.size() - 1)]
	var def: Dictionary = Party.ITEMS.get(id, {})
	var centre := Vector2(v.x * 0.36, v.y * 0.42)

	# Spotlight and pedestal.
	var beam := PackedVector2Array([Vector2(centre.x - 30, 0), Vector2(centre.x + 30, 0),
		Vector2(centre.x + 150, centre.y + 95), Vector2(centre.x - 150, centre.y + 95)])
	var glow := Color(1, 0.97, 0.8, 0.16)
	draw_polygon(beam, PackedColorArray([glow, glow, Color(glow, 0.05), Color(glow, 0.05)]))
	draw_colored_polygon(_ellipse(centre + Vector2(0, 95), Vector2(150, 22)), Color(1, 0.97, 0.8, 0.18))
	var ped := PackedVector2Array([centre + Vector2(-95, 70), centre + Vector2(95, 70),
		centre + Vector2(80, 150), centre + Vector2(-80, 150)])
	draw_colored_polygon(ped, UiTheme.MARBLE)
	draw_polyline(_closed(ped), UiTheme.INK, 4.0)
	draw_rect(Rect2(centre + Vector2(-110, 56), Vector2(220, 18)), Color("d8d5de"))
	draw_rect(Rect2(centre + Vector2(-110, 56), Vector2(220, 18)), UiTheme.INK, false, 4.0)

	# The item, coming out, then floating.
	var rise := clampf(stage_time / 0.5, 0.0, 1.0) if stage == "intro" else 1.0
	var sold_out := stage == "sold" and buyers.size() > lot and int(buyers[lot][0]) != 0
	var fly := clampf((stage_time - 1.0) / 0.7, 0.0, 1.0) if sold_out else 0.0
	var item_pos := centre + Vector2(0, -10 + sin(_t * 2.2) * 6.0 + (1.0 - rise) * 60.0)
	if fly > 0.0:
		var to := _panel_rect(int(buyers[lot][0]), v).get_center()
		item_pos = item_pos.lerp(to, fly * fly)
	var tex: Texture2D = _icon(id)
	if tex and fly < 1.0:
		var size := 128.0 * (1.0 - fly * 0.7)
		draw_circle(item_pos, size * 0.62, Color(1, 1, 0.85, 0.16 * rise))
		var tsz := tex.get_size()
		var k := size / maxf(tsz.x, tsz.y)
		draw_texture_rect(tex, Rect2(item_pos - tsz * k / 2.0, tsz * k), false, Color(1, 1, 1, rise))
	# Its name and kind.
	var title := str(def.get("name", id))
	_text(font, Vector2(centre.x, centre.y - 120), title, 46, UiTheme.MARBLE, true)
	var kind := "TRAP" if def.get("kind", "") == "trap" else ("HELP" if def.get("kind", "") == "help" else "ITEM")
	if Party.is_special(id):
		kind = "SPECIAL " + kind
	var kind_col := UiTheme.RED if def.get("kind", "") == "trap" else (Color("3fa35b") if def.get("kind", "") == "help" else UiTheme.MUTED)
	var kw := font.get_string_size(kind, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 24
	var pill := Rect2(Vector2(centre.x - kw / 2.0, centre.y - 106), Vector2(kw, 28))
	draw_rect(pill, kind_col)
	draw_rect(pill, UiTheme.INK, false, 3.0)
	_text(font, pill.get_center() + Vector2(0, 8), kind, 22, Color.WHITE, true)

	_draw_board(v, font, thin)
	_draw_lots(v, font)
	for s in slots:
		_draw_panel(int(s), v, font, thin)
	_draw_stamp(v, font)
	# Title and help.
	_text(font, Vector2(36, 54), "AUCTION", 52, GOLD)
	_text(thin, Vector2(38, 82), "Round %d  ·  item %d of %d" % [round_no, mini(lot + 1, lots.size()), lots.size()], 22, Color(1, 1, 1, 0.75))
	_text(thin, Vector2(v.x / 2.0, v.y - 10), "Up / Down: your price   Left / Right: 10 at a time   Jump: bid", 18, Color(1, 1, 1, 0.6), true)


func _draw_hall(v: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, v), WALL)
	draw_texture_rect(TEX_TILE, Rect2(Vector2.ZERO, Vector2(v.x, v.y * 0.66)), true, Color(0.45, 0.36, 0.55, 0.35))
	# Stage floor.
	var floor_y := v.y * 0.66
	draw_rect(Rect2(0, floor_y, v.x, v.y - floor_y), WOOD)
	for i in 8:
		var y := floor_y + i * 34.0
		draw_line(Vector2(0, y), Vector2(v.x, y), WOOD_DARK, 3.0)
		for x in range(int(fmod(i * 97.0, 160.0)) - 160, int(v.x), 160):
			draw_line(Vector2(x, y), Vector2(x, y + 34), WOOD_DARK, 2.0)
	draw_rect(Rect2(0, floor_y - 6, v.x, 8), UiTheme.INK)
	# Curtains on both sides, and a valance on top.
	for side in [0, 1]:
		var w := v.x * 0.09
		var x0: float = 0.0 if side == 0 else v.x - w
		for k in 6:
			var fx := x0 + k * w / 6.0
			draw_rect(Rect2(fx, 0, w / 6.0, floor_y), VELVET if k % 2 == 0 else VELVET_LIGHT)
			draw_line(Vector2(fx, 0), Vector2(fx, floor_y), Color(0, 0, 0, 0.25), 2.0)
		var tie := Vector2(x0 + w * (0.75 if side == 0 else 0.25), floor_y * 0.62)
		draw_circle(tie, 9, GOLD)
		draw_circle(tie, 9, UiTheme.INK, false, 3.0)
	var top := 46.0
	draw_rect(Rect2(0, 0, v.x, top), VELVET)
	for x in range(0, int(v.x) + 60, 60):
		draw_circle(Vector2(x + 30, top), 30, VELVET)
		draw_arc(Vector2(x + 30, top), 30, 0, PI, 12, Color(0, 0, 0, 0.35), 3.0)
	draw_line(Vector2(0, top - 30), Vector2(v.x, top - 30), GOLD, 4.0)


## The board on the right: highest bid, who, and the clock.
func _draw_board(v: Vector2, font: Font, thin: Font) -> void:
	var r := Rect2(Vector2(v.x * 0.58, v.y * 0.13), Vector2(v.x * 0.3, v.y * 0.46))
	draw_rect(Rect2(r.position + Vector2(6, 6), r.size), Color(0, 0, 0, 0.35))
	draw_rect(r, UiTheme.MARBLE)
	draw_rect(r, UiTheme.INK, false, 5.0)
	var cx := r.get_center().x
	_text(thin, Vector2(cx, r.position.y + 38), "HIGHEST BID", 24, UiTheme.MUTED, true)
	var amount := str(price) if leader != 0 else "-"
	var bounce := _bounce(leader)
	var big := 76.0 * (1.0 + bounce * 0.25)
	var w := font.get_string_size(amount, HORIZONTAL_ALIGNMENT_LEFT, -1, int(big)).x
	draw_texture_rect(TEX_COIN, Rect2(Vector2(cx - w / 2.0 - 46, r.position.y + 62), Vector2(40, 40)), false)
	_text(font, Vector2(cx + 18, r.position.y + 106), amount, int(big), UiTheme.INK, true)
	if leader != 0:
		var col := _color(leader)
		var tag := Rect2(Vector2(cx - 90, r.position.y + 122), Vector2(180, 40))
		draw_rect(tag, col)
		draw_rect(tag, UiTheme.INK, false, 3.0)
		_text(font, tag.get_center() + Vector2(0, 10), Party.label(leader), 28, UiTheme.INK, true)
	else:
		_text(thin, Vector2(cx, r.position.y + 150), "No bids yet", 24, UiTheme.MUTED, true)
	# The clock.
	var c := Vector2(cx, r.end.y - 72)
	var total := maxf(float(Party.rule("auction_time")), time_left)
	var frac := clampf(time_left / total, 0.0, 1.0) if stage == "bid" else (1.0 if stage == "intro" else 0.0)
	var hurry := time_left < EXTEND_UNDER and stage == "bid"
	var ring := UiTheme.RED if hurry else UiTheme.ACCENT
	draw_arc(c, 50, 0, TAU, 48, Color("d8d5de"), 12.0)
	if frac > 0.0:
		draw_arc(c, 50, -PI / 2.0, -PI / 2.0 + TAU * frac, 48, ring, 12.0)
	draw_arc(c, 57, 0, TAU, 48, UiTheme.INK, 3.0)
	draw_arc(c, 43, 0, TAU, 48, UiTheme.INK, 3.0)
	var pulse := 1.0 + (0.12 * absf(sin(_t * 8.0)) if hurry else 0.0)
	_text(font, c + Vector2(0, 16), str(ceili(time_left)) if stage == "bid" else "-", int(44 * pulse), ring if hurry else UiTheme.INK, true)
	var since := Time.get_ticks_msec() - extended_at
	if since < 1200:
		var a := 1.0 - since / 1200.0
		_text(font, c + Vector2(78, -20 - (1.0 - a) * 30.0), "+5 s", 34, Color(UiTheme.ACCENT, a), true)


## The strip of this round's items at the top: sold ones show who bought them.
func _draw_lots(v: Vector2, font: Font) -> void:
	var n := lots.size()
	var step := 54.0
	var x0 := v.x * 0.58 + (v.x * 0.3 - n * step) / 2.0
	var y := v.y * 0.13 - 66
	for i in n:
		var r := Rect2(Vector2(x0 + i * step, y), Vector2(46, 46))
		draw_rect(r, UiTheme.MARBLE if i >= lot else Color("bdb9c4"))
		var tex: Texture2D = _icon(lots[i])
		if tex:
			var k := 36.0 / maxf(tex.get_size().x, tex.get_size().y)
			draw_texture_rect(tex, Rect2(r.get_center() - tex.get_size() * k / 2.0, tex.get_size() * k), false,
				Color(1, 1, 1, 1.0 if i >= lot else 0.55))
		draw_rect(r, GOLD if i == lot else UiTheme.INK, false, 5.0 if i == lot else 3.0)
		if i < buyers.size():
			var who := int(buyers[i][0])
			if who != 0:
				draw_rect(Rect2(r.position + Vector2(0, 40), Vector2(46, 6)), _color(who))
			else:
				draw_line(r.position + Vector2(8, 8), r.end - Vector2(8, 8), UiTheme.RED, 4.0)


func _panel_rect(slot: int, v: Vector2) -> Rect2:
	var n := maxi(1, slots.size())
	var w := minf(170.0, (v.x - 80.0) / n - 12.0)
	var i := slots.find(slot)
	var x := (v.x - n * (w + 12.0) + 12.0) / 2.0 + i * (w + 12.0)
	var lift := -14.0 if slot == leader else 0.0
	return Rect2(Vector2(x, v.y * 0.69 + lift), Vector2(w, v.y * 0.25))


## A player's stand: their robot, coins, the price they'd bid and what they bought.
func _draw_panel(slot: int, v: Vector2, font: Font, thin: Font) -> void:
	var r := _panel_rect(slot, v)
	var b := _bounce(slot)
	r = r.grow(b * 6.0)
	var col := _color(slot)
	draw_rect(Rect2(r.position + Vector2(5, 5), r.size), Color(0, 0, 0, 0.35))
	draw_rect(r, UiTheme.MARBLE)
	draw_rect(Rect2(r.position, Vector2(r.size.x, 10)), col)
	draw_rect(r, GOLD if slot == leader else UiTheme.INK, false, 6.0 if slot == leader else 3.0)
	# The robot (looking at the item), and a crown for whoever leads.
	var robot := Rect2(Vector2(r.position.x + 10, r.position.y + 18), Vector2(52, 52))
	var frame := Rect2(0, 0, 32, 32)
	draw_texture_rect_region(TEX_BODY, robot, frame, col)
	draw_texture_rect_region(TEX_FACE, robot, frame)
	if slot == leader:
		var cx := robot.get_center().x
		var cy := robot.position.y - 2
		draw_colored_polygon(PackedVector2Array([Vector2(cx - 16, cy), Vector2(cx - 16, cy - 14), Vector2(cx - 8, cy - 6),
			Vector2(cx, cy - 18), Vector2(cx + 8, cy - 6), Vector2(cx + 16, cy - 14), Vector2(cx + 16, cy)]), GOLD)
	_text(font, Vector2(robot.end.x + 8, r.position.y + 42), Party.label(slot).left(9), 26, UiTheme.INK)
	draw_texture_rect(TEX_COIN, Rect2(Vector2(robot.end.x + 8, r.position.y + 50), Vector2(20, 20)), false)
	_text(thin, Vector2(robot.end.x + 32, r.position.y + 68), str(_coins(slot)), 22, UiTheme.INK)
	# Their price.
	var offer := int(offers.get(slot, 0))
	var can := _coins(slot) >= min_bid() and slot != leader and stage == "bid"
	var box := Rect2(Vector2(r.position.x + 10, r.position.y + 80), Vector2(r.size.x - 20, 40))
	draw_rect(box, Color.WHITE if can else Color("d8d5de"))
	draw_rect(box, UiTheme.INK, false, 3.0)
	if slot == leader:
		_text(font, box.get_center() + Vector2(0, 10), "LEADS", 26, UiTheme.ACCENT, true)
	elif _coins(slot) < min_bid():
		_text(thin, box.get_center() + Vector2(0, 8), "not enough", 20, UiTheme.MUTED, true)
	else:
		_text(font, box.get_center() + Vector2(0, 11), str(offer), 30, UiTheme.INK if can else UiTheme.MUTED, true)
		var up := box.position + Vector2(box.size.x - 16, 12)
		draw_colored_polygon(PackedVector2Array([up + Vector2(-7, 6), up + Vector2(7, 6), up + Vector2(0, -3)]), UiTheme.INK)
		var dn := box.position + Vector2(box.size.x - 16, 28)
		draw_colored_polygon(PackedVector2Array([dn + Vector2(-7, -6), dn + Vector2(7, -6), dn + Vector2(0, 3)]), UiTheme.INK)
	# What they bought this round.
	var bought: Array = won.get(str(slot), [])
	for k in bought.size():
		var tex: Texture2D = _icon(bought[k])
		var cell := Rect2(Vector2(r.position.x + 10 + k * 26, r.end.y - 34), Vector2(24, 24))
		if cell.end.x > r.end.x - 6:
			_text(thin, cell.position + Vector2(2, 18), "+%d" % (bought.size() - k), 18, UiTheme.MUTED)
			break
		if tex:
			draw_texture_rect(tex, cell, false)
	var level: Dictionary = Party.session.get("auction", {}).get("levels", {}).get(str(slot), {})
	if bought.is_empty() and not level.is_empty():
		_text(thin, Vector2(r.position.x + 10, r.end.y - 14), "Level: " + Mode.level_name(level), 18, UiTheme.MUTED)
	# "Bid!" floating up.
	var age := Time.get_ticks_msec() - int(bid_at.get(slot, -100000))
	if age < 900:
		var a := 1.0 - age / 900.0
		_text(font, Vector2(r.get_center().x, r.position.y - 10 - (1.0 - a) * 40.0), "BID!", 30, Color(GOLD, a), true)


## "Sold!" (or "No bid") stamped over the item.
func _draw_stamp(v: Vector2, font: Font) -> void:
	if stage != "sold" or buyers.size() <= lot:
		if stage == "done":
			_text(font, Vector2(v.x * 0.36, v.y * 0.42), "To the levels!", 60, GOLD, true)
		return
	var who := int(buyers[lot][0])
	var s := clampf(stage_time / 0.18, 0.0, 1.0)
	var scale := 1.6 - 0.6 * s
	var c := Vector2(v.x * 0.36, v.y * 0.40)
	draw_set_transform(c, -0.18, Vector2(scale, scale))
	var text := "SOLD!" if who != 0 else "NO BID"
	var col := UiTheme.RED if who != 0 else UiTheme.MUTED
	var r := Rect2(Vector2(-150, -48), Vector2(300, 96))
	draw_rect(r, Color(1, 1, 1, 0.9 * s))
	draw_rect(r, Color(col, s), false, 8.0)
	_text(font, Vector2(0, 22), text, 72, Color(col, s), true)
	draw_set_transform(Vector2.ZERO)
	if who != 0:
		_text(font, c + Vector2(0, 92), "%s, for %d coins" % [Party.label(who), int(buyers[lot][1])], 32, GOLD, true)


func _icon(id: String) -> Texture2D:
	if not _icons.has(id):
		_icons[id] = Party.icon(id)
	return _icons[id]


func _bounce(slot: int) -> float:
	var age := Time.get_ticks_msec() - int(bid_at.get(slot, -100000))
	return maxf(0.0, 1.0 - age / 300.0) if slot != 0 else 0.0


func _color(slot: int) -> Color:
	return PlayerSpawner.COLORS[(slot - 1) % PlayerSpawner.COLORS.size()]


func _text(f: Font, pos: Vector2, s: String, size: int, col: Color, centred := false) -> void:
	var x := pos.x
	if centred:
		x -= f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x / 2.0
	draw_string_outline(f, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 6,
		Color(0, 0, 0, col.a * 0.8) if col.v > 0.5 else Color(1, 1, 1, col.a * 0.6))
	draw_string(f, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _ellipse(c: Vector2, r: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 24:
		var a := TAU * i / 24.0
		out.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	return out


func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var out := p.duplicate()
	out.append(p[0])
	return out
