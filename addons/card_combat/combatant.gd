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


func take_damage(amount: int) -> void:
	current_health = maxi(current_health - amount, 0)
	health_changed.emit(current_health)
	if current_health == 0:
		died.emit()


func heal(amount: int) -> void:
	current_health = mini(current_health + amount, max_health)
	health_changed.emit(current_health)


func is_alive() -> bool:
	return current_health > 0
