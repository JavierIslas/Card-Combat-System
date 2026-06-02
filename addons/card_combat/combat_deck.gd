# Card Combat Engine
# Copyright (C) 2026 Javier Islas
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. This program is distributed WITHOUT ANY WARRANTY; see the GNU
# AGPL for details: <https://www.gnu.org/licenses/>.
#
# A commercial license that exempts you from the AGPL is available: see
# LICENSE_COMMERCIAL.md or contact islasjavieralf@gmail.com.

class_name CombatDeck
extends RefCounted
## Estado de un lado durante combate: mano, mazo, tablero, cementerio y pool de mana.

signal card_drawn(card: CardData)
signal deck_exhausted
signal card_played(instance: CardInstance)
signal mana_changed(new_mana: int)

var _draw_pile: Array[CardData] = []
# Seeded RNG for reproducible shuffles. Seeded by setup(); a negative seed
# randomizes it (non-reproducible, engine default).
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _hand: Array[CardData] = []
var _board: Array[CardInstance] = []
var _graveyard: Array[CardData] = []
var _mana: int = 0
var _max_mana: int = 1
var owner_id: int = 0

## Handler de habilidades a inyectar en cada CardInstance creada. Lo provee
## la sesión; vacío = sin semántica de habilidades (motor agnóstico).
var ability_fn: Callable = Callable()

## Tope de mejoras permanentes a sembrar en cada CardInstance. Lo provee la
## sesión desde CombatConfig; -1 = ilimitado.
var max_permanent_buffs: int = -1

## Optional fatigue hook, seeded by the session. Signature: (owner_id: int).
## Invoked when a draw fails because the pile is empty. Empty = signal only
## (engine default behavior unchanged).
var exhaust_fn: Callable = Callable()

## Tope de criaturas en el tablero. Lo siembra la sesión desde CombatConfig.
## -1 = ilimitado (motor agnóstico).
var max_board_size: int = -1

## Tope de cartas en la mano. Lo siembra la sesión desde CombatConfig.
## -1 = ilimitado (motor agnóstico).
var max_hand_size: int = -1

## Optional discard hook for overdraw, seeded by the session.
## Signature: (card: CardData, owner_id: int). Invoked when a drawn card is burned
## because the hand is full. Empty = the card just goes to the graveyard.
var discard_fn: Callable = Callable()


func setup(cards: Array[CardData], owner: int, starting_max_mana: int = 2, p_ability_fn: Callable = Callable(), p_max_permanent_buffs: int = -1, p_shuffle_seed: int = -1) -> void:
	owner_id = owner
	ability_fn = p_ability_fn
	max_permanent_buffs = p_max_permanent_buffs
	if p_shuffle_seed >= 0:
		_rng.seed = p_shuffle_seed
	else:
		_rng.randomize()
	_draw_pile.clear()
	_hand.clear()
	_board.clear()
	_graveyard.clear()
	_mana = 0
	_max_mana = starting_max_mana
	for c in cards:
		_draw_pile.append(c)
	shuffle()


