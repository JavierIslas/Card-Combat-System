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

extends SceneTree
## Demonstrates how to implement a custom AI and inject it into a combat session.
## The AI prioritizes high-value trades, clears threats, and goes face when lethal.
##
## Note: in GDScript, a script file can only `extends` one thing. When the AI class
## and the demo runner share a file, the AI becomes an inner class. In production,
## you'd put the AI in its own file (e.g. my_ai.gd) with `extends CombatAI` at top.
##
## Run headless:
##   godot --headless --path . --script addons/card_combat/examples/custom_ai.gd


## A simple value-based AI that tries to make favorable trades.
## Inner class because the script extends SceneTree for the demo runner.
## In production, extract to its own file: `class_name ValueAI extends CombatAI`.
class ValueAI extends CombatAI:


	func choose_card_to_play(hand: Array[CardData], mana: int) -> CardData:
		## Play the most expensive card we can afford (greedy mana curve).
		var best: CardData = null
		for card in hand:
			if card.cost <= mana:
				if best == null or card.cost > best.cost:
					best = card
		return best


	func choose_attackers(board: Array[CardInstance], _enemy_heroes: Array[Combatant] = []) -> Array[CardInstance]:
		## Attack with every creature that can.
		var attackers: Array[CardInstance] = []
		for inst in board:
			if inst.can_attack_this_turn and inst.times_attacked < inst.attacks_per_turn and inst.is_combatant:
				attackers.append(inst)
		return attackers


	func choose_attack_target(attacker: CardInstance, enemy_board: Array[CardInstance], enemy_heroes: Array[Combatant] = []) -> Variant:
		## Priority: kill a threat > trade efficiently > go face.
		if enemy_board.is_empty():
			return null  # go face

		# Look for a favorable trade: kill something as big as us.
		for target in enemy_board:
			if not target.is_dead and target.current_health <= attacker.current_attack:
				if target.current_attack >= attacker.current_attack:
					return target

		# Look for anything we can kill.
		for target in enemy_board:
			if not target.is_dead and target.current_health <= attacker.current_attack:
				return target

		# Check if we can lethal the enemy hero.
		if not enemy_heroes.is_empty():
			var hero: Combatant = enemy_heroes[0]
			if hero.current_health <= attacker.current_attack:
				return null  # go face for lethal

		# Default: go face (pressure).
		return null


	func choose_spell_target(_spell: CardData, _own_board: Array[CardInstance], enemy_board: Array[CardInstance]) -> Variant:
		## Target the enemy creature with the highest attack (remove biggest threat).
		if enemy_board.is_empty():
			return null
		var best: CardInstance = null
		for inst in enemy_board:
			if not inst.is_dead:
				if best == null or inst.current_attack > best.current_attack:
					best = inst
		return best


	func choose_blockers(attackers: Array[CardInstance], own_board: Array[CardInstance]) -> Dictionary:
		## Block the most dangerous attacker with the cheapest viable blocker.
		var blocks: Dictionary = {}
		var used: Array[CardInstance] = []
		for atk in attackers:
			var best_blocker: CardInstance = null
			for inst in own_board:
				if inst.is_combatant and not inst.is_dead and not used.has(inst):
					if inst.current_health >= atk.current_attack:
						if best_blocker == null or inst.current_health < best_blocker.current_health:
							best_blocker = inst
			if best_blocker != null:
				used.append(best_blocker)
				blocks[atk] = best_blocker
		return blocks


# --- Demo runner --------------------------------------------------------------

func _initialize() -> void:
	print("=== Custom AI Demo — ValueAI vs DummyAI ===")

	var session := CombatSession.new()

	# Inject our custom AI on side 0
	session.ais[0] = ValueAI.new()
	# Side 1 gets the default DummyAI (seeded by setup)

	var hero := _make_hero("ValueAI Player", 30)
	var enemy := _make_hero("DummyAI Enemy", 30)

	session.combat_ended.connect(func(w: int) -> void:
		print("  Winner: side %d (%s)" % [w, "ValueAI" if w == 0 else "DummyAI"])
	)

	session.setup(hero, _midrange_deck(), enemy, _midrange_deck(), 42)
	session.auto_resolve()

	var result: Dictionary = session.get_result()
	print("\nResult: winner=%d  turns=%d  hp0=%d  hp1=%d" % [
		result["winner_side"], result["turn_number"],
		result["hp"][0], result["hp"][1],
	])
	quit()


func _midrange_deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.append(_creature("scout", 1, 1, 2))
	cards.append(_creature("grunt", 1, 2, 1))
	cards.append(_creature("knight", 2, 2, 3))
	cards.append(_creature("archer", 2, 3, 2))
	cards.append(_creature("ogre", 3, 4, 4))
	cards.append(_creature("golem", 4, 4, 6))
	cards.append(_creature("drake", 4, 5, 4))
	cards.append(_creature("giant", 6, 7, 7))
	return cards


func _creature(id: String, cost: int, attack: int, health: int) -> CardData:
	var card := CardData.new()
	card.card_id = id
	card.name = id
	card.cost = cost
	card.attack = attack
	card.health = health
	card.play_kind = CardData.PlayKind.UNIT
	return card


func _make_hero(display_name: String, hp: int) -> Combatant:
	var c := Combatant.new()
	c.display_name = display_name
	c.max_health = hp
	c.current_health = hp
	return c
