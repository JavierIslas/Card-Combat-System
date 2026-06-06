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
## Demonstrates the full AbilityLibrary wiring with all 14 keywords in play.
## Builds two themed decks and runs a combat with abilities enabled.
##
## Run headless:
##   godot --headless --path . --script addons/card_combat/examples/ability_demo.gd


func _initialize() -> void:
	print("=== Ability Demo — full keyword combat ===")

	var session := CombatSession.new()
	var lib := AbilityLibrary.new(session)
	lib.wire_all()

	var hero := _make_hero("Knight-Captain", 30)
	var enemy := _make_hero("Orc Warchief", 30)

	session.phase_changed.connect(_on_phase)
	session.creature_died.connect(_on_death)
	session.combatant_damaged.connect(func(s: int, a: int) -> void: print("  Side %d hero takes %d damage" % [s, a]))
	session.combatant_healed.connect(func(s: int, a: int) -> void: print("  Side %d hero healed %d" % [s, a]))
	session.combat_ended.connect(func(w: int) -> void: print("  Combat ended — winner=%d" % w))

	session.setup(hero, _knight_deck(), enemy, _orc_deck(), 42)
	session.auto_resolve()

	var result: Dictionary = session.get_result()
	print("\nResult: winner=%d  turns=%d  hp0=%d  hp1=%d" % [
		result["winner_side"], result["turn_number"],
		result["hp"][0], result["hp"][1],
	])
	quit()


# --- Signal handlers ----------------------------------------------------------

func _on_phase(old_phase: int, new_phase: int) -> void:
	print("  %s -> %s" % [CombatState.phase_name(old_phase), CombatState.phase_name(new_phase)])


func _on_death(card: CardInstance, owner: int) -> void:
	print("  %s (side %d) died" % [card.card_data.name, owner])


# --- Deck builders ------------------------------------------------------------

func _knight_deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	# CHARGE + LIFESTEAL knight
	cards.append(_creature("lance_knight", 3, 3, 2, ["CHARGE", "LIFESTEAL"]))
	# TAUNT wall
	cards.append(_creature("shield_bearer", 2, 1, 4, ["TAUNT"]))
	# STEALTH assassin
	cards.append(_creature("shadow_agent", 2, 3, 1, ["STEALTH"]))
	# WINDFURY berserker
	cards.append(_creature("berserker", 4, 2, 3, ["WINDFURY"]))
	# IMMUNITY paladin
	cards.append(_creature("paladin", 3, 2, 3, ["IMMUNITY"], {"immunity_hits": 2}))
	# LORD commander (buffs other friendlies)
	cards.append(_creature("commander", 5, 2, 4, ["LORD"], {"aura_attack": 1, "aura_health": 1}))
	# Damage spell (benefits from SPELLPOWER)
	cards.append(_spell("smite", 2, SpellEffect.EffectType.DAMAGE, 3, SpellEffect.TargetType.ENEMY_HERO))
	# Buff spell
	cards.append(_spell("rally", 1, SpellEffect.EffectType.BUFF_ATTACK, 2, SpellEffect.TargetType.PLAYER_CREATURES))
	# Healing spell
	cards.append(_spell("holy_light", 2, SpellEffect.EffectType.HEAL, 5, SpellEffect.TargetType.PLAYER_HERO))
	# SPELLPOWER provider
	cards.append(_creature("archmage", 3, 1, 3, ["SPELLPOWER"], {"spell_power": 1}))
	return cards


func _orc_deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	# OVERKILL brute
	cards.append(_creature("brute", 4, 5, 3, ["OVERKILL"]))
	# THORNS spiky
	cards.append(_creature("spiky_tortoise", 2, 1, 4, ["THORNS"], {"thorns": 2}))
	# ARMOR tank
	cards.append(_creature("ironhide", 3, 2, 4, ["ARMOR"], {"armor": 1}))
	# FREEZE shaman
	cards.append(_creature("frost_shaman", 3, 2, 2, ["FREEZE"]))
	# BATTLECRY raider
	cards.append(_creature("raider", 2, 2, 2, ["BATTLECRY"], {"battlecry_damage": 3}))
	# SPELLBURST cultist
	cards.append(_creature("cultist", 2, 1, 3, ["SPELLBURST"], {"spellburst_attack": 2, "spellburst_health": 1}))
	# AOE spell (triggers SPELLBURST)
	cards.append(_spell("fireball", 3, SpellEffect.EffectType.AOE_DAMAGE, 2, SpellEffect.TargetType.ENEMY_CREATURES))
	# Summon spell (also triggers SPELLBURST)
	cards.append(_summon("call_wolves", 3, "Wolf", 2, 2, 2))
	# Vanilla filler
	cards.append(_creature("grunt", 1, 2, 1))
	cards.append(_creature("ogre", 4, 4, 4))
	return cards


# --- Factories ----------------------------------------------------------------

func _creature(id: String, cost: int, attack: int, health: int, keywords: Array = [], extra: Dictionary = {}) -> CardData:
	var card := CardData.new()
	card.card_id = id
	card.name = id
	card.cost = cost
	card.attack = attack
	card.health = health
	card.play_kind = CardData.PlayKind.UNIT
	var meta: Dictionary = {}
	if not keywords.is_empty():
		meta["keywords"] = keywords
	for k in extra:
		meta[k] = extra[k]
	if not meta.is_empty():
		card.metadata = meta
	return card


func _spell(id: String, cost: int, type: SpellEffect.EffectType, value: int, target: SpellEffect.TargetType) -> CardData:
	var card := CardData.new()
	card.card_id = id
	card.name = id
	card.cost = cost
	card.play_kind = CardData.PlayKind.EFFECT
	var effect := SpellEffect.new()
	effect.effect_type = type
	effect.value = value
	effect.target_type = target
	card.spell_effects = [effect]
	return card


func _summon(id: String, cost: int, unit_name: String, count: int, attack: int, health: int) -> CardData:
	var card := CardData.new()
	card.card_id = id
	card.name = id
	card.cost = cost
	card.play_kind = CardData.PlayKind.EFFECT
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.SUMMON
	effect.target_type = SpellEffect.TargetType.SUMMON_BOARD
	effect.summon_name = unit_name
	effect.summon_count = count
	effect.summon_attack = attack
	effect.summon_health = health
	card.spell_effects = [effect]
	return card


func _make_hero(display_name: String, hp: int) -> Combatant:
	var c := Combatant.new()
	c.display_name = display_name
	c.max_health = hp
	c.current_health = hp
	return c
