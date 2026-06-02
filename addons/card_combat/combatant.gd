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

class_name Combatant
extends Resource
## Generic combat participant: health + damage/heal with signals. Agnostic base of
## the combat engine. The game layer extends it for its participants (player) or
## instances it directly (enemy). The engine only knows this interface, never the
## game's concrete types.

signal health_changed(new_health: int)
signal died

@export var display_name: String = ""
@export var max_health: int = 30
@export var current_health: int = 30


func take_damage(amount: int) -> int:
	## Returns the damage actually applied (clamped so overkill is not counted),
	## mirroring CardInstance.take_damage for API parity.
	var actual: int = mini(maxi(amount, 0), current_health)
	current_health -= actual
	health_changed.emit(current_health)
	# <= 0 (not == 0) to match how the rest of the engine tests for death, so a
	# direct health set below zero still counts as dead.
	if current_health <= 0:
		died.emit()
	return actual


func heal(amount: int) -> void:
	current_health = mini(current_health + amount, max_health)
	health_changed.emit(current_health)


func is_alive() -> bool:
	return current_health > 0


func serialize() -> Dictionary:
	return {
		"display_name": display_name,
		"max_health": max_health,
		"current_health": current_health,
	}


static func deserialize(data: Dictionary) -> Combatant:
	## Rebuilds a base Combatant. A game with a subclassed hero re-hydrates its own
	## instance and passes it via the deserialize hooks instead.
	var c := Combatant.new()
	c.display_name = data.get("display_name", "")
	c.max_health = int(data.get("max_health", 30))
	c.current_health = int(data.get("current_health", c.max_health))
	return c
