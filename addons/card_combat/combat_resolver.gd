class_name CombatDamageResolver
extends RefCounted
## Calculo de dano simultaneo entre criaturas. Logica pura.


func resolve_combat(pairs: Array, _defender_hp: int) -> Dictionary:
	var pairs_result: Array = []
	var hero_damage: int = 0

	# Phase 1: Calculate all damage
	var pending_damage: Array = []  # Array of [CardInstance, int]

	for pair in pairs:
		var a: CardInstance = pair.attacker
		var d = pair.defender
		var a_dmg := calculate_damage(a, d)

		if d == null:
			# Direct attack to hero
			hero_damage += a_dmg
			pairs_result.append({
				"attacker": a,
				"defender": null,
				"attacker_died": false,
				"defender_died": false,
			})
		else:
			var d_dmg := calculate_damage(d, a)
			pending_damage.append([d, a_dmg])
			pending_damage.append([a, d_dmg])
			pairs_result.append({
				"attacker": a,
				"defender": d,
				"attacker_died": false,
				"defender_died": false,
			})

	# Phase 2: Apply all damage simultaneously
	for entry in pending_damage:
		var target: CardInstance = entry[0]
		var amount: int = entry[1]
		target.take_damage(amount)

	# Phase 3: Mark deaths
	for pr in pairs_result:
		var a: CardInstance = pr["attacker"]
		if a.is_dead:
			pr["attacker_died"] = true
		if pr["defender"] != null and pr["defender"].is_dead:
			pr["defender_died"] = true

	return {
		"pairs_result": pairs_result,
		"hero_damage": hero_damage,
	}


func calculate_damage(attacker: CardInstance, _defender: CardInstance) -> int:
	return maxi(attacker.current_attack, 1)
