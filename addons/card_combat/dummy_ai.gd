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

class_name DummyAI
extends CombatAI
## Engine reference AI: picks plays randomly with an optional seed (deterministic
## if `p_seed >= 0`). It is the default AI used by `CombatSession`, and doubles as
## an example of the contract any addon AI must fulfill (choose_card_to_play /
## choose_attackers / choose_attack_target / choose_blockers). Game-agnostic: it
## operates only on `CardData` and `CardInstance`.

var _seed: int = 0
var _rng: RandomNumberGenerator


func setup(p_seed: int = -1) -> void:
	_seed = p_seed
	_rng = RandomNumberGenerator.new()
	if p_seed >= 0:
		_rng.seed = p_seed
	else:
		_rng.randomize()


func choose_card_to_play(hand: Array[CardData], mana: int) -> CardData:
	var affordable: Array[CardData] = []
	for card in hand:
		if card.cost <= mana:
			affordable.append(card)
	if affordable.is_empty():
		return null
	return affordable[_rng.randi() % affordable.size()]


func choose_attackers(board: Array[CardInstance]) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	for inst in board:
		if not inst.is_dead and inst.can_attack_this_turn:
			result.append(inst)
	return result


func choose_attack_target(_attacker: CardInstance, enemy_board: Array[CardInstance]) -> Variant:
	if enemy_board.is_empty():
		return null
	if _rng.randf() < 0.5:
		return null  # attack hero
	return enemy_board[_rng.randi() % enemy_board.size()]


func choose_spell_target(spell: CardData, own_board: Array[CardInstance], enemy_board: Array[CardInstance]) -> Variant:
	# Reference AI: pick the board that matches the spell's first effect (a damaging
	# spell wants an enemy, a heal/buff an ally), then a random living creature from
	# it. Avoids the old behavior of damaging its own creatures. Null if none alive.
	var board := enemy_board if _targets_enemies(spell) else own_board
	var candidates: Array[CardInstance] = CardInstance.living(board)
	if candidates.is_empty():
		return null
	return candidates[_rng.randi() % candidates.size()]


func _targets_enemies(spell: CardData) -> bool:
	# A DAMAGE/AOE_DAMAGE spell wants an enemy; HEAL/BUFF_ATTACK an ally. Defaults to
	# enemy when the spell declares no effects.
	if spell.spell_effects.is_empty():
		return true
	var type: SpellEffect.EffectType = spell.spell_effects[0].effect_type
	return type == SpellEffect.EffectType.DAMAGE or type == SpellEffect.EffectType.AOE_DAMAGE


func choose_blockers(attackers: Array[CardInstance], own_board: Array[CardInstance]) -> Dictionary:
	var blocks: Dictionary = {}
	var available: Array[CardInstance] = CardInstance.living(own_board)
	if available.is_empty():
		return blocks
	for atk in attackers:
		if available.is_empty():
			break
		if _rng.randf() < 0.5:
			var idx: int = _rng.randi() % available.size()
			blocks[atk] = available[idx]
			# A blocker can only be assigned once.
			available.remove_at(idx)
	return blocks
