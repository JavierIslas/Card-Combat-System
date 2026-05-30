class_name CardInstance
extends RefCounted
## Instancia viva de una carta en el tablero de combate. Lógica pura sin dependencia de escena.

signal card_died(card: CardInstance)
signal card_damaged(card: CardInstance, amount: int)
signal card_revealed(card: CardInstance)

## Disparadores de ciclo de vida. El handler de habilidades (inyectado por el
## juego vía ability_fn) reacciona a estos puntos; el motor no conoce la
## semántica concreta de cada habilidad.
enum Trigger { ON_SETUP, ON_TURN_REFRESH, ON_DEATH, ON_REVEAL }

var card_data: CardData = null
var owner_id: int = 0
var is_hidden: bool = false
var is_dead: bool = false
var hidden_stats: HiddenCardStats = null

var current_attack: int = 0
var current_health: int = 0
var can_attack_this_turn: bool = false
var damage_taken_this_turn: int = 0
var times_attacked: int = 0
var has_attacked_this_turn: bool = false

# Inmunidad
var immunity_hits_remaining: int = 0

# Mejoras acumuladas (PvE: cap de 2-3 por carta)
var upgrade_count: int = 0
const MAX_UPGRADES := 3

## Handler de habilidades inyectable. Firma: (inst: CardInstance, trigger: int).
## Si no se inyecta, el motor no aplica semántica de habilidades (agnóstico).
var ability_fn: Callable = Callable()


func setup(data: CardData, p_owner: int, p_hidden: bool = false) -> void:
	card_data = data
	owner_id = p_owner
	is_hidden = p_hidden

	if p_hidden:
		current_attack = hidden_stats.declared_attack if hidden_stats else data.attack
		current_health = hidden_stats.declared_health if hidden_stats else data.health
	else:
		current_attack = data.attack
		current_health = data.health

	_fire(Trigger.ON_SETUP)


func reveal() -> void:
	if not is_hidden:
		return

	is_hidden = false
	current_attack = card_data.attack
	current_health = card_data.health

	_fire(Trigger.ON_REVEAL)

	card_revealed.emit(self)


func take_damage(amount: int) -> int:
	## Aplica daño. Retorna daño real recibido (puede ser 0 con inmunidad).
	if amount <= 0:
		return 0
	if immunity_hits_remaining != 0:
		if immunity_hits_remaining > 0:
			immunity_hits_remaining -= 1
		return 0

	var actual := mini(amount, current_health)
	current_health -= actual
	damage_taken_this_turn += actual
	card_damaged.emit(self, actual)

	if current_health <= 0:
		_die()

	return actual


func heal(amount: int) -> void:
	if amount <= 0:
		return
	var max_hp := card_data.health + (upgrade_count if not is_hidden else 0)
	current_health = mini(current_health + amount, max_hp)


func apply_upgrade() -> bool:
	## PvE: mejora +1/+1. Retorna false si llegó al cap.
	if upgrade_count >= MAX_UPGRADES:
		return false
	upgrade_count += 1
	current_attack += 1
	current_health += 1
	return true


func refresh_for_turn() -> void:
	damage_taken_this_turn = 0
	has_attacked_this_turn = false
	times_attacked = 0
	can_attack_this_turn = false

	_fire(Trigger.ON_TURN_REFRESH)


func _die() -> void:
	is_dead = true
	_fire(Trigger.ON_DEATH)
	card_died.emit(self)


func _fire(trigger: Trigger) -> void:
	if ability_fn.is_valid():
		ability_fn.call(self, trigger)
