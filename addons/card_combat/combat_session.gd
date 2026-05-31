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
## FSM de combate PVE: orquesta turnos, mazos, IA y resolucion de dano.

signal phase_changed(old_phase: int, new_phase: int)
signal combat_ended(player_won: bool)
signal creature_died(card: CardInstance, owner: int)
signal hero_damaged(amount: int)
signal enemy_damaged(amount: int)

# Safety guards (engine internals, not game balance): cap auto_resolve loop
# iterations and the number of card plays resolved automatically per turn.
const AUTO_RESOLVE_MAX_ITERATIONS := 200
const MAX_PLAYS_PER_TURN := 10

# Effective iteration cap for auto_resolve. Defaults to the const; overridable
# (e.g. tests) so the exhaustion path can be exercised without a pathological
# combat that never converges.
var _auto_resolve_max_iterations: int = AUTO_RESOLVE_MAX_ITERATIONS

var phase: CombatState.Phase = CombatState.Phase.INICIO
var player_deck: CombatDeck = null
var enemy_deck: CombatDeck = null
var player_hero: Combatant = null
var enemy: Combatant = null
var ai: CombatAI = null
var turn_number: int = 0
var _player_attack_pairs: Array = []  # Array[CombatPair] - player declared
var _ai_attack_pairs: Array = []  # Array[CombatPair] - AI declared
var _block_assignments: Dictionary = {}  # attacker CardInstance -> blocker CardInstance
var _combat_over: bool = false
var _resolver: CombatDamageResolver = CombatDamageResolver.new()
# Creatures that died during combat, tracked per side for external retrieval.
var _dead_player_creatures: Array[CardInstance] = []
var _dead_enemy_creatures: Array[CardInstance] = []

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


func setup(hero: Combatant, hero_cards: Array[CardData], enemy_combatant: Combatant, enemy_cards: Array[CardData], ai_seed: int = -1) -> void:
	player_hero = hero
	enemy = enemy_combatant

	# Seed the optional damage hook so the resolver uses it for this combat.
	_resolver.damage_fn = damage_fn

	# Derive a distinct shuffle seed per side from the combat seed so a fixed
	# ai_seed reproduces both deck orders. A negative seed leaves both decks
	# randomized (engine default).
	var player_shuffle_seed: int = ai_seed if ai_seed < 0 else ai_seed * 2 + 1
	var enemy_shuffle_seed: int = ai_seed if ai_seed < 0 else ai_seed * 2 + 2

	player_deck = CombatDeck.new()
	player_deck.setup(hero_cards, 0, config.starting_max_mana, ability_fn, config.max_permanent_buffs_per_card, player_shuffle_seed)
	player_deck.exhaust_fn = exhaust_fn
	player_deck.draw_initial_hand(config.initial_hand_size)

	enemy_deck = CombatDeck.new()
	enemy_deck.setup(enemy_cards, 1, config.starting_max_mana, ability_fn, config.max_permanent_buffs_per_card, enemy_shuffle_seed)
	enemy_deck.exhaust_fn = exhaust_fn
	enemy_deck.draw_initial_hand(config.initial_hand_size)

	# Injectable: honor an AI assigned before setup() (must follow the DummyAI
	# contract); otherwise fall back to the seeded reference AI.
	if ai == null:
		ai = DummyAI.new()
		ai.setup(ai_seed)

	phase = CombatState.Phase.INICIO
	turn_number = 0
	_player_attack_pairs.clear()
	_ai_attack_pairs.clear()
	_block_assignments.clear()
	_dead_player_creatures.clear()
	_dead_enemy_creatures.clear()
	event_log.clear()
	_combat_over = false


func start() -> void:
	_transition_to(CombatState.Phase.PREPARACION)


func play_card(card: CardData, as_hidden: bool = false, declared_attack: int = 0, declared_health: int = 0, target: Variant = null) -> bool:
	## `target` only applies to single-target spells (e.g. PLAYER_CREATURE); when
	## null, single-target effects fall back to their default pick (board[0]).
	if not _can_play_from_hand(card):
		return false
	if card.card_type == CardData.CardType.HECHIZO:
		if not _consume_spell(card):
			return false
		_apply_spell_effects(card, 0, target)
		return true
	var inst: CardInstance = player_deck.play_creature(card, as_hidden, declared_attack, declared_health)
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
	var context: Dictionary = {"session": self, "owner_id": 0}
	effect.apply(target, context)
	return true


