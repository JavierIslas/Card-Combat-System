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

## Coin-flip probability for the reference AI's optional choices (swing at the hero
## instead of a creature; block an incoming attacker). Tuning knob, not balance.
const HERO_ACTION_CHANCE := 0.5

var _seed: int = 0
var _rng: RandomNumberGenerator


func setup(p_seed: int = -1) -> void:
	_seed = p_seed
	_rng = RandomNumberGenerator.new()
	if p_seed >= 0:
		_rng.seed = p_seed
	else:
		_rng.randomize()


func serialize_state() -> Dictionary:
	## Capture the seed and the live RNG state so a resumed combat reproduces the
	## exact same picks without re-injecting the AI. state is 0 if setup() never ran.
	return {"seed": _seed, "rng_state": _rng.state if _rng != null else 0}


func restore_state(data: Dictionary) -> void:
	## Rebuild the RNG from a serialized state. Re-seed first (so a never-set-up AI
	## gets a valid generator), then overwrite with the saved position.
	setup(int(data.get("seed", -1)))
	_rng.state = int(data.get("rng_state", _rng.state))


func choose_card_to_play(hand: Array[CardData], mana: int) -> CardData:
	var affordable: Array[CardData] = []
	for card in hand:
		if card.cost <= mana:
			affordable.append(card)
	if affordable.is_empty():
		return null
	return affordable[_rng.randi() % affordable.size()]


func choose_attackers(board: Array[CardInstance], _enemy_heroes: Array[Combatant] = []) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	for inst in board:
		if not inst.is_dead and inst.can_attack_this_turn:
			result.append(inst)
	return result


func choose_attack_target(_attacker: CardInstance, enemy_board: Array[CardInstance], _enemy_heroes: Array[Combatant] = []) -> Variant:
	# Only living creatures are valid targets, matching choose_spell_target /
	# choose_blockers and HeuristicAI: enemy_board may carry dead instances.
	var candidates: Array[CardInstance] = CardInstance.living(enemy_board)
	if candidates.is_empty():
		return null
	if _rng.randf() < HERO_ACTION_CHANCE:
		return null  # attack hero
	return candidates[_rng.randi() % candidates.size()]


func choose_spell_target(spell: CardData, own_board: Array[CardInstance], enemy_board: Array[CardInstance]) -> Variant:
	# Reference AI: pick the board that matches the spell's first effect (a damaging
	# spell wants an enemy, a heal/buff an ally), then a random living creature from
	# it. Avoids the old behavior of damaging its own creatures. Null if none alive.
	var board := enemy_board if spell.targets_enemies() else own_board
	var candidates: Array[CardInstance] = CardInstance.living(board)
	if candidates.is_empty():
		return null
	# CHOSEN_CREATURES: return up to target_count distinct living creatures (the
	# engine fizzles/skips if fewer than target_count are returned). Single-target
	# spells return one creature, unchanged.
	var n: int = spell.chosen_target_count()
	if n > 0:
		return _pick_random_distinct(candidates, n)
	return candidates[_rng.randi() % candidates.size()]


func _pick_random_distinct(candidates: Array[CardInstance], n: int) -> Array[CardInstance]:
	var pool: Array[CardInstance] = candidates.duplicate()
	var out: Array[CardInstance] = []
	while out.size() < n and not pool.is_empty():
		var i: int = _rng.randi() % pool.size()
		out.append(pool[i])
		pool.remove_at(i)
	return out


func choose_blockers(attackers: Array[CardInstance], own_board: Array[CardInstance]) -> Dictionary:
	var blocks: Dictionary = {}
	var available: Array[CardInstance] = CardInstance.living(own_board)
	if available.is_empty():
		return blocks
	for atk in attackers:
		if available.is_empty():
			break
		if _rng.randf() < HERO_ACTION_CHANCE:
			var idx: int = _rng.randi() % available.size()
			blocks[atk] = available[idx]
			# A blocker can only be assigned once.
			available.remove_at(idx)
	return blocks
