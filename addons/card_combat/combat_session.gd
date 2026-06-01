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

class_name CombatSession
extends RefCounted
## Alternating-turn combat FSM: orchestrates turns, decks, AI and damage
## resolution. The model is symmetric per `side` (0/1) and agnostic to who drives
## each side (human UI, AI or a network peer), which makes it PvP-ready. On every
## turn one side is ACTIVE (takes its turn and attacks) and the other is PASSIVE
## (declares blockers). turn_number counts half-turns (one per side turn).

signal phase_changed(old_phase: int, new_phase: int)
signal combat_ended(winner_side: int)
signal creature_died(card: CardInstance, owner: int)
signal combatant_damaged(side: int, amount: int)
signal spell_fizzled(card: CardData)

# Safety guards (engine internals, not game balance): cap auto_resolve loop
# iterations and the number of card plays resolved automatically per turn.
const AUTO_RESOLVE_MAX_ITERATIONS := 200
const MAX_PLAYS_PER_TURN := 10

# Effective iteration cap for auto_resolve. Defaults to the const; overridable
# (e.g. tests) so the exhaustion path can be exercised without a pathological
# combat that never converges.
var _auto_resolve_max_iterations: int = AUTO_RESOLVE_MAX_ITERATIONS

var phase: CombatState.Phase = CombatState.Phase.INICIO
## Side taking its turn (0 or 1). The other side (1 - active_side) is passive.
var active_side: int = 0
## Winner once the combat ends: 0 or 1, or -1 for no winner (stalemate / both dead).
var winner_side: int = -1
## Heroes and decks indexed by side. Drivers (UI/AI/network) interact through the
## same per-side surface; the engine never assumes which side is "the player".
var heroes: Array[Combatant] = [null, null]
var decks: Array[CombatDeck] = [null, null]
## AI driver per side, used by auto_resolve(). Assign ais[side] before setup() to
## inject a custom controller; otherwise setup() seeds a reference DummyAI.
var ais: Array[CombatAI] = [null, null]
var turn_number: int = 0
# CombatPair declared by each side, indexed by side.
var _attack_pairs: Array = [[], []]
# attacker CardInstance -> blocker CardInstance, for the current turn.
var _block_assignments: Dictionary = {}
var _combat_over: bool = false
var _resolver: CombatDamageResolver = CombatDamageResolver.new()
# Creatures that died during combat, tracked per side for external retrieval.
var _dead_creatures: Array = [[], []]

## Structured, replay-friendly stream of what the combat did. Mirrors the signals
## below; the game layer can consume it instead of wiring each signal. Cleared on
## setup(). Card-level events (draw/play) live on CombatDeck, not here.
var event_log: Array[CombatEvent] = []

## Parámetros de balance. Reasignar antes de setup() para personalizar.
var config: CombatConfig = CombatConfig.new()

## Handler de habilidades. Lo inyecta la capa de juego antes de setup()
## (la capa-juego inyecta su handler de habilidades). Vacío = motor agnóstico.
var ability_fn: Callable = Callable()

## Optional damage formula hook, seeded into the resolver on setup().
## Signature: (attacker, defender) -> int. Empty = engine default.
var damage_fn: Callable = Callable()

## Optional fatigue hook, seeded into both decks on setup().
## Signature: (owner_id: int). Empty = decks only emit deck_exhausted.
var exhaust_fn: Callable = Callable()

## Optional overdraw hook, seeded into both decks on setup().
## Signature: (card: CardData, owner_id: int). Invoked when a drawn card is burned
## because the hand is full (see config.max_hand_size). Empty = burned silently.
var discard_fn: Callable = Callable()


func setup(side0_hero: Combatant, side0_cards: Array[CardData], side1_hero: Combatant, side1_cards: Array[CardData], ai_seed: int = -1) -> void:
	## Positional setup: side 0 = first hero/cards, side 1 = second hero/cards.
	heroes[0] = side0_hero
	heroes[1] = side1_hero

	# Seed the optional damage hook so the resolver uses it for this combat.
	_resolver.damage_fn = damage_fn

	# Derive a distinct shuffle seed per side from the combat seed so a fixed
	# ai_seed reproduces both deck orders. A negative seed leaves both decks
	# randomized (engine default).
	var seed0: int = ai_seed if ai_seed < 0 else ai_seed * 2 + 1
	var seed1: int = ai_seed if ai_seed < 0 else ai_seed * 2 + 2
	decks[0] = _make_deck(side0_cards, 0, seed0)
	decks[1] = _make_deck(side1_cards, 1, seed1)

	# Seed a reference AI per side unless a driver already assigned one.
	_seed_ai(0, ai_seed)
	_seed_ai(1, ai_seed)

	phase = CombatState.Phase.INICIO
	active_side = 0
	winner_side = -1
	turn_number = 0
	_attack_pairs = [[], []]
	_block_assignments.clear()
	_dead_creatures = [[], []]
	event_log.clear()
	_combat_over = false


