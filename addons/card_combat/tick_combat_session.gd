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

class_name TickCombatSession
extends CombatSession
## Tick-simultaneous combat paradigm on top of the sequential engine core.
##
## Instead of alternating one side per turn, every tick each READY side
## independently selects one card/action against the same pre-tick board, and
## every declared attack from every side resolves in a single simultaneous
## damage batch. Reuses the whole base core (decks, spell effects, triggers,
## topology, events, serialization) through inheritance; the sequential driver
## surface (start/advance/play_card/declare_*/end_*_phase/apply_command) stays
## inert — phase never leaves BEGIN until the victory settle moves it to END,
## so is_auto_phase() consumers never ask for player input.
##
## Tick anatomy (run_tick):
##   1. Upkeep for EVERY living side (recovery gates actions, not the
##      economy): mana refill/ramp, optional draws, creature refresh and
##      ON_TURN_START all run at once, not just for one active side.
##   2. Simultaneous selection: one choose_card_to_play call per ready side
##      (null = the side swings with its creatures instead); no side sees
##      another side's in-flight choice.
##   3. Card plays resolve sequentially in side order, revalidated against the
##      live board: a declared target that already died fizzles without
##      consuming the card (the base atomic-fizzle contract).
##   4. Every declared attack from every ready side resolves in ONE damage
##      batch through the CombatDamageResolver three-phase core — the real
##      simultaneity: mutual trades across sides, overkill and reflects all
##      compute before anything applies.
##   5. Close: ON_TURN_END for every living side, the TICK event, then a
##      single victory settle per tick.
##
## Recovery is a scheduling hook like cost_fn: recovery_fn(card, owner_id)
## returns how many ticks a side waits after playing that card; the engine
## never knows what recovery means in the game's rules. Determinism is
## per-mode: the AI-call interleaving differs from the sequential paradigm, so
## the same seed yields a different (but internally reproducible) match.

signal tick_ended(tick_number: int)

## Scheduling hook: (card: CardData, owner_id: int) -> int ticks the side
## waits after playing that card. Empty Callable = 0 (no recovery).
var recovery_fn: Callable = Callable()

## Per-tick economy knobs. Defaults mirror the sequential per-turn economy;
## each side still spends from its own pool via the usual cost/cost_fn path.
var mana_refill_per_tick := true
var mana_ramp_per_tick := true
var cards_drawn_per_tick := 0

var tick_number := 0

var _recovery_ticks: Array[int] = []
var _pending_intents: Array = []


## One side's frozen selection for a tick. `card == null` means the side's
## action is swinging with its creatures (the AI expresses that by passing).
class Intent:
	extends RefCounted
	var side: int = 0
	var card: CardData = null
	var target: Variant = null
	var target_side: int = -1


func ready_sides() -> Array[int]:
	## Sides that may act this tick: living and off recovery, in side order.
	_ensure_tick_arrays()
	var out: Array[int] = []
	for side in _living_sides():
		if _recovery_ticks[side] == 0:
			out.append(side)
	return out


func run_tick() -> bool:
	## Runs one tick (upkeep -> selection/plays/attacks -> close). Returns
	## false without side effects once the combat is over.
	if _combat_over:
		return false
	if phase != CombatState.Phase.BEGIN:
		push_error("TickCombatSession.run_tick: the sequential FSM was started (phase=%s); the tick paradigm never calls start()/advance()" % CombatState.phase_name(phase))
		return false
	_ensure_tick_arrays()
	# Readiness is frozen BEFORE the upkeep decrement, so recovery N skips
	# exactly N ticks (played on tick T with N=2: skips T+1 and T+2, acts on T+3).
	var ready: Array[int] = ready_sides()
	_upkeep_tick()
	var played: Array[int] = _execute_play_intents(_collect_intents(ready))
	_resolve_tick_batch(_collect_attack_pairs(ready, played))
	_close_tick()
	return true


