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

class_name HeuristicAI
extends CombatAI
## Greedy reference AI: a stronger, deterministic alternative to DummyAI for
## balancing with auto_resolve. It plays the most expensive affordable card,
## attacks for value (favorable trades, otherwise the hero), targets spells by
## effect type, and blocks the biggest threats. Agnostic: operates only on
## CardData and CardInstance. DummyAI stays the engine default; assign this via
## ais[side] when you want tougher headless opponents.
##
## Fully deterministic from board state (stable tie-breaking by position); setup()
## accepts a seed only for API parity with DummyAI.


## Lethal flag computed in choose_attackers and read by choose_attack_target within
## the same turn (auto_resolve calls choose_attackers once, then choose_attack_target
## per attacker). When the chosen attackers can together kill the enemy hero, every
## attack goes face — even sacrificing favorable trades — to close the game.
var _lethal_this_turn: bool = false


func setup(_p_seed: int = -1) -> void:
	# State-only heuristics: no RNG needed. Kept for parity with DummyAI.setup.
	pass


func choose_card_to_play(hand: Array[CardData], mana: int) -> CardData:
	## Spend mana greedily: the most expensive affordable card (curve filling).
	var best: CardData = null
	for card in hand:
		if card.cost <= mana and (best == null or card.cost > best.cost):
			best = card
	return best


func choose_attackers(board: Array[CardInstance], enemy_heroes: Array[Combatant] = []) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	var total_attack: int = 0
	for inst in board:
		if not inst.is_dead and inst.can_attack_this_turn:
			result.append(inst)
			total_attack += inst.current_attack
	# Optimistic lethal: ignores blocks the defender may declare (the attacking AI
	# can't see them yet), the standard assumption for an attack-step heuristic.
	# Lethal is measured against the first living enemy hero — the one the engine
	# defaults unblocked hits to (see CombatSession._default_enemy_side).
	var target_hero: Combatant = _first_living_hero(enemy_heroes)
	_lethal_this_turn = target_hero != null and total_attack >= target_hero.current_health
	return result


func _first_living_hero(enemy_heroes: Array[Combatant]) -> Combatant:
	for h in enemy_heroes:
		if h != null and h.current_health > 0:
			return h
	return null


func choose_attack_target(attacker: CardInstance, enemy_board: Array[CardInstance], _enemy_heroes: Array[Combatant] = []) -> Variant:
	## Go face when lethal is on the table; otherwise trade for value: kill the
	## strongest enemy we can kill without dying. If no favorable trade exists, swing
	## at the hero (null).
	if _lethal_this_turn:
		return null
	var best: CardInstance = null
	for enemy in enemy_board:
		if enemy.is_dead:
			continue
		var kills: bool = attacker.current_attack >= enemy.current_health
		var survives: bool = enemy.current_attack < attacker.current_health
		if kills and survives and (best == null or enemy.current_attack > best.current_attack):
			best = enemy
	if best != null:
		return best
	return null


func choose_spell_target(spell: CardData, own_board: Array[CardInstance], enemy_board: Array[CardInstance]) -> Variant:
	## Damage/AOE hits the enemy; heal/buff goes to an ally. For damage, prefer an
	## enemy we can outright kill (highest attack among those); otherwise the
	## weakest enemy. For heal, the most-damaged ally; for buff, the strongest ally.
	var effect: SpellEffect = _first_effect(spell)
	if effect == null:
		return _first_living(enemy_board)
	if _is_damage(effect):
		return _pick_damage_target(effect.value, enemy_board)
	return _pick_support_target(effect, own_board)


func choose_blockers(attackers: Array[CardInstance], own_board: Array[CardInstance]) -> Dictionary:
	## Block the biggest threats first with a defender that survives or trades up.
	## A blocker is used at most once; chump blocks (defender dies for nothing) are
	## skipped so we don't waste board presence.
	var blocks: Dictionary = {}
	var available: Array[CardInstance] = CardInstance.living(own_board)
	if available.is_empty():
		return blocks
	var threats: Array[CardInstance] = CardInstance.living(attackers)
	threats.sort_custom(func(a: CardInstance, b: CardInstance) -> bool: return a.current_attack > b.current_attack)
	for atk in threats:
		var blocker: CardInstance = _best_blocker(atk, available)
		if blocker == null:
			continue
		blocks[atk] = blocker
		available.erase(blocker)
		if available.is_empty():
			break
	return blocks


func _best_blocker(attacker: CardInstance, available: Array[CardInstance]) -> CardInstance:
	## Pick the cheapest worthwhile blocker: prefer survive+kill, then kill (trade),
	## then survive. Returns null if every option is a pure chump block.
	var best: CardInstance = null
	var best_score: int = 0
	for blocker in available:
		var kills: bool = blocker.current_attack >= attacker.current_health
		var survives: bool = attacker.current_attack < blocker.current_health
		var score: int = 0
		if kills and survives:
			score = 3
		elif kills:
			score = 2
		elif survives:
			score = 1
		if score > best_score:
			best_score = score
			best = blocker
	return best


func _pick_damage_target(value: int, enemy_board: Array[CardInstance]) -> Variant:
	var lethal: CardInstance = null
	var weakest: CardInstance = null
	for enemy in enemy_board:
		if enemy.is_dead:
			continue
		if value >= enemy.current_health and (lethal == null or enemy.current_attack > lethal.current_attack):
			lethal = enemy
		if weakest == null or enemy.current_health < weakest.current_health:
			weakest = enemy
	return lethal if lethal != null else weakest


func _pick_support_target(effect: SpellEffect, own_board: Array[CardInstance]) -> Variant:
	var best: CardInstance = null
	var heal: bool = effect.effect_type == SpellEffect.EffectType.HEAL
	for ally in own_board:
		if ally.is_dead:
			continue
		if best == null:
			best = ally
		elif heal and _missing_health(ally) > _missing_health(best):
			best = ally
		elif not heal and ally.current_attack > best.current_attack:
			best = ally
	return best


func _missing_health(inst: CardInstance) -> int:
	return inst.current_max_health - inst.current_health


func _is_damage(effect: SpellEffect) -> bool:
	return effect.effect_type == SpellEffect.EffectType.DAMAGE or effect.effect_type == SpellEffect.EffectType.AOE_DAMAGE


func _first_effect(spell: CardData) -> SpellEffect:
	if spell.spell_effects.is_empty():
		return null
	return spell.spell_effects[0]


func _first_living(board: Array[CardInstance]) -> Variant:
	for inst in board:
		if not inst.is_dead:
			return inst
	return null