func _make_deck(cards: Array[CardData], side: int, shuffle_seed: int) -> CombatDeck:
	var deck := CombatDeck.new()
	deck.setup(cards, side, config.starting_max_mana, ability_fn, config.max_permanent_buffs_per_card, shuffle_seed)
	deck.exhaust_fn = exhaust_fn
	deck.max_board_size = config.max_board_size
	deck.max_hand_size = config.max_hand_size
	deck.discard_fn = discard_fn
	deck.draw_initial_hand(config.initial_hand_size)
	return deck


func _seed_ai(side: int, ai_seed: int) -> void:
	## Honor an AI assigned to ais[side] before setup; otherwise seed a reference
	## DummyAI (deterministic for a fixed seed, distinct per side).
	if ais[side] != null:
		return
	var dummy := DummyAI.new()
	dummy.setup(ai_seed if ai_seed < 0 else ai_seed * 2 + side + 1)
	ais[side] = dummy


func start() -> void:
	_transition_to(CombatState.Phase.PREPARACION)


func play_card(card: CardData, as_hidden: bool = false, declared_attack: int = 0, declared_health: int = 0, target: Variant = null) -> bool:
	## Plays a card from the ACTIVE side's hand. `target` only applies to
	## single-target spells (e.g. PLAYER_CREATURE). A single-target spell cast with
	## no valid target fizzles: it is NOT consumed (mana and card stay),
	## `spell_fizzled` is emitted and play_card returns false. The caller is
	## responsible for picking a target and retrying.
	if not _can_play_from_hand(card):
		return false
	if card.card_type == CardData.CardType.HECHIZO:
		if _spell_needs_missing_target(card, target):
			_emit_spell_fizzled(card)
			return false
		if not _consume_spell(card):
			return false
		_apply_spell_effects(card, active_side, target)
		return true
	var inst: CardInstance = decks[active_side].play_creature(card, as_hidden, declared_attack, declared_health)
	return inst != null


func play_spell(card: CardData, effect: SpellEffect, target: Variant = null) -> bool:
	## Ad-hoc casting: applies a single externally-built SpellEffect to `target`,
	## bypassing the card's own TargetType-relative spell_effects. For normal
	## casting prefer play_card(card, ..., target), which honors the card's
	## declared spell_effects and target_type.
	if not _can_play_from_hand(card):
		return false
	if not _consume_spell(card):
		return false
	var context: Dictionary = {"session": self, "owner_id": active_side}
	effect.apply(target, context)
	return true


func _spell_needs_missing_target(card: CardData, target: Variant) -> bool:
	## A spell fizzles when any of its effects is single-target (PLAYER_CREATURE)
	## and no living creature target was provided. Casting is atomic: the whole
	## spell is rejected so a half-applied multi-effect card can't be consumed.
	if target is CardInstance and not target.is_dead:
		return false
	for effect in card.spell_effects:
		if effect.target_type == SpellEffect.TargetType.PLAYER_CREATURE:
			return true
	return false


func _can_play_from_hand(card: CardData) -> bool:
	## Shared precondition: a card can only be played from the active side's hand
	## during PRINCIPAL, while the combat is live and the deck can afford it.
	if phase != CombatState.Phase.PRINCIPAL:
		return false
	if _combat_over:
		return false
	return decks[active_side].can_play_card(card)


func _consume_spell(card: CardData) -> bool:
	## Single source of truth for moving a spell out of hand and spending mana.
	return decks[active_side].play_spell(card) != null


