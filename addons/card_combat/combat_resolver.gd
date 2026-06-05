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

class_name CombatDamageResolver
extends RefCounted
## Simultaneous damage calculation between creatures. Pure logic.

## Optional damage formula hook. Signature: (attacker, defender) -> int. When
## valid it fully replaces the default formula, letting the game layer factor in
## the defender (e.g. armor). Empty = engine default (attack, floored at 1).
var damage_fn: Callable = Callable()


func resolve_combat(pairs: Array) -> Dictionary:
	var pairs_result: Array = []

	# Phase 1: Calculate all damage. Each entry is [target: CardInstance, amount: int].
	var pending_damage: Array[Array] = []

	for pair in pairs:
		var a: CardInstance = pair.attacker
		var d = pair.defender
		var a_dmg := calculate_damage(a, d)

		if d == null:
			# Direct attack to hero: the dealt damage lives in this pair's
			# attacker_damage_dealt, which the session aggregates per target_side.
			pairs_result.append({
				"attacker": a,
				"defender": null,
				"attacker_died": false,
				"defender_died": false,
				"attacker_damage_dealt": a_dmg,
				"defender_damage_dealt": 0,
			})
		else:
			var d_dmg := calculate_damage(d, a)
			# Each entry is [target, amount, source]: the source is the opponent that
			# dealt it, so ON_DAMAGE_TAKEN can name who hit (reflect / thorns).
			pending_damage.append([d, a_dmg, a])
			pending_damage.append([a, d_dmg, d])
			pairs_result.append({
				"attacker": a,
				"defender": d,
				"attacker_died": false,
				"defender_died": false,
				"attacker_damage_dealt": a_dmg,
				"defender_damage_dealt": d_dmg,
			})

	# Phase 2: Apply all damage simultaneously
	for entry in pending_damage:
		var target: CardInstance = entry[0]
		var amount: int = entry[1]
		var source: CardInstance = entry[2]
		target.take_damage(amount, source)

	# Phase 3: Mark deaths
	for pr in pairs_result:
		var a: CardInstance = pr["attacker"]
		if a.is_dead:
			pr["attacker_died"] = true
		if pr["defender"] != null and pr["defender"].is_dead:
			pr["defender_died"] = true

	return {
		"pairs_result": pairs_result,
	}


func calculate_damage(attacker: CardInstance, defender: CardInstance) -> int:
	if damage_fn.is_valid():
		return damage_fn.call(attacker, defender)
	return maxi(attacker.current_attack, 1)
