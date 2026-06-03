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

class_name CardData
extends Resource
## Generic card core: id, cost, stats and type. Game-specific data (rarity, flavor,
## texture, abilities) lives in `metadata: Dictionary`, which the engine does not
## interpret — same as `HexCell.metadata` in the map addon. The game layer (card
## loading, abilities, UI) reads/writes metadata.

enum CardType { CREATURE, SPELL }

@export var card_id: String = ""
@export var name: String = ""
@export var cost: int = 0
@export var attack: int = 0
@export var health: int = 0
@export var card_type: CardType = CardType.CREATURE
@export var metadata: Dictionary = {}
## Spell effects, authored on the card. Exportable now that SpellEffect is a
## Resource, so a card defined as a .tres persists its effects natively.
@export var spell_effects: Array[SpellEffect] = []


func get_total_cost() -> int:
	return cost


func can_afford(player_mana: int) -> bool:
	return player_mana >= get_total_cost()


static func from_dict(data: Dictionary) -> CardData:
	var card := CardData.new()
	card.card_id = data.get("card_id", "")
	card.name = data.get("name", "")
	card.cost = int(data.get("cost", 0))
	card.attack = int(data.get("attack", 0))
	card.health = int(data.get("health", 0))
	var type_idx := CardType.keys().find(data.get("card_type", "CREATURE"))
	if type_idx == -1:
		push_warning("CardData.from_dict: invalid card_type — %s" % data.get("card_type", ""))
		return null
	card.card_type = type_idx as CardType
	var meta: Variant = data.get("metadata", {})
	if meta is Dictionary:
		card.metadata = (meta as Dictionary).duplicate()
	var effects: Variant = data.get("spell_effects", [])
	if effects is Array:
		var parsed: Array[SpellEffect] = []
		for e in effects:
			if e is Dictionary:
				parsed.append(SpellEffect.from_dict(e))
		card.spell_effects = parsed
	return card


func serialize() -> Dictionary:
	var effects: Array = []
	for e in spell_effects:
		effects.append(e.serialize())
	return {
		"card_id": card_id,
		"name": name,
		"cost": cost,
		"attack": attack,
		"health": health,
		"card_type": CardType.keys()[card_type],
		"metadata": metadata.duplicate(),
		"spell_effects": effects,
	}