func run_until_end(max_ticks: int = 1000) -> void:
	## Drive ticks until the combat resolves. The cap mirrors auto_resolve's
	## iteration guard: a stuck tick loop (every side passing forever under a
	## huge stalemate limit) must force END with a warning instead of hanging.
	var run: int = 0
	while run < max_ticks and not _combat_over:
		run_tick()
		run += 1
	if not _combat_over:
		push_warning("TickCombatSession.run_until_end hit the tick cap (%d) at tick %d; forcing END" % [max_ticks, tick_number])
		_combat_over = true
		_transition_to(CombatState.Phase.END)


func serialize() -> Dictionary:
	## Extends the base snapshot with the tick state. super.serialize() carries
	## everything shared (decks + RNG, heroes, ai_states, event_log, command_log,
	## dead, teams); "mode" + the "tick" sub-dict are namespaced additions, the
	## same additive approach as trigger_mode/ai_states — the base format and
	## SCHEMA_VERSION stay untouched.
	var data: Dictionary = super.serialize()
	data["mode"] = "tick"
	data["tick"] = {
		"tick_number": tick_number,
		"recovery_ticks": _recovery_ticks.duplicate(),
		# Manual card intents by index, the same primitive encoding as
		# CombatCommand and the base attack pairs. A manual pass/attack intent
		# carries no state to keep: on resume the AI re-decides that side.
		"pending": _serialize_intents(),
		"economy": {
			"mana_refill_per_tick": mana_refill_per_tick,
			"mana_ramp_per_tick": mana_ramp_per_tick,
			"cards_drawn_per_tick": cards_drawn_per_tick,
		},
	}
	return data


static func deserialize(data: Dictionary, hooks: Dictionary = {}) -> TickCombatSession:
	## Rebuild a tick session from serialize(). A non-tick save is REJECTED
	## (warning + null) instead of degraded: resuming a sequential save under
	## another paradigm would silently diverge from its recorded event_log.
	## recovery_fn re-injects through `hooks` like every other Callable.
	if data.get("mode", "") != "tick":
		push_warning("TickCombatSession.deserialize: not a tick save (mode=%s); refusing to load" % str(data.get("mode", "<none>")))
		return null
	var session := TickCombatSession.new()
	session.recovery_fn = hooks.get("recovery_fn", Callable())
	session._restore_from(data, hooks)
	session._restore_tick(data)
	return session


static func deserialize_any(data: Dictionary, hooks: Dictionary = {}) -> CombatSession:
	## Dispatch by the saved paradigm: a "tick" save resumes as
	## TickCombatSession, anything else (legacy saves carry no mode key) as the
	## sequential base.
	if data.get("mode", "") == "tick":
		return deserialize(data, hooks)
	return CombatSession.deserialize(data, hooks)


func _serialize_intents() -> Array:
	_ensure_tick_arrays()
	var out: Array = []
	for side in _pending_intents.size():
		var intent = _pending_intents[side]
		if intent == null or intent.card == null:
			out.append(-1)
			continue
		var target_ref: Variant = null
		if intent.target is CardInstance:
			target_ref = {"side": intent.target.owner_id, "index": _board_index(intent.target)}
		out.append({
			"hand_index": decks[side].get_hand().find(intent.card),
			"hero_target_side": intent.target_side,
			"target_ref": target_ref,
		})
	return out


func _restore_tick(data: Dictionary) -> void:
	## Restore the tick sub-dict. Tolerant to absence like the base scalar
	## restores, with the defensive pad pattern of _restore_topology.
	_ensure_tick_arrays()
	var raw: Dictionary = data.get("tick", {})
	tick_number = int(raw.get("tick_number", 0))
	var saved_recovery: Array = raw.get("recovery_ticks", [])
	for side in mini(saved_recovery.size(), _recovery_ticks.size()):
		_recovery_ticks[side] = maxi(int(saved_recovery[side]), 0)
	var economy: Dictionary = raw.get("economy", {})
	mana_refill_per_tick = bool(economy.get("mana_refill_per_tick", true))
	mana_ramp_per_tick = bool(economy.get("mana_ramp_per_tick", true))
	cards_drawn_per_tick = maxi(int(economy.get("cards_drawn_per_tick", 0)), 0)
	_restore_intents(raw.get("pending", []))


