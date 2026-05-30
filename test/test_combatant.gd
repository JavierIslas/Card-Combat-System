extends GutTest
## Caracterización de Combatant: daño, curación, clamps y señales.

var _combatant: Combatant


func before_each() -> void:
	_combatant = Combatant.new()
	_combatant.max_health = 30
	_combatant.current_health = 30


func test_take_damage_reduce_vida() -> void:
	_combatant.take_damage(10)
	assert_eq(_combatant.current_health, 20)


func test_take_damage_no_baja_de_cero() -> void:
	_combatant.take_damage(100)
	assert_eq(_combatant.current_health, 0, "la vida se clampa a 0")


func test_heal_no_supera_max_health() -> void:
	_combatant.take_damage(20)  # 10
	_combatant.heal(100)
	assert_eq(_combatant.current_health, 30, "la cura se clampa a max_health")


func test_is_alive() -> void:
	assert_true(_combatant.is_alive(), "vivo con vida > 0")
	_combatant.take_damage(30)
	assert_false(_combatant.is_alive(), "muerto con vida 0")


func test_emite_health_changed() -> void:
	watch_signals(_combatant)
	_combatant.take_damage(5)
	assert_signal_emitted_with_parameters(_combatant, "health_changed", [25])


func test_emite_died_al_llegar_a_cero() -> void:
	watch_signals(_combatant)
	_combatant.take_damage(30)
	assert_signal_emitted(_combatant, "died")


func test_no_emite_died_si_sobrevive() -> void:
	watch_signals(_combatant)
	_combatant.take_damage(5)
	assert_signal_not_emitted(_combatant, "died")