func declare_attacker(attacker: CardInstance, target: Variant = null) -> void:
	## Active-side action: declare an attacker, optionally directed at a passive
	## creature (`target`); null targets the passive hero. A blocker declared in
	## DEFENSA can later redirect this pair's damage.
	if phase != CombatState.Phase.PRINCIPAL and phase != CombatState.Phase.ATAQUE:
		return
	if _combat_over:
		return
	if attacker == null:
		return
	if not decks[active_side].get_board().has(attacker):
		return
	# Reject summoning-sick creatures and double declarations.
	if not attacker.can_attack_this_turn or attacker.has_attacked_this_turn:
		return
	var pair = CombatPair.new(attacker, target)
	_attack_pairs[active_side].append(pair)
	attacker.has_attacked_this_turn = true


func declare_blocker(attacker: CardInstance, blocker: CardInstance) -> void:
	## Passive-side action during DEFENSA: assign one of the passive side's
	## defenders to intercept an attacker declared by the active side. This
	## redirects that attack's damage to the blocker, overriding any directed
	## target. A blocker can only be assigned once per turn.
	if phase != CombatState.Phase.DEFENSA:
		return
	if _combat_over:
		return
	if attacker == null or blocker == null:
		return
	var passive: int = 1 - active_side
	if not decks[passive].get_defenders().has(blocker):
		return
	if blocker.is_dead:
		return
	if _block_assignments.values().has(blocker):
		return
	var pair: CombatPair = _find_attack_pair(attacker)
	if pair == null:
		return
	pair.defender = blocker
	_block_assignments[attacker] = blocker


func _find_attack_pair(attacker: CardInstance) -> CombatPair:
	for pair in _attack_pairs[active_side]:
		if pair.attacker == attacker:
			return pair
	return null


func end_main_phase() -> void:
	if phase != CombatState.Phase.PRINCIPAL:
		return
	_transition_to(CombatState.Phase.ATAQUE)


func end_attack_phase() -> void:
	if phase != CombatState.Phase.ATAQUE:
		return
	# A spell in PRINCIPAL may have already killed a hero: settle victory first.
	_check_victory()
	if _combat_over:
		return
	_transition_to(CombatState.Phase.DEFENSA)


func end_defense_phase() -> void:
	if phase != CombatState.Phase.DEFENSA:
		return
	_transition_to(CombatState.Phase.RESOLVER)


func advance() -> void:
	## Manual driver for the phases that need an external nudge. PREPARACION and
	## RESOLVER auto-chain inside their _enter_* handlers, and FINAL is terminal,
	## so only INICIO and PREPARACION are actionable here.
	match phase:
		CombatState.Phase.INICIO:
			start()
		CombatState.Phase.PREPARACION:
			# Auto-advance to PRINCIPAL
			_transition_to(CombatState.Phase.PRINCIPAL)


func get_result() -> Dictionary:
	return {
		"winner_side": winner_side,
		"turn_number": turn_number,
		"hp": [
			heroes[0].current_health if heroes[0] != null else 0,
			heroes[1].current_health if heroes[1] != null else 0,
		],
	}


func get_dead_creatures(side: int) -> Array:
	if decks[side] == null:
		return []
	return _dead_creatures[side]


func auto_resolve() -> void:
	## Drives the whole combat headless using the per-side AIs in `ais` (seeded in
	## setup, or injected by a driver before setup). Deterministic for a fixed seed.
	start()
	var iterations_left: int = _auto_resolve_max_iterations
	while phase != CombatState.Phase.FINAL and not _combat_over and iterations_left > 0:
		iterations_left -= 1
		match phase:
			CombatState.Phase.PRINCIPAL:
				_auto_play_active()
				end_main_phase()
			CombatState.Phase.ATAQUE:
				end_attack_phase()
			CombatState.Phase.DEFENSA:
				_auto_declare_blockers()
				end_defense_phase()
			CombatState.Phase.PREPARACION, CombatState.Phase.RESOLVER:
				pass
	if not _combat_over:
		# Loop exhausted before the combat resolved on its own: force FINAL but
		# warn with diagnostics, since a silent termination hides a stuck combat.
		if iterations_left <= 0:
			push_warning("CombatSession.auto_resolve hit the iteration cap (%d) at turn %d, phase %s; forcing FINAL" % [_auto_resolve_max_iterations, turn_number, CombatState.phase_name(phase)])
		_combat_over = true
		_transition_to(CombatState.Phase.FINAL)