func _can_play_from_hand(card: CardData) -> bool:
	## Shared precondition: a card can only be played from hand during PRINCIPAL,
	## while the combat is live and the deck can afford it.
	if phase != CombatState.Phase.PRINCIPAL:
		return false
	if _combat_over:
		return false
	return player_deck.can_play_card(card)


func _consume_spell(card: CardData) -> bool:
	## Single source of truth for moving a spell out of hand and spending mana.
	return player_deck.play_spell(card) != null


func declare_attacker(attacker: CardInstance, target: Variant = null) -> void:
	if phase != CombatState.Phase.PRINCIPAL and phase != CombatState.Phase.ATAQUE:
		return
	if _combat_over:
		return
	if attacker == null:
		return
	# Only allow player creatures
	if not player_deck.get_board().has(attacker):
		return
	# Reject summoning-sick creatures and double declarations.
	if not attacker.can_attack_this_turn or attacker.has_attacked_this_turn:
		return
	var pair = CombatPair.new(attacker, target)
	_player_attack_pairs.append(pair)
	attacker.has_attacked_this_turn = true


func end_main_phase() -> void:
	if phase != CombatState.Phase.PRINCIPAL:
		return
	_transition_to(CombatState.Phase.ATAQUE)


func end_attack_phase() -> void:
	if phase != CombatState.Phase.ATAQUE:
		return
	# If no attackers and enemy is dead, go to final
	if _player_attack_pairs.is_empty() and _ai_attack_pairs.is_empty() and enemy.current_health <= 0:
		_transition_to(CombatState.Phase.FINAL)
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
	var player_won: bool = enemy.current_health <= 0
	return {
		"player_won": player_won,
		"turn_number": turn_number,
		"hero_hp": player_hero.current_health if player_hero != null else 0,
		"enemy_hp": enemy.current_health if enemy != null else 0,
	}


func get_dead_player_creatures() -> Array[CardInstance]:
	if player_deck == null:
		return []
	return _dead_player_creatures


func get_dead_enemy_creatures() -> Array[CardInstance]:
	if enemy_deck == null:
		return []
	return _dead_enemy_creatures


func auto_resolve(player_ai: CombatAI = null, player_ai_seed: int = 99) -> void:
	## Drives the whole combat headless. Honors an injected player AI; when null,
	## falls back to a seeded reference DummyAI (deterministic for a fixed seed).
	if player_ai == null:
		var dummy := DummyAI.new()
		dummy.setup(player_ai_seed)
		player_ai = dummy
	start()
	var iterations_left: int = _auto_resolve_max_iterations
	while phase != CombatState.Phase.FINAL and not _combat_over and iterations_left > 0:
		iterations_left -= 1
		match phase:
			CombatState.Phase.PRINCIPAL:
				_auto_play_player(player_ai)
				end_main_phase()
			CombatState.Phase.ATAQUE:
				end_attack_phase()
			CombatState.Phase.DEFENSA:
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


func _auto_play_player(player_ai: CombatAI) -> void:
	_play_hand(player_deck, 0, player_ai)
	var attackers: Array[CardInstance] = player_ai.choose_attackers(player_deck.get_board())
	var enemy_board: Array[CardInstance] = enemy_deck.get_defenders()
	for attacker in attackers:
		var target: Variant = player_ai.choose_attack_target(attacker, enemy_board)
		declare_attacker(attacker, target)


func _snapshot_hand(deck: CombatDeck) -> Array[CardData]:
	## Typed copy of a deck's hand, so the AI sees a stable list while we mutate
	## the real hand by playing cards out of it.
	var hand: Array[CardData] = []
	for card in deck.get_hand():
		hand.append(card)
	return hand


func _play_hand(deck: CombatDeck, side: int, side_ai: CombatAI) -> void:
	## Plays cards from `side`'s hand until the AI passes or the per-turn cap is
	## hit. Shared by the player's auto-play and the AI's turn so both resolve
	## spells and creatures the same way.
	var card_to_play: CardData = side_ai.choose_card_to_play(_snapshot_hand(deck), deck.mana)
	var plays: int = 0
	while card_to_play != null and plays < MAX_PLAYS_PER_TURN:
		if card_to_play.card_type == CardData.CardType.HECHIZO:
			deck.play_spell(card_to_play)
			_apply_spell_effects(card_to_play, side)
		else:
			deck.play_creature(card_to_play)
		plays += 1
		card_to_play = side_ai.choose_card_to_play(_snapshot_hand(deck), deck.mana)


func _transition_to(new_phase: CombatState.Phase) -> void:
	var old_phase: CombatState.Phase = phase
	phase = new_phase
	_emit_phase_changed(old_phase, new_phase)
	_enter_phase(new_phase)


