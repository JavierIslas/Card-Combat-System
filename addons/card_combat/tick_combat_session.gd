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
	_upkeep_tick()
	_close_tick()
	return true


func _ensure_tick_arrays() -> void:
	## Size the per-side tick state lazily so setup()/setup_sides()/
	## deserialize() all land here without overriding any base setup path.
	for side in range(_recovery_ticks.size(), side_count()):
		_recovery_ticks.append(0)


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