func _restore_intents(saved: Array) -> void:
	for side in mini(saved.size(), _pending_intents.size()):
		var raw: Variant = saved[side]
		if not (raw is Dictionary):
			_pending_intents[side] = null
			continue
		var hand_index: int = int(raw.get("hand_index", -1))
		var hand: Array[CardData] = decks[side].get_hand()
		if hand_index < 0 or hand_index >= hand.size():
			_pending_intents[side] = null
			continue
		var intent := Intent.new()
		intent.side = side
		intent.card = hand[hand_index]
		intent.target_side = int(raw.get("hero_target_side", -1))
		var target_ref: Variant = raw.get("target_ref", null)
		if target_ref is Dictionary:
			intent.target = _board_at(int(target_ref.get("side", -1)), int(target_ref.get("index", -1)))
		_pending_intents[side] = intent


func declare_tick_intent(side: int, card: CardData = null, target: Variant = null, target_side: int = -1) -> bool:
	## Override ONE side's card selection for the next tick (card = null means
	## "swing with creatures"). The intent is consumed by the next run_tick; a
	## non-AI driver uses this exactly where the sequential paradigm would call
	## play_card. Execution is still revalidated: an unplayable or fizzled
	## intent is a pass, never a crash.
	_ensure_tick_arrays()
	if side < 0 or side >= side_count() or _is_side_out(side):
		return false
	var intent := Intent.new()
	intent.side = side
	intent.card = card
	intent.target = target
	intent.target_side = target_side
	_pending_intents[side] = intent
	return true


func recovery_remaining(side: int) -> int:
	## Ticks left before `side` may act again (0 = ready). 0 for an invalid
	## side, mirroring the base ability-facing mutators.
	_ensure_tick_arrays()
	if side < 0 or side >= _recovery_ticks.size():
		return 0
	return _recovery_ticks[side]


func _recovery_of(card: CardData, owner_id: int) -> int:
	## Ticks the side waits after playing `card`, per the injected hook. Empty
	## Callable = 0 for every card: recovery is opt-in exactly like cost_fn,
	## and the engine never reads card.metadata on its own.
	if not recovery_fn.is_valid():
		return 0
	return maxi(int(recovery_fn.call(card, owner_id)), 0)


func _apply_recovery(owner_id: int, card: CardData) -> void:
	## Arm recovery after a successful play. Takes the max, not the sum: a card
	## played while still winding down extends to its own window, never stacks.
	_ensure_tick_arrays()
	_recovery_ticks[owner_id] = maxi(_recovery_ticks[owner_id], _recovery_of(card, owner_id))


func _ensure_tick_arrays() -> void:
	## Size the per-side tick state lazily so setup()/setup_sides()/
	## deserialize() all land here without overriding any base setup path.
	for side in range(_recovery_ticks.size(), side_count()):
		_recovery_ticks.append(0)
	for side in range(_pending_intents.size(), side_count()):
		_pending_intents.append(null)


func _collect_intents(ready: Array[int]) -> Array:
	## Simultaneous selection: every ready side freezes ONE action against the
	## same post-upkeep board, before anything executes — no side sees another
	## side's in-flight choice. A manual intent (declare_tick_intent) overrides
	## the AI for that side and is consumed here.
	var intents: Array = []
	for side in ready:
		if _pending_intents[side] != null:
			intents.append(_pending_intents[side])
			_pending_intents[side] = null
			continue
		var deck: CombatDeck = decks[side]
		var skipped: Array[CardData] = []
		var card: CardData = ais[side].choose_card_to_play(_playable_hand(deck, skipped), deck.mana)
		var intent := Intent.new()
		intent.side = side
		intent.card = card
		if card != null and card.play_kind == CardData.PlayKind.EFFECT:
			intent.target = _ai_spell_target(card, side, ais[side])
		intents.append(intent)
	return intents


