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
# Player creatures that died during combat, tracked for external retrieval.
var _dead_player_creatures: Array[CardInstance] = []

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
	match phase:
		CombatState.Phase.INICIO:
			start()
		CombatState.Phase.PREPARACION:
			# Auto-advance to PRINCIPAL
			_transition_to(CombatState.Phase.PRINCIPAL)
		CombatState.Phase.RESOLVER:
			# Auto-advance handled in _enter_resolve
			pass
		CombatState.Phase.FINAL:
			pass


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


func auto_resolve(player_ai: CombatAI = null, player_ai_seed: int = 99) -> void:
	## Drives the whole combat headless. Honors an injected player AI; when null,
	## falls back to a seeded reference DummyAI (deterministic for a fixed seed).
	if player_ai == null:
		var dummy := DummyAI.new()
		dummy.setup(player_ai_seed)
		player_ai = dummy
	start()
	var iterations_left: int = AUTO_RESOLVE_MAX_ITERATIONS
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
		_combat_over = true
		_transition_to(CombatState.Phase.FINAL)


func _auto_play_player(player_ai: CombatAI) -> void:
	var hand: Array[CardData] = []
	for card in player_deck.get_hand():
		hand.append(card)
	var card_to_play: CardData = player_ai.choose_card_to_play(hand, player_deck.mana)
	var plays: int = 0
	while card_to_play != null and plays < MAX_PLAYS_PER_TURN:
		if card_to_play.card_type == CardData.CardType.HECHIZO:
			player_deck.play_spell(card_to_play)
			_apply_spell_effects(card_to_play, 0)
		else:
			player_deck.play_creature(card_to_play)
		plays += 1
		hand = []
		for card in player_deck.get_hand():
			hand.append(card)
		card_to_play = player_ai.choose_card_to_play(hand, player_deck.mana)
	var attackers: Array[CardInstance] = player_ai.choose_attackers(player_deck.get_board())
	var enemy_board: Array[CardInstance] = enemy_deck.get_defenders()
	for attacker in attackers:
		var target: Variant = player_ai.choose_attack_target(attacker, enemy_board)
		declare_attacker(attacker, target)


func _transition_to(new_phase: CombatState.Phase) -> void:
	var old_phase: CombatState.Phase = phase
	phase = new_phase
	phase_changed.emit(old_phase, new_phase)
	_enter_phase(new_phase)


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

	# Player mana: refill + increment (cap at config.max_mana_cap)
	player_deck.gain_mana(player_deck.max_mana)
	if player_deck.max_mana < config.max_mana_cap:
		player_deck.increment_max_mana(mini(config.mana_ramp_per_turn, config.max_mana_cap - player_deck.max_mana))
	player_deck.draw_card()
	player_deck.refresh_creatures_for_turn()

	# Enemy mana: refill + increment (cap at config.max_mana_cap)
	enemy_deck.gain_mana(enemy_deck.max_mana)
	if enemy_deck.max_mana < config.max_mana_cap:
		enemy_deck.increment_max_mana(mini(config.mana_ramp_per_turn, config.max_mana_cap - enemy_deck.max_mana))
	enemy_deck.draw_card()
	enemy_deck.refresh_creatures_for_turn()

	# Clear attack state from previous turn
	_player_attack_pairs.clear()
	_ai_attack_pairs.clear()
	_block_assignments.clear()

	# Auto-advance to PRINCIPAL
	_transition_to(CombatState.Phase.PRINCIPAL)


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
	if not _player_attack_pairs.is_empty():
		var p_result: Dictionary = _resolver.resolve_combat(_player_attack_pairs, enemy.current_health)
		var p_pairs: Array = p_result["pairs_result"]
		var p_hero_dmg: int = p_result["hero_damage"]
		enemy.take_damage(p_hero_dmg)
		if p_hero_dmg > 0:
			enemy_damaged.emit(p_hero_dmg)
		if not p_pairs.is_empty():
			_process_death_results(p_pairs)

	_player_attack_pairs.clear()
	_block_assignments.clear()

	_check_victory()
	if _combat_over:
		return

	# --- AI turn: play cards + declare attacks ---
	_run_ai_turn()

	# --- Resolve AI attacks ---
	if not _ai_attack_pairs.is_empty():
		var e_result: Dictionary = _resolver.resolve_combat(_ai_attack_pairs, player_hero.current_health)
		var e_pairs: Array = e_result["pairs_result"]
		var e_hero_dmg: int = e_result["hero_damage"]
		if e_hero_dmg > 0:
			player_hero.take_damage(e_hero_dmg)
			hero_damaged.emit(e_hero_dmg)
		if not e_pairs.is_empty():
			_process_death_results(e_pairs)

	_ai_attack_pairs.clear()

	_check_victory()
	if not _combat_over:
		_transition_to(CombatState.Phase.PREPARACION)


func _enter_final() -> void:
	if not _combat_over:
		_combat_over = true
	var player_won: bool = enemy.current_health <= 0
	combat_ended.emit(player_won)


func _run_ai_turn() -> void:
	# AI plays cards
	var ai_hand: Array[CardData] = []
	for card in enemy_deck.get_hand():
		ai_hand.append(card)

	var card_to_play: CardData = ai.choose_card_to_play(ai_hand, enemy_deck.mana)
	var plays_this_turn: int = 0
	while card_to_play != null and plays_this_turn < MAX_PLAYS_PER_TURN:
		if card_to_play.card_type == CardData.CardType.HECHIZO:
			enemy_deck.play_spell(card_to_play)
			_apply_spell_effects(card_to_play, 1)
		else:
			enemy_deck.play_creature(card_to_play)
		plays_this_turn += 1
		ai_hand = []
		for card in enemy_deck.get_hand():
			ai_hand.append(card)
		card_to_play = ai.choose_card_to_play(ai_hand, enemy_deck.mana)

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
			creature_died.emit(attacker, attacker.owner_id)

		if defender != null and pr["defender_died"]:
			if defender.owner_id == 0:
				dead_player.append(defender)
			else:
				dead_enemy.append(defender)
			creature_died.emit(defender, defender.owner_id)

	# Track dead player creatures for external retrieval
	for inst in dead_player:
		if not _dead_player_creatures.has(inst):
			_dead_player_creatures.append(inst)

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
		enemy_damaged.emit(amount)
	elif hero == player_hero:
		hero_damaged.emit(amount)


func _check_board_deaths(deck: CombatDeck) -> void:
	var dead: Array[CardInstance] = []
	for inst in deck.get_board():
		if inst.is_dead:
			dead.append(inst)
	for inst in dead:
		deck.remove_from_board(inst)
		creature_died.emit(inst, inst.owner_id)
