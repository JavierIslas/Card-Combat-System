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
## Vida máxima actual de la instancia (incluye buffs permanentes). Es el tope
## que respeta heal(). El motor no la deriva de reglas del juego.
var current_max_health: int = 0
var can_attack_this_turn: bool = false
var damage_taken_this_turn: int = 0
var times_attacked: int = 0
var has_attacked_this_turn: bool = false

# Inmunidad
var immunity_hits_remaining: int = 0

## Mejoras permanentes acumuladas (genéricas: cualquier delta vía
## apply_permanent_buff). El motor no conoce "+1/+1": el delta y el tope los
## decide la capa-juego. El tope se siembra desde CombatConfig vía el deck.
var permanent_buff_count: int = 0
var max_permanent_buffs: int = -1  # -1 = ilimitado
## Accumulated permanent-buff deltas. Kept so reveal() can rebuild real stats
## without discarding buffs applied while the card was hidden.
var _buff_attack_total: int = 0
var _buff_health_total: int = 0

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
	current_max_health = current_health

	_fire(Trigger.ON_SETUP)


func reveal() -> void:
	if not is_hidden:
		return

	is_hidden = false
	current_attack = card_data.attack + _buff_attack_total
	current_health = card_data.health + _buff_health_total
	current_max_health = card_data.health + _buff_health_total

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
	current_health = mini(current_health + amount, current_max_health)


func apply_permanent_buff(attack_delta: int, health_delta: int, max_buffs: int = -1) -> bool:
	## Mejora permanente genérica. El delta lo decide la capa-juego; el tope sale
	## de max_buffs (override puntual) o de max_permanent_buffs (sembrado desde
	## CombatConfig). Cap < 0 = ilimitado. Retorna false si llegó al tope.
	var cap := max_buffs if max_buffs >= 0 else max_permanent_buffs
	if cap >= 0 and permanent_buff_count >= cap:
		return false
	permanent_buff_count += 1
	_buff_attack_total += attack_delta
	_buff_health_total += health_delta
	current_attack += attack_delta
	current_health += health_delta
	current_max_health += health_delta
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