func _execute_play_intents(intents: Array) -> Array[int]:
	## Card plays resolve sequentially in side order, revalidated against the
	## live board: a declared target that already died this tick fizzles without
	## consuming the card (the base atomic-fizzle contract). Returns the sides
	## that actually played; they spend their tick action and do not attack too.
	var played: Array[int] = []
	for intent in intents:
		var side: int = intent.side
		if intent.card == null or _is_side_out(side):
			continue
		var deck: CombatDeck = decks[side]
		if not deck.can_play_card(intent.card):
			# The selection was frozen pre-execution; anything unaffordable or
			# gone by now is a silent pass, same rule as the auto-play skip.
			continue
		if intent.card.play_kind == CardData.PlayKind.EFFECT:
			if _spell_needs_missing_target(intent.card, intent.target):
				_emit_spell_fizzled(intent.card)
				continue
			deck.play_spell(intent.card)
			_apply_spell_effects(intent.card, side, intent.target, intent.target_side)
			_fire_cast_trigger(intent.card, side)
			if _effective_ability_fn.is_valid():
				_settle_reactive_triggers()
		else:
			var played_inst: CardInstance = deck.play_creature(intent.card)
			if played_inst == null:
				continue
			if _effective_ability_fn.is_valid():
				var play_target: Variant = ais[side].choose_play_target(intent.card, ally_boards(side), enemy_boards(side))
				played_inst._fire(CardInstance.Trigger.ON_PLAY, {"target": play_target})
				_settle_reactive_triggers(true)
			else:
				recompute_auras()
		_apply_recovery(side, intent.card)
		played.append(side)
	return played


func _tick_required_targets(attacker: CardInstance) -> Array:
	## Side-parameterized mirror of _required_attack_targets: the base version
	## flattens the ACTIVE side's enemies, which the tick paradigm never sets.
	## Here the restriction set comes from the attacker's own enemies.
	if not attack_restriction_fn.is_valid():
		return []
	return attack_restriction_fn.call(attacker, CardInstance.living(enemy_boards(attacker.owner_id)))


func _tick_redirect_for_restriction(attacker: CardInstance, chosen: Variant) -> Variant:
	## Mirror of _redirect_for_restriction over _tick_required_targets: map the
	## AI's choice to a legal one (keep it, force the first required creature,
	## or fall to a hero swing) without teaching the AI about TAUNT/STEALTH.
	var required: Array = _tick_required_targets(attacker)
	if _target_within_restriction(chosen, required):
		return chosen
	if not required.is_empty():
		return required[0]
	return null


func _tick_attack_allowed(attacker: CardInstance, target: Variant) -> bool:
	## Side-parameterized mirror of _attacker_declaration_rejection's per-side
	## rules, minus the phase gate (the tick loop only asks for ready sides).
	## Reads the attacker's OWN board/enemies instead of active_side's.
	if attacker == null:
		return false
	if not decks[attacker.owner_id].get_board().has(attacker):
		return false
	if not attacker.can_attack_this_turn or attacker.times_attacked >= attacker.attacks_per_turn:
		return false
	if not (target is CardInstance):
		if _default_enemy_side(attacker.owner_id) < 0:
			return false
	return _target_within_restriction(target, _tick_required_targets(attacker))


func _collect_attack_pairs(ready: Array[int], played: Array[int]) -> Array:
	## Every ready side that did not play a card swings with its creatures.
	## Mirrors the auto-play attacker flow (choose_attackers ->
	## choose_attack_target -> restriction redirect) per side, against each
	## attacker's own enemies. Pairs from ALL sides land in ONE array so the
	## batch resolves them simultaneously.
	var pairs: Array = []
	for side in ready:
		if played.has(side) or _is_side_out(side):
			continue
		var side_ai: CombatAI = ais[side]
		var enemy_heroes: Array[Combatant] = _living_enemy_heroes(side)
		var enemy_board: Array = enemy_boards(side)
		for attacker in side_ai.choose_attackers(decks[side].get_board(), enemy_heroes):
			var chosen: Variant = side_ai.choose_attack_target(attacker, enemy_board, enemy_heroes)
			var target: Variant = _tick_redirect_for_restriction(attacker, chosen)
			if not _tick_attack_allowed(attacker, target):
				continue
			var ts: int = -1
			if not (target is CardInstance):
				ts = _default_enemy_side(side)
			var pair := CombatPair.new(attacker, target)
			pair.target_side = ts
			attacker.has_attacked_this_turn = true
			attacker.times_attacked += 1
			pairs.append(pair)
			# Same per-declaration settle as declare_attacker: an ON_ATTACK
			# reaction resolves before the next pair is declared.
			if _effective_ability_fn.is_valid():
				attacker._fire(CardInstance.Trigger.ON_ATTACK, {"target": target})
				_settle_reactive_triggers()
	# Whiff filter: an attacker (or directed target) killed by an earlier
	# declaration's reactive trigger drops out of the batch, deterministically.
	var live_pairs: Array = []
	for pair in pairs:
		var attacker_live: bool = not pair.attacker.is_dead \
			and decks[pair.attacker.owner_id].get_board().has(pair.attacker)
		var target_live: bool = pair.defender == null \
			or (not pair.defender.is_dead and decks[pair.defender.owner_id].get_board().has(pair.defender))
		if attacker_live and target_live:
			live_pairs.append(pair)
	return live_pairs