func shuffle() -> void:
	# Fisher-Yates with the seeded RNG so a fixed seed reproduces the order.
	# Array.shuffle() would use Godot's global RNG and break seed-based replay.
	for i in range(_draw_pile.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp: CardData = _draw_pile[i]
		_draw_pile[i] = _draw_pile[j]
		_draw_pile[j] = tmp


func draw_initial_hand(count: int = 3) -> void:
	for i in count:
		var card := _draw_from_pile()
		if card != null:
			_hand.append(card)


func draw_card() -> CardData:
	var card := _draw_from_pile()
	if card == null:
		deck_exhausted.emit()
		if exhaust_fn.is_valid():
			exhaust_fn.call(owner_id)
		return null
	if is_hand_full():
		# Overdraw: the drawn card is burned to the graveyard instead of held.
		_graveyard.append(card)
		if discard_fn.is_valid():
			discard_fn.call(card, owner_id)
		return card
	_hand.append(card)
	return card


func is_hand_full() -> bool:
	return max_hand_size >= 0 and _hand.size() >= max_hand_size


func _draw_from_pile() -> CardData:
	if _draw_pile.is_empty():
		return null
	var card: CardData = _draw_pile.pop_back()
	card_drawn.emit(card)
	return card


func play_creature(card: CardData, as_hidden: bool = false, declared_attack: int = 0, declared_health: int = 0) -> CardInstance:
	if not can_play_card(card):
		return null
	if is_board_full():
		return null
	spend_mana(card.cost)
	var idx := _hand.find(card)
	if idx == -1:
		return null
	_hand.remove_at(idx)

	var inst := CardInstance.new()
	inst.ability_fn = ability_fn
	inst.max_permanent_buffs = max_permanent_buffs
	if as_hidden:
		var hidden := HiddenCardStats.new()
		hidden.declared_attack = declared_attack
		hidden.declared_health = declared_health
		hidden.total_mana_invested = card.cost
		inst.hidden_stats = hidden
	inst.setup(card, owner_id, as_hidden)
	_board.append(inst)
	card_played.emit(inst)
	return inst


func play_spell(card: CardData) -> CardData:
	if not can_play_card(card):
		return null
	spend_mana(card.cost)
	var idx := _hand.find(card)
	if idx == -1:
		return null
	_hand.remove_at(idx)
	_graveyard.append(card)
	return card


func can_play_card(card: CardData) -> bool:
	return card.cost <= _mana and _hand.has(card)


func spend_mana(amount: int) -> bool:
	if amount > _mana:
		return false
	_mana -= amount
	mana_changed.emit(_mana)
	return true


func gain_mana(amount: int) -> void:
	_mana = mini(_mana + amount, _max_mana)
	mana_changed.emit(_mana)


func increment_max_mana(amount: int = 2) -> void:
	_max_mana += amount


func refresh_creatures_for_turn() -> void:
	for inst in _board:
		if not inst.is_dead:
			inst.refresh_for_turn()
			inst.can_attack_this_turn = true


func get_defenders() -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	for inst in _board:
		if not inst.is_dead:
			result.append(inst)
	return result


func remove_dead_creatures() -> Array[CardInstance]:
	var dead: Array[CardInstance] = []
	var alive: Array[CardInstance] = []
	for inst in _board:
		if inst.is_dead:
			dead.append(inst)
		else:
			alive.append(inst)
	_board = alive
	return dead


func get_hand() -> Array[CardData]:
	return _hand


func get_board() -> Array[CardInstance]:
	return _board


func add_to_board(inst: CardInstance) -> void:
	# Respect the board cap (e.g. summons): a full board silently drops the extra.
	if is_board_full():
		return
	_board.append(inst)


func is_board_full() -> bool:
	return max_board_size >= 0 and _board.size() >= max_board_size


func remove_from_board(inst: CardInstance) -> void:
	_board.erase(inst)


func get_graveyard() -> Array[CardData]:
	return _graveyard


func serialize() -> Dictionary:
	## Snapshot of one side's state. Hooks (ability_fn, exhaust_fn, discard_fn) and
	## caps are NOT stored: the session re-injects them on deserialize. The RNG seed
	## and state are kept so further shuffles stay deterministic after a resume.
	return {
		"owner_id": owner_id,
		"mana": _mana,
		"max_mana": _max_mana,
		"rng_seed": _rng.seed,
		"rng_state": _rng.state,
		"draw_pile": _serialize_cards(_draw_pile),
		"hand": _serialize_cards(_hand),
		"graveyard": _serialize_cards(_graveyard),
		"board": _board.map(func(inst: CardInstance) -> Dictionary: return inst.serialize()),
	}


func _serialize_cards(cards: Array[CardData]) -> Array:
	return cards.map(func(card: CardData) -> Dictionary: return card.serialize())


static func deserialize(data: Dictionary, hooks: Dictionary = {}) -> CombatDeck:
	## Rebuilds a deck from a snapshot. `hooks` re-supplies the non-serializable
	## config: ability_fn, max_permanent_buffs, exhaust_fn, discard_fn, max_board_size
	## and max_hand_size. Board instances are rebuilt with the ability_fn already set.
	var deck := CombatDeck.new()
	deck.owner_id = int(data.get("owner_id", 0))
	deck.ability_fn = hooks.get("ability_fn", Callable())
	deck.max_permanent_buffs = int(hooks.get("max_permanent_buffs", -1))
	deck.exhaust_fn = hooks.get("exhaust_fn", Callable())
	deck.discard_fn = hooks.get("discard_fn", Callable())
	deck.max_board_size = int(hooks.get("max_board_size", -1))
	deck.max_hand_size = int(hooks.get("max_hand_size", -1))
	deck._mana = int(data.get("mana", 0))
	deck._max_mana = int(data.get("max_mana", 1))
	deck._rng.seed = int(data.get("rng_seed", 0))
	deck._rng.state = int(data.get("rng_state", 0))
	deck._draw_pile = _deserialize_cards(data.get("draw_pile", []))
	deck._hand = _deserialize_cards(data.get("hand", []))
	deck._graveyard = _deserialize_cards(data.get("graveyard", []))
	var board: Array[CardInstance] = []
	for d in data.get("board", []):
		board.append(CardInstance.deserialize(d, deck.ability_fn))
	deck._board = board
	return deck


static func _deserialize_cards(raw: Array) -> Array[CardData]:
	var cards: Array[CardData] = []
	for d in raw:
		var card := CardData.from_dict(d)
		if card != null:
			cards.append(card)
		else:
			# A corrupt snapshot must not drop cards silently: surface it so a bad
			# save is diagnosable instead of resuming with a smaller deck.
			push_warning("CombatDeck.deserialize: dropped an invalid card entry — %s" % d)
	return cards


var mana: int:
	get: return _mana

var max_mana: int:
	get: return _max_mana

var hand_size: int:
	get: return _hand.size()

var board_size: int:
	get: return _board.size()

var draw_pile_size: int:
	get: return _draw_pile.size()
