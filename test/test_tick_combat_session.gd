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

extends GutTest
## Verificación del paradigma tick de TickCombatSession. Los primeros casos
## fijan el upkeep por tick (economía de TODOS los lados vivos, refresh y el
## evento TICK); los de recuperación, jugadas simultáneas y batch de ataques
## (chunks siguientes) están diseñados para DISCRIMINAR contra el modelo
## secuencial: si la orquestación cayera a la FSM de turnos, fallan.


var _session: TickCombatSession


func before_each() -> void:
	_session = TickCombatSession.new()


func _hero(hp: int = 30) -> Combatant:
	var c := Combatant.new()
	c.max_health = hp
	c.current_health = hp
	return c


func _creature(cost: int, atk: int, hp: int) -> CardData:
	var d := CardData.new()
	d.cost = cost
	d.attack = atk
	d.health = hp
	d.play_kind = CardData.PlayKind.UNIT
	return d


func _deck(n: int = 8) -> Array[CardData]:
	var cards: Array[CardData] = []
	for i in n:
		cards.append(_creature(1, 2, 2))
	return cards


func _board_creature(side: int, card: CardData) -> CardInstance:
	var inst := CardInstance.new()
	inst.setup(card, side)
	_session.decks[side].add_to_board(inst)
	return inst


func test_run_tick_incrementa_tick_y_turn_number() -> void:
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	assert_true(_session.run_tick(), "el primer tick ejecuta")
	assert_eq(_session.tick_number, 1, "tick_number avanza por tick")
	assert_eq(_session.turn_number, 1, "turn_number acompaña: stalemate/get_result siguen útiles")
	assert_true(_session.run_tick(), "el segundo tick ejecuta")
	assert_eq(_session.tick_number, 2, "un tick más")
	assert_eq(_session.turn_number, 2, "un turn_number más")


func test_run_tick_emite_tick_ended_y_registra_evento_tick() -> void:
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var ticks: Array[int] = []
	_session.tick_ended.connect(func(n: int) -> void: ticks.append(n))
	_session.run_tick()
	_session.run_tick()
	assert_eq(ticks, [1, 2], "la señal dispara una vez por tick con su número")
	assert_eq(_session.event_log.back().type, CombatEvent.EventType.TICK, "el log registra el tick")
	assert_eq(_session.event_log.back().payload.get("tick", -1), 2, "el payload lleva el número de tick")


func test_fase_permanece_begin_y_es_auto_phase() -> void:
	# El paradigma tick no corre la FSM secuencial: phase queda en BEGIN (una
	# fase auto) hasta que la victoria la pasa a END, así una UI que consulta
	# is_auto_phase nunca pide input.
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.run_tick()
	assert_eq(_session.phase, CombatState.Phase.BEGIN, "sin FSM secuencial la fase no cambia")
	assert_true(CombatState.is_auto_phase(_session.phase), "BEGIN es auto: la UI no pide input")


func test_mana_refill_por_tick_llena_el_pool_y_rampa() -> void:
	# Economía espejo de la secuencial por turno, pero para TODOS los lados a la
	# vez: refill al max vigente y rampa de +2 (config default).
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.run_tick()
	assert_eq(_session.decks[0].mana, 2, "tick 1: refill a max_mana inicial (2)")
	assert_eq(_session.decks[0].max_mana, 4, "tick 1: rampa +2")
	assert_eq(_session.decks[1].mana, 2, "el lado 1 refilla EN EL MISMO tick")
	_session.run_tick()
	assert_eq(_session.decks[0].mana, 4, "tick 2: refill al nuevo max")
	assert_eq(_session.decks[0].max_mana, 6, "tick 2: rampa +2")


func test_mana_sin_refill_conserva_el_mana() -> void:
	_session.mana_refill_per_tick = false
	_session.mana_ramp_per_tick = false
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.decks[0].gain_mana(2)
	_session.run_tick()
	assert_eq(_session.decks[0].mana, 2, "sin refill el maná no cambia")
	assert_eq(_session.decks[0].max_mana, 2, "sin rampa el tope no crece")


func test_rampa_opt_in_mantiene_max_mana() -> void:
	_session.mana_ramp_per_tick = false
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.run_tick()
	_session.run_tick()
	assert_eq(_session.decks[0].max_mana, 2, "la rampa por tick es opt-in")
	assert_eq(_session.decks[0].mana, 2, "el refill sigue llenando al max vigente")