func _auto_play_active() -> void:
	## Headless turn of the active side: play its hand, then declare attackers
	## (optionally directed) via its AI.
	var side: int = active_side
	var deck: CombatDeck = decks[side]
	var side_ai: CombatAI = ais[side]
	_play_hand(deck, side, side_ai)
	var passive_board: Array[CardInstance] = decks[1 - side].get_defenders()
	var attackers: Array[CardInstance] = side_ai.choose_attackers(deck.get_board())
	for attacker in attackers:
		var target: Variant = side_ai.choose_attack_target(attacker, passive_board)
		declare_attacker(attacker, target)


func _auto_declare_blockers() -> void:
	## Headless defense: the passive side's AI assigns blockers to the active
	## side's attackers.
	var passive: int = 1 - active_side
	var def_ai: CombatAI = ais[passive]
	var attackers: Array[CardInstance] = []
	for pair in _attack_pairs[active_side]:
		attackers.append(pair.attacker)
	if attackers.is_empty():
		return
	var own_board: Array[CardInstance] = decks[passive].get_defenders()
	var blocks: Dictionary = def_ai.choose_blockers(attackers, own_board)
	for attacker in blocks:
		declare_blocker(attacker, blocks[attacker])


func _snapshot_hand(deck: CombatDeck) -> Array[CardData]:
	## Typed copy of a deck's hand, so the AI sees a stable list while we mutate
	## the real hand by playing cards out of it.
	var hand: Array[CardData] = []
	for card in deck.get_hand():
		hand.append(card)
	return hand


func _play_hand(deck: CombatDeck, side: int, side_ai: CombatAI) -> void:
	## Plays cards from `side`'s hand until the AI passes or the per-turn cap is
	## hit. Shared by both sides' auto-play so spells and creatures resolve the
	## same way regardless of who is active. A single-target spell asks the AI for
	## a target; if none fits it is skipped (not consumed) and hidden from the AI
	## for the rest of the turn so it isn't re-picked uselessly.
	var skipped: Array[CardData] = []
	var card_to_play: CardData = side_ai.choose_card_to_play(_playable_hand(deck, skipped), deck.mana)
	var plays: int = 0
	while card_to_play != null and plays < MAX_PLAYS_PER_TURN:
		if card_to_play.card_type == CardData.CardType.HECHIZO:
			var target: Variant = _ai_spell_target(card_to_play, side, side_ai)
			if _spell_needs_missing_target(card_to_play, target):
				skipped.append(card_to_play)
			else:
				deck.play_spell(card_to_play)
				_apply_spell_effects(card_to_play, side, target)
				plays += 1
		else:
			deck.play_creature(card_to_play)
			plays += 1
		card_to_play = side_ai.choose_card_to_play(_playable_hand(deck, skipped), deck.mana)


func _ai_spell_target(card: CardData, side: int, side_ai: CombatAI) -> Variant:
	## Consult the AI for a single-target spell's target. Other spells resolve
	## relative to the caster, so they need no explicit target.
	if not _spell_is_single_target(card):
		return null
	return side_ai.choose_spell_target(card, decks[side].get_board(), decks[1 - side].get_board())


func _spell_is_single_target(card: CardData) -> bool:
	for effect in card.spell_effects:
		if effect.target_type == SpellEffect.TargetType.PLAYER_CREATURE:
			return true
	return false


func _playable_hand(deck: CombatDeck, skipped: Array[CardData]) -> Array[CardData]:
	## Hand snapshot minus cards already skipped this turn (e.g. untargetable
	## single-target spells), so the AI doesn't keep re-picking them.
	var hand: Array[CardData] = []
	for card in _snapshot_hand(deck):
		if not skipped.has(card):
			hand.append(card)
	return hand


func _transition_to(new_phase: CombatState.Phase) -> void:
	var old_phase: CombatState.Phase = phase
	phase = new_phase
	_emit_phase_changed(old_phase, new_phase)
	_enter_phase(new_phase)


# --- Signal + event-log emitters (single source for each combat event) ---
# Each helper emits the signal AND appends a structured CombatEvent, so existing
# listeners keep working while event_log offers a replay-friendly stream.

func _emit_phase_changed(old_phase: int, new_phase: int) -> void:
	phase_changed.emit(old_phase, new_phase)
	event_log.append(CombatEvent.new(CombatEvent.EventType.PHASE_CHANGED, {
		"old_phase": old_phase, "new_phase": new_phase,
	}))


func _emit_combatant_damaged(side: int, amount: int) -> void:
	combatant_damaged.emit(side, amount)
	event_log.append(CombatEvent.new(CombatEvent.EventType.COMBATANT_DAMAGED, {
		"side": side, "amount": amount,
	}))