# --- Signal + event-log emitters (single source for each combat event) ---
# Each helper emits the legacy signal AND appends a structured CombatEvent, so
# existing listeners keep working while event_log offers a replay-friendly stream.

func _emit_phase_changed(old_phase: int, new_phase: int) -> void:
	phase_changed.emit(old_phase, new_phase)
	event_log.append(CombatEvent.new(CombatEvent.EventType.PHASE_CHANGED, {
		"old_phase": old_phase, "new_phase": new_phase,
	}))


func _emit_hero_damaged(amount: int) -> void:
	hero_damaged.emit(amount)
	event_log.append(CombatEvent.new(CombatEvent.EventType.HERO_DAMAGED, {"amount": amount}))


func _emit_enemy_damaged(amount: int) -> void:
	enemy_damaged.emit(amount)
	event_log.append(CombatEvent.new(CombatEvent.EventType.ENEMY_DAMAGED, {"amount": amount}))


func _emit_creature_died(card: CardInstance, owner: int) -> void:
	creature_died.emit(card, owner)
	var card_id: String = card.card_data.card_id if card.card_data != null else ""
	event_log.append(CombatEvent.new(CombatEvent.EventType.CREATURE_DIED, {
		"owner": owner, "card_id": card_id,
	}))


func _emit_combat_ended(player_won: bool) -> void:
	combat_ended.emit(player_won)
	event_log.append(CombatEvent.new(CombatEvent.EventType.COMBAT_ENDED, {"player_won": player_won}))


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

	_ramp_mana_for(player_deck)
	player_deck.draw_card()
	player_deck.refresh_creatures_for_turn()

	_ramp_mana_for(enemy_deck)
	enemy_deck.draw_card()
	enemy_deck.refresh_creatures_for_turn()

	# Clear attack state from previous turn
	_player_attack_pairs.clear()
	_ai_attack_pairs.clear()
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
	if _combat_over:
		return
	# IA assigns blockers for each player attacker
	var enemy_board: Array[CardInstance] = enemy_deck.get_defenders()
	if not _player_attack_pairs.is_empty() and not enemy_board.is_empty():
		var attackers: Array[CardInstance] = []
		for pair in _player_attack_pairs:
			attackers.append(pair.attacker)
		_block_assignments = ai.choose_blockers(attackers, enemy_board)
		for pair in _player_attack_pairs:
			if _block_assignments.has(pair.attacker):
				pair.defender = _block_assignments[pair.attacker]


func _enter_resolve() -> void:
	# --- Resolve player attacks ---
	_resolve_side_attacks(_player_attack_pairs, enemy)
	_player_attack_pairs.clear()
	_block_assignments.clear()

	_check_victory()
	if _combat_over:
		return

	# --- AI turn: play cards + declare attacks ---
	_run_ai_turn()

	# --- Resolve AI attacks ---
	_resolve_side_attacks(_ai_attack_pairs, player_hero)
	_ai_attack_pairs.clear()

	_check_victory()
	if not _combat_over:
		_transition_to(CombatState.Phase.PREPARACION)


func _resolve_side_attacks(pairs: Array, target_hero: Combatant) -> void:
	## Resolves one side's declared attacks: deals unblocked damage to the target
	## hero (via _damage_hero, which routes the right signal) and processes the
	## resulting creature deaths. Shared by the player and AI resolution blocks.
	if pairs.is_empty():
		return
	var result: Dictionary = _resolver.resolve_combat(pairs, target_hero.current_health)
	_damage_hero(target_hero, result["hero_damage"])
	var pairs_result: Array = result["pairs_result"]
	if not pairs_result.is_empty():
		_process_death_results(pairs_result)


func _enter_final() -> void:
	if not _combat_over:
		_combat_over = true
	var player_won: bool = enemy.current_health <= 0
	_emit_combat_ended(player_won)


func _run_ai_turn() -> void:
	_play_hand(enemy_deck, 1, ai)

	# AI declares attackers
	var ai_attackers: Array[CardInstance] = ai.choose_attackers(enemy_deck.get_board())
	var player_board: Array[CardInstance] = player_deck.get_defenders()

	# AI attack pairs stored separately for resolve phase
	for attacker in ai_attackers:
		var target: Variant = ai.choose_attack_target(attacker, player_board)
		var pair = CombatPair.new(attacker, target)
		_ai_attack_pairs.append(pair)


