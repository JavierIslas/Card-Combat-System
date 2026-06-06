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

## How playing the card resolves — the engine's only behavioral dispatch, NOT a
## game taxonomy. UNIT goes to the board and persists (attacks/blocks); EFFECT
## resolves its spell_effects and goes to the graveyard; PERSISTENT goes to the
## board and persists (fires triggers) but never fights — it is not a combatant, so
## it cannot attack or block (an aura/enchantment-style permanent). Game-domain
## types (Weapon, Land, Trap, rarity, …) belong in `metadata`, never here.
enum PlayKind { UNIT, EFFECT, PERSISTENT }

@export var card_id: String = ""
@export var name: String = ""
@export var cost: int = 0
@export var attack: int = 0
@export var health: int = 0
@export var play_kind: PlayKind = PlayKind.UNIT
@export var metadata: Dictionary = {}
## Spell effects, authored on the card. Exportable now that SpellEffect is a
## Resource, so a card defined as a .tres persists its effects natively.
@export var spell_effects: Array[SpellEffect] = []


func get_total_cost() -> int:
	return cost


func needs_explicit_target() -> bool:
	## Whether casting this card requires a caller-supplied target: true if any of its
	## effects needs one (PLAYER_CREATURE / CHOSEN_CREATURES). Single source shared by the
	## session's fizzle/targeting checks and the AIs.
	for effect in spell_effects:
		if effect.needs_explicit_target():
			return true
	return false


func chosen_target_count() -> int:
	## How many creatures a CHOSEN_CREATURES effect on this card targets (its
	## target_count, floored at 1), or 0 if the card has no such effect. Lets a driver/AI
	## size a multi-target pick without reaching into spell_effects.
	for effect in spell_effects:
		if effect.target_type == SpellEffect.TargetType.CHOSEN_CREATURES:
			return maxi(effect.target_count, 1)
	return 0


func targets_enemies() -> bool:
	## Whether this card's first effect aims at enemies (a damaging effect) rather than
	## allies (heal/buff). Defaults to true when the card declares no effects, matching the
	## reference AIs' fallback.
	if spell_effects.is_empty():
		return true
	return spell_effects[0].is_damage()


func can_afford(player_mana: int) -> bool:
	return player_mana >= get_total_cost()


static func from_dict(data: Dictionary) -> CardData:
	var card := CardData.new()
	card.card_id = data.get("card_id", "")
	card.name = data.get("name", "")
	card.cost = int(data.get("cost", 0))
	card.attack = int(data.get("attack", 0))
	card.health = int(data.get("health", 0))
	var kind_idx := PlayKind.keys().find(data.get("play_kind", "UNIT"))
	if kind_idx == -1:
		push_warning("CardData.from_dict: invalid play_kind — %s" % data.get("play_kind", ""))
		return null
	card.play_kind = kind_idx as PlayKind
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
		"play_kind": PlayKind.keys()[play_kind],
		"metadata": metadata.duplicate(),
		"spell_effects": effects,
	}
