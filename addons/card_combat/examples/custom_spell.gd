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
## Demonstrates custom spell effects via the effect_fn injection point.
## Shows three custom effects that go beyond the built-in catalog:
##   1. Drain — damage + heal the caster's hero
##   2. Swap — swap a creature's attack and health
##   3. Destroy — kill a creature with attack >= 5 (conditional removal)
##
## Run headless:
##   godot --headless --path . --script addons/card_combat/examples/custom_spell.gd


func _initialize() -> void:
	print("=== Custom Spell Demo — effect_fn ===")

	var session := CombatSession.new()
	var hero := _make_hero("Wizard", 30)
	var enemy := _make_hero("Necromancer", 30)

	session.setup(hero, _wizard_deck(), enemy, _necro_deck(), 7)
	session.start()
	# play_spell only fires during MAIN, so advance out of PREPARATION first.
	session.advance()

	# Force some creatures onto the board for the demo. Each spell targets its own
	# creature (captured by reference) so a death + board compaction from one cast
	# can't shift the index of another's target.
	session.decks[1].add_to_board(_make_instance(_creature("grunt", 1, 2, 5), 1))
	session.decks[1].add_to_board(_make_instance(_creature("brute", 3, 6, 4), 1))
	session.decks[1].add_to_board(_make_instance(_creature("giant", 6, 6, 8), 1))
	session.decks[0].add_to_board(_make_instance(_creature("apprentice", 1, 1, 3), 0))

	var board: Array = session.decks[1].get_board()
	var drain_target: CardInstance = board[0]  # grunt (survives the 3 damage)
	var swap_target: CardInstance = board[1]    # brute 6/4 -> 4/6
	var exec_target: CardInstance = board[2]    # giant (attack 6 >= 5 -> destroyed)

	print("\nBoard before custom spells:")
	_print_board(session)

	# --- Demo 1: Drain (damage + heal) ---
	print("\n--- Cast: Drain Soul (3 damage to enemy creature, heal 3) ---")
	_cast_drain(session, drain_target)

	# --- Demo 2: Swap (swap attack/health) ---
	print("\n--- Cast: Polymorph (swap attack/health of enemy creature) ---")
	_cast_swap(session, swap_target)

	# --- Demo 3: Conditional destroy ---
	print("\n--- Cast: Execute (destroy creature with attack >= 5) ---")
	_cast_execute(session, exec_target)

	print("\nBoard after custom spells:")
	_print_board(session)

	print("\nHero HP: side0=%d  side1=%d" % [
		session.heroes[0].current_health,
		session.heroes[1].current_health,
	])
	quit()


# --- Custom spell implementations ---------------------------------------------

func _cast_from_hand(session: CombatSession, card: CardData, effect: SpellEffect, target: CardInstance) -> void:
	## play_spell casts from the active side's hand during MAIN, so the ad-hoc card
	## must be in hand first. Cost 0 means no mana is required to play it.
	session.decks[session.active_side].get_hand().append(card)
	session.play_spell(card, effect, target)


func _cast_drain(session: CombatSession, target: CardInstance) -> void:
	## Drain: deal 3 damage to target creature and heal caster's hero by 3.
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE  # fallback type
	effect.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	effect.effect_fn = _drain_effect  # custom resolution overrides the fallback

	var card := CardData.new()
	card.card_id = "drain_soul"
	card.name = "Drain Soul"
	card.cost = 0
	card.play_kind = CardData.PlayKind.EFFECT

	_cast_from_hand(session, card, effect, target)
	print("  Drain resolved: target HP=%d" % target.current_health)


func _drain_effect(_effect: SpellEffect, target: Variant, context: Dictionary) -> Dictionary:
	## Custom effect_fn: deal 3 damage to the target, then heal the caster's hero.
	var session: CombatSession = context["session"]
	var owner_id: int = context["owner_id"]
	if target is CardInstance and not target.is_dead:
		target.take_damage(3, null)
		session.heal_hero(owner_id, 3)
		print("  Drain: dealt 3 to %s, healed side %d by 3" % [target.card_data.name, owner_id])
	return {}


func _cast_swap(session: CombatSession, target: CardInstance) -> void:
	## Swap: exchange a creature's current attack and health.
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.BUFF_ATTACK  # fallback
	effect.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	effect.effect_fn = _swap_effect

	var card := CardData.new()
	card.card_id = "polymorph"
	card.name = "Polymorph"
	card.cost = 0
	card.play_kind = CardData.PlayKind.EFFECT

	_cast_from_hand(session, card, effect, target)
	if not target.is_dead:
		print("  Swap resolved: %s is now %d/%d" % [target.card_data.name, target.current_attack, target.current_health])


func _swap_effect(_effect: SpellEffect, target: Variant, _unused_ctx: Dictionary) -> Dictionary:
	## Custom effect_fn: swap a creature's attack and health. A single permanent buff
	## with per-stat deltas reaches the swapped values directly (apply_permanent_buff
	## accepts negative deltas and adjusts current/max health consistently).
	if target is CardInstance and not target.is_dead:
		var old_attack: int = target.current_attack
		var old_health: int = target.current_health
		target.apply_permanent_buff(old_health - old_attack, old_attack - old_health)
		print("  Swap: %s %d/%d -> %d/%d" % [
			target.card_data.name, old_attack, old_health,
			target.current_attack, target.current_health,
		])
	return {}


func _cast_execute(session: CombatSession, target: CardInstance) -> void:
	## Execute: destroy a creature with attack >= 5.
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	effect.effect_fn = _execute_effect

	var card := CardData.new()
	card.card_id = "execute"
	card.name = "Execute"
	card.cost = 0
	card.play_kind = CardData.PlayKind.EFFECT

	_cast_from_hand(session, card, effect, target)


func _execute_effect(_effect: SpellEffect, target: Variant, _exec_ctx: Dictionary) -> Dictionary:
	## Custom effect_fn: destroy a creature if its attack >= 5, otherwise nothing.
	## play_spell already sweeps the board for deaths after the effect resolves.
	if target is CardInstance and not target.is_dead:
		if target.current_attack >= 5:
			print("  Execute: %s (%d attack) destroyed!" % [target.card_data.name, target.current_attack])
			target.take_damage(target.current_health, null)  # lethal
		else:
			print("  Execute: %s (%d attack) survives (need >= 5)" % [target.card_data.name, target.current_attack])
	return {}


# --- Helpers ------------------------------------------------------------------

func _make_instance(card: CardData, owner: int) -> CardInstance:
	var inst := CardInstance.new()
	inst.setup(card, owner)
	return inst


func _print_board(session: CombatSession) -> void:
	for side in session.side_count():
		var board: Array = session.decks[side].get_board()
		var names: PackedStringArray = []
		for inst in board:
			if not inst.is_dead:
				names.append("%s(%d/%d)" % [inst.card_data.name, inst.current_attack, inst.current_health])
		print("  Side %d: %s" % [side, " ".join(names) if not names.is_empty() else "(empty)"])


func _wizard_deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.append(_creature("apprentice", 1, 1, 3))
	cards.append(_creature("mage", 2, 2, 2))
	cards.append(_creature("archmage", 4, 3, 5))
	return cards


func _necro_deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.append(_creature("skeleton", 1, 1, 1))
	cards.append(_creature("zombie", 2, 2, 3))
	cards.append(_creature("vampire", 3, 3, 3))
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