func test_robo_por_tick_es_opt_in() -> void:
	# Default: no se roba por tick (la mano inicial sale del setup).
	_session.setup(_hero(10), _deck(8), _hero(10), _deck(8), 1)
	var hand0: int = _session.decks[0].hand_size
	_session.run_tick()
	assert_eq(_session.decks[0].hand_size, hand0, "por defecto el tick no roba")
	_session.cards_drawn_per_tick = 2
	_session.run_tick()
	assert_eq(_session.decks[0].hand_size, hand0 + 2, "con cards_drawn_per_tick=2 roba 2")


func test_refresh_por_tick_habilita_can_attack_this_turn() -> void:
	# El upkeep refresca a TODOS los lados: la criatura sembrada con summoning
	# sickness queda lista para atacar en el mismo tick en que entró al upkeep.
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var inst := _board_creature(0, _creature(1, 2, 2))
	assert_false(inst.can_attack_this_turn, "recién sembrada no puede atacar")
	_session.run_tick()
	assert_true(inst.can_attack_this_turn, "el refresh del tick la habilita")


func test_ready_sides_devuelve_todos_los_lados_vivos() -> void:
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	assert_eq(_session.ready_sides(), [0, 1] as Array[int], "sin recovery ambos lados están ready")
	_session.heroes[1].take_damage(10)
	assert_eq(_session.ready_sides(), [0] as Array[int], "un héroe muerto sale de la lista")


func _seed_recovery(side: int, ticks: int) -> void:
	_session._ensure_tick_arrays()
	_session._recovery_ticks[side] = ticks


func test_recovery_excluye_al_lado_de_ready_sides() -> void:
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_seed_recovery(0, 1)
	assert_eq(_session.ready_sides(), [1] as Array[int], "un lado en recovery no está ready")
	assert_eq(_session.recovery_remaining(0), 1, "el contador es observable")
	assert_eq(_session.recovery_remaining(1), 0, "el lado 1 nunca entró en recovery")


func test_recovery_decrementa_uno_por_tick_y_vuelve_a_ready() -> void:
	# recovery N salta exactamente N ticks: readiness se evalúa ANTES del
	# decremento del upkeep, así 2 = no actúa en 2 ticks y vuelve al tercero.
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_seed_recovery(0, 2)
	_session.run_tick()
	assert_eq(_session.recovery_remaining(0), 1, "tick 1: 2 -> 1")
	assert_false(_session.ready_sides().has(0), "todavía en recovery")
	_session.run_tick()
	assert_eq(_session.recovery_remaining(0), 0, "tick 2: 1 -> 0")
	assert_true(_session.ready_sides().has(0), "al tercer tick vuelve a estar ready")


func test_recovery_fn_vacia_es_cero_para_toda_carta() -> void:
	# Opt-in como cost_fn: sin Callable inyectado, ninguna carta impone recovery.
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var card := _creature(1, 2, 2)
	card.metadata["recovery"] = 3
	assert_eq(_session._recovery_of(card, 0), 0, "sin hook el motor nunca lee metadata")


func test_recovery_fn_define_los_ticks_de_la_carta() -> void:
	# El hook decide qué significa recovery (típicamente un campo opaco de
	# metadata del juego); el motor solo ve un entero >= 0.
	_session.recovery_fn = func(card: CardData, _owner: int) -> int:
		return int(card.metadata.get("recovery", 0))
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var card := _creature(1, 2, 2)
	card.metadata["recovery"] = 3
	assert_eq(_session._recovery_of(card, 0), 3, "el hook dicta los ticks")
	var corta := _creature(1, 2, 2)
	corta.metadata["recovery"] = 0
	assert_eq(_session._recovery_of(corta, 0), 0, "cero = sin recovery")


func test_recovery_toma_el_maximo_no_suma() -> void:
	# Re-jugar mientras se recupera extiende a la ventana propia, no apila.
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.recovery_fn = func(card: CardData, _owner: int) -> int:
		return int(card.metadata.get("recovery", 0))
	var lenta := _creature(1, 2, 2)
	lenta.metadata["recovery"] = 3
	var media := _creature(1, 2, 2)
	media.metadata["recovery"] = 2
	_session._apply_recovery(0, lenta)
	_session._apply_recovery(0, media)
	assert_eq(_session.recovery_remaining(0), 3, "max(3, 2) = 3, no 5")
