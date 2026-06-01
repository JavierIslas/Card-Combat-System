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
## Participante de combate genérico: salud + daño/curación con señales.
## Base agnóstica del motor de combate. La capa-juego la extiende para sus
## participantes (jugador) o la instancia directamente (enemigo). El motor sólo
## conoce esta interfaz, nunca los tipos concretos del juego.

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
	if current_health == 0:
		died.emit()
	return actual


func heal(amount: int) -> void:
	current_health = mini(current_health + amount, max_health)
	health_changed.emit(current_health)


func is_alive() -> bool:
	return current_health > 0