func _emit_creature_died(card: CardInstance, owner: int) -> void:
	creature_died.emit(card, owner)
	var card_id: String = card.card_data.card_id if card.card_data != null else ""
	event_log.append(CombatEvent.new(CombatEvent.EventType.CREATURE_DIED, {
		"owner": owner, "card_id": card_id,
	}))


func _emit_combat_ended(winner: int) -> void:
	combat_ended.emit(winner)
	event_log.append(CombatEvent.new(CombatEvent.EventType.COMBAT_ENDED, {"winner_side": winner}))


func _emit_spell_fizzled(card: CardData) -> void:
	spell_fizzled.emit(card)
	var card_id: String = card.card_id if card != null else ""
	event_log.append(CombatEvent.new(CombatEvent.EventType.SPELL_FIZZLED, {"card_id": card_id}))


func _enter_phase(p: CombatState.Phase) -> void:
	match p:
		CombatState.Phase.PREPARACION:
			_enter_preparacion()
		CombatState.Phase.PRINCIPAL:
			_enter_principal()
		CombatState.Phase.ATAQUE:
			_enter_ataque()
		CombatState.Phase.DEFENSA:
			_enter_defensa()
		CombatState.Phase.RESOLVER:
			_enter_resolve()
		CombatState.Phase.FINAL:
			_enter_final()


func _enter_preparacion() -> void:
	turn_number += 1

	# Only the active side ramps mana, draws and refreshes on its own turn.
	var deck: CombatDeck = decks[active_side]
	_ramp_mana_for(deck)
	deck.draw_card()
	deck.refresh_creatures_for_turn()

	# Clear the active side's attack state from its previous turn.
	_attack_pairs[active_side].clear()
	_block_assignments.clear()

	# Auto-advance to PRINCIPAL
	_transition_to(CombatState.Phase.PRINCIPAL)


func _ramp_mana_for(deck: CombatDeck) -> void:
	## Per-turn mana: refill to the current max, then ramp the max up toward
	## config.max_mana_cap. Same rule for both sides; extracted to keep it single-
	## sourced.
	deck.gain_mana(deck.max_mana)
	if deck.max_mana < config.max_mana_cap:
		deck.increment_max_mana(mini(config.mana_ramp_per_turn, config.max_mana_cap - deck.max_mana))


func _enter_principal() -> void:
	if _combat_over:
		return


func _enter_ataque() -> void:
	if _combat_over:
		return


func _enter_defensa() -> void:
	# Blocking is driver-driven (declare_blocker / auto_resolve), so the engine
	# does not auto-assign here — that would assume the passive side is an AI.
	if _combat_over:
		return


func _enter_resolve() -> void:
	# Resolve the active side's declared attacks against the passive side.
	var passive: int = 1 - active_side
	_resolve_side_attacks(_attack_pairs[active_side], heroes[passive], passive)
	_attack_pairs[active_side].clear()
	_block_assignments.clear()

	_check_victory()
	if _combat_over:
		return

	# Hand the turn to the other side.
	active_side = passive
	_transition_to(CombatState.Phase.PREPARACION)


func _resolve_side_attacks(pairs: Array, target_hero: Combatant, target_side: int) -> void:
	## Resolves one side's declared attacks: deals unblocked damage to the target
	## hero (emitting combatant_damaged for target_side) and processes the
	## resulting creature deaths.
	if pairs.is_empty():
		return
	var result: Dictionary = _resolver.resolve_combat(pairs)
	_damage_hero(target_side, result["hero_damage"])
	var pairs_result: Array = result["pairs_result"]
	if not pairs_result.is_empty():
		_process_death_results(pairs_result)


func _enter_final() -> void:
	if not _combat_over:
		_combat_over = true
	_resolve_winner()
	_emit_combat_ended(winner_side)


func _resolve_winner() -> void:
	## A side wins when the opposing hero is dead and its own is not. Both dead or
	## a stalemate leaves no winner (-1).
	var dead0: bool = heroes[0] != null and heroes[0].current_health <= 0
	var dead1: bool = heroes[1] != null and heroes[1].current_health <= 0
	if dead1 and not dead0:
		winner_side = 0
	elif dead0 and not dead1:
		winner_side = 1
	else:
		winner_side = -1