func _resolve_tick_batch(pairs: Array) -> void:
	## Generalization of _resolve_active_attacks over the combined pairs of
	## EVERY side: ONE resolver call applies all combat damage simultaneously
	## (mutual trades across sides compute before anything applies), hero
	## damage aggregates per target_side in declaration order, then the shared
	## death pipeline (ON_DAMAGE_DEALT -> drain -> deaths).
	if pairs.is_empty():
		return
	var result: Dictionary = _resolver.resolve_combat(pairs)
	var pairs_result: Array = result["pairs_result"]
	var hero_damage_by_side: Dictionary = {}
	for i in pairs.size():
		if pairs[i].defender == null:
			var s: int = pairs[i].target_side
			hero_damage_by_side[s] = hero_damage_by_side.get(s, 0) + pairs_result[i]["attacker_damage_dealt"]
	for s in hero_damage_by_side:
		deal_damage_to_hero(s, hero_damage_by_side[s])
	if not pairs_result.is_empty():
		_fire_damage_dealt(pairs_result)
		_drain_triggers()
		_process_death_results(pairs_result)


func _living_sides() -> Array[int]:
	## Sides whose hero is still alive, in side-index order. Every tick stage
	## iterates this order so the run stays deterministic.
	var out: Array[int] = []
	for side in side_count():
		if not _is_side_out(side):
			out.append(side)
	return out


func _upkeep_tick() -> void:
	## Per-tick economy for every living side. The default refill+ramp reuses
	## _ramp_mana_for so the tick economy stays single-sourced with the
	## sequential one; the split cases cover the opt-out knobs.
	tick_number += 1
	# turn_number tracks ticks here so config.stalemate_turn_limit reads as a
	# tick limit and get_result() stays meaningful without touching the base.
	turn_number += 1
	for side in _living_sides():
		var deck: CombatDeck = decks[side]
		if _recovery_ticks[side] > 0:
			_recovery_ticks[side] -= 1
		if mana_refill_per_tick and mana_ramp_per_tick:
			_ramp_mana_for(deck)
		else:
			if mana_refill_per_tick:
				deck.gain_mana(deck.max_mana)
			if mana_ramp_per_tick and deck.max_mana < config.max_mana_cap:
				deck.increment_max_mana(mini(config.mana_ramp_per_turn, config.max_mana_cap - deck.max_mana))
		for _i in cards_drawn_per_tick:
			deck.draw_card()
		deck.refresh_creatures_for_turn()
		_fire_turn_trigger(side, CardInstance.Trigger.ON_TURN_START)
	if _effective_ability_fn.is_valid():
		_settle_reactive_triggers()


func _close_tick() -> void:
	## End-of-tick: ON_TURN_END for every living side (per-tick cadence here,
	## not per-alternating-turn), the TICK event, then one victory settle.
	for side in _living_sides():
		_fire_turn_trigger(side, CardInstance.Trigger.ON_TURN_END)
	if _effective_ability_fn.is_valid():
		_settle_reactive_triggers()
	_emit_tick()
	_check_victory()


func _emit_tick() -> void:
	## Same single-source pattern as the base _emit_* helpers: live signal plus
	## a TICK CombatEvent, so the event_log alone delimits ticks for replay/UI.
	tick_ended.emit(tick_number)
	if not _recording:
		return
	event_log.append(CombatEvent.new(CombatEvent.EventType.TICK, {"tick": tick_number}))
