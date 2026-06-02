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

class_name HiddenCardStats
extends Resource
## Declared stats for a card played face-down (bluff).

@export var declared_attack: int = 0
@export var declared_health: int = 0
## Abilities declared in the bluff. Untyped (Array) and opaque to the core; the
## game layer interprets the content (no coupling to concrete ability types).
@export var declared_abilities: Array = []
@export var total_mana_invested: int = 0


func serialize() -> Dictionary:
	return {
		"declared_attack": declared_attack,
		"declared_health": declared_health,
		"declared_abilities": declared_abilities.duplicate(),
		"total_mana_invested": total_mana_invested,
	}


static func from_dict(data: Dictionary) -> HiddenCardStats:
	var stats := HiddenCardStats.new()
	stats.declared_attack = int(data.get("declared_attack", 0))
	stats.declared_health = int(data.get("declared_health", 0))
	stats.total_mana_invested = int(data.get("total_mana_invested", 0))
	# declared_abilities is opaque to the core: raw passthrough. The game layer
	# builds the concrete ability objects if it needs them.
	var decl: Variant = data.get("declared_abilities", [])
	if decl is Array:
		stats.declared_abilities = (decl as Array).duplicate()
	return stats