func _process_death_results(pairs_result: Array) -> void:
	for pr in pairs_result:
		var attacker: CardInstance = pr["attacker"]
		var defender: Variant = pr["defender"]
		if pr["attacker_died"]:
			_record_death(attacker)
		if defender != null and pr["defender_died"]:
			_record_death(defender)
	# Remove dead from both boards.
	decks[0].remove_dead_creatures()
	decks[1].remove_dead_creatures()


func _record_death(inst: CardInstance) -> void:
	## Idempotent: a creature is recorded and announced once. This lets spell
	## resolution sweep boards repeatedly without double-emitting creature_died.
	var side: int = inst.owner_id
	if _dead_creatures[side].has(inst):
		return
	_dead_creatures[side].append(inst)
	_emit_creature_died(inst, side)


func _check_victory() -> void:
	var dead_hero: bool = heroes[0].current_health <= 0 or heroes[1].current_health <= 0
	if dead_hero or _is_stalemate():
		_combat_over = true
		_transition_to(CombatState.Phase.FINAL)


func _is_stalemate() -> bool:
	var s0_nothing: bool = decks[0].hand_size == 0 and decks[0].board_size == 0 and decks[0].draw_pile_size == 0
	var s1_nothing: bool = decks[1].hand_size == 0 and decks[1].board_size == 0 and decks[1].draw_pile_size == 0
	if s0_nothing and s1_nothing:
		return true
	if turn_number >= config.stalemate_turn_limit:
		return true
	return false


func _apply_spell_effects(card: CardData, side: int, target: Variant = null) -> void:
	for effect in card.spell_effects:
		_apply_single_spell_effect(effect, side, target)


func _apply_single_spell_effect(effect: SpellEffect, side: int, target: Variant = null) -> void:
	## Resolución agnóstica desde la óptica del lanzador (`side`). TargetType se
	## interpreta relativo al lanzador, así un mismo hechizo sirve a ambos lados
	## sin lógica duplicada.
	var caster_hero: Combatant = heroes[side]
	var caster_deck: CombatDeck = decks[side]
	var opponent_deck: CombatDeck = decks[1 - side]
	match effect.target_type:
		SpellEffect.TargetType.ENEMY_HERO:
			_damage_hero(1 - side, effect.value)
		SpellEffect.TargetType.PLAYER_HERO:
			caster_hero.heal(effect.value)
		SpellEffect.TargetType.PLAYER_CREATURE:
			# Public casting via play_card() already rejects a missing target before
			# consuming (see _spell_needs_missing_target). This is a low-level guard
			# for internal callers (e.g. auto-play) that bypass that check.
			if target is CardInstance and not target.is_dead:
				effect.apply(target, {})
				# A single-target damage can kill: surface that death like any other.
				_check_board_deaths(decks[target.owner_id])
			else:
				push_warning("PLAYER_CREATURE spell with no valid target — not applied")
		SpellEffect.TargetType.ENEMY_CREATURES:
			var enemies: Array[CardInstance] = opponent_deck.get_board()
			effect.apply(enemies, {})
			_check_board_deaths(opponent_deck)
		SpellEffect.TargetType.PLAYER_CREATURES:
			var allies: Array[CardInstance] = caster_deck.get_board()
			effect.apply(allies, {})
		SpellEffect.TargetType.SUMMON_BOARD:
			# Seed the deck-owned hooks via context so _apply_summon builds the
			# instances already configured (fires ON_SETUP with the handler).
			var result: Dictionary = effect.apply(null, {
				"owner_id": side,
				"ability_fn": caster_deck.ability_fn,
				"max_permanent_buffs": caster_deck.max_permanent_buffs,
			})
			var summoned: Array = result.get("summoned", [])
			for inst in summoned:
				caster_deck.add_to_board(inst)


func _damage_hero(side: int, amount: int) -> void:
	if amount <= 0:
		return
	heroes[side].take_damage(amount)
	_emit_combatant_damaged(side, amount)


func _check_board_deaths(deck: CombatDeck) -> void:
	## Spell-caused deaths must surface like combat deaths: record them (emits
	## creature_died, appends CREATURE_DIED to event_log, tracks get_dead_creatures)
	## before removing them from the board. Otherwise an AOE/single-target kill would
	## be invisible to the event_log and break replay.
	var dead: Array[CardInstance] = []
	for inst in deck.get_board():
		if inst.is_dead:
			dead.append(inst)
	for inst in dead:
		_record_death(inst)
		deck.remove_from_board(inst)