func _process_death_results(pairs_result: Array) -> void:
	var dead_player: Array[CardInstance] = []
	var dead_enemy: Array[CardInstance] = []

	for pr in pairs_result:
		var attacker: CardInstance = pr["attacker"]
		var defender: Variant = pr["defender"]

		if pr["attacker_died"]:
			if attacker.owner_id == 0:
				dead_player.append(attacker)
			else:
				dead_enemy.append(attacker)
			_emit_creature_died(attacker, attacker.owner_id)

		if defender != null and pr["defender_died"]:
			if defender.owner_id == 0:
				dead_player.append(defender)
			else:
				dead_enemy.append(defender)
			_emit_creature_died(defender, defender.owner_id)

	# Track dead creatures per side for external retrieval
	for inst in dead_player:
		if not _dead_player_creatures.has(inst):
			_dead_player_creatures.append(inst)
	for inst in dead_enemy:
		if not _dead_enemy_creatures.has(inst):
			_dead_enemy_creatures.append(inst)

	# Remove dead from boards
	player_deck.remove_dead_creatures()
	enemy_deck.remove_dead_creatures()


func _check_victory() -> void:
	if enemy.current_health <= 0:
		_combat_over = true
		_transition_to(CombatState.Phase.FINAL)
	elif player_hero != null and player_hero.current_health <= 0:
		_combat_over = true
		_transition_to(CombatState.Phase.FINAL)
	elif _is_stalemate():
		_combat_over = true
		_transition_to(CombatState.Phase.FINAL)


func _is_stalemate() -> bool:
	var player_has_nothing: bool = player_deck.hand_size == 0 and player_deck.board_size == 0 and player_deck.draw_pile_size == 0
	var enemy_has_nothing: bool = enemy_deck.hand_size == 0 and enemy_deck.board_size == 0 and enemy_deck.draw_pile_size == 0
	if player_has_nothing and enemy_has_nothing:
		return true
	if turn_number >= config.stalemate_turn_limit:
		return true
	return false


func _apply_spell_effects(card: CardData, side: int, target: Variant = null) -> void:
	for effect in card.spell_effects:
		_apply_single_spell_effect(effect, side, target)


func _apply_single_spell_effect(effect: SpellEffect, side: int, target: Variant = null) -> void:
	## Resolución agnóstica desde la óptica del lanzador (side 0 = jugador,
	## 1 = enemigo). TargetType se interpreta relativo al lanzador, así un mismo
	## hechizo sirve a ambos lados sin lógica duplicada.
	var caster_hero: Combatant = player_hero if side == 0 else enemy
	var opponent_hero: Combatant = enemy if side == 0 else player_hero
	var caster_deck: CombatDeck = player_deck if side == 0 else enemy_deck
	var opponent_deck: CombatDeck = enemy_deck if side == 0 else player_deck
	match effect.target_type:
		SpellEffect.TargetType.ENEMY_HERO:
			_damage_hero(opponent_hero, effect.value)
		SpellEffect.TargetType.PLAYER_HERO:
			caster_hero.heal(effect.value)
		SpellEffect.TargetType.PLAYER_CREATURE:
			# Use the explicit target when provided; otherwise fall back to the
			# first creature on the caster's board for backward compatibility.
			if target is CardInstance and not target.is_dead:
				effect.apply(target, {})
			else:
				var board: Array[CardInstance] = caster_deck.get_board()
				if not board.is_empty():
					effect.apply(board[0], {})
		SpellEffect.TargetType.ENEMY_CREATURES:
			var enemies: Array[CardInstance] = opponent_deck.get_board()
			effect.apply(enemies, {})
			_check_board_deaths(opponent_deck)
		SpellEffect.TargetType.PLAYER_CREATURES:
			var allies: Array[CardInstance] = caster_deck.get_board()
			effect.apply(allies, {})
		SpellEffect.TargetType.SUMMON_BOARD:
			var result: Dictionary = effect.apply(null, {"owner_id": side})
			var summoned: Array = result.get("summoned", [])
			for inst in summoned:
				inst.ability_fn = caster_deck.ability_fn
				inst.max_permanent_buffs = caster_deck.max_permanent_buffs
				caster_deck.add_to_board(inst)


func _damage_hero(hero: Combatant, amount: int) -> void:
	if amount <= 0:
		return
	hero.take_damage(amount)
	if hero == enemy:
		_emit_enemy_damaged(amount)
	elif hero == player_hero:
		_emit_hero_damaged(amount)


func _check_board_deaths(deck: CombatDeck) -> void:
	var dead: Array[CardInstance] = []
	for inst in deck.get_board():
		if inst.is_dead:
			dead.append(inst)
	for inst in dead:
		deck.remove_from_board(inst)
		_emit_creature_died(inst, inst.owner_id)
