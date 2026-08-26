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
	# Los hooks viven por instancia (los siembra el deck al crear por
	# play_creature); una criatura sembrada cruda debe recibir el handler de
	# la sesión para que sus triggers disparen como una jugada real.
	if _session.ability_fn.is_valid():
		inst.ability_fn = _session.ability_fn
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


func _pass_ai() -> _ScriptedAI:
	# IA que siempre pasa: aísla los tests de upkeep de las jugadas.
	return _ScriptedAI.new()


func test_mana_refill_por_tick_llena_el_pool_y_rampa() -> void:
	# Economía espejo de la secuencial por turno, pero para TODOS los lados a la
	# vez: refill al max vigente y rampa de +2 (config default). Pass-AIs para
	# que ninguna jugada gaste el maná que se está midiendo.
	_session.ais[0] = _pass_ai()
	_session.ais[1] = _pass_ai()
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
	_session.ais[0] = _pass_ai()
	_session.ais[1] = _pass_ai()
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.decks[0].gain_mana(2)
	_session.run_tick()
	assert_eq(_session.decks[0].mana, 2, "sin refill el maná no cambia")
	assert_eq(_session.decks[0].max_mana, 2, "sin rampa el tope no crece")


func test_rampa_opt_in_mantiene_max_mana() -> void:
	_session.mana_ramp_per_tick = false
	_session.ais[0] = _pass_ai()
	_session.ais[1] = _pass_ai()
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.run_tick()
	_session.run_tick()
	assert_eq(_session.decks[0].max_mana, 2, "la rampa por tick es opt-in")
	assert_eq(_session.decks[0].mana, 2, "el refill sigue llenando al max vigente")


func test_robo_por_tick_es_opt_in() -> void:
	# Default: no se roba por tick (la mano inicial sale del setup). Pass-AIs
	# para que ninguna jugada altere la mano que se está midiendo.
	_session.ais[0] = _pass_ai()
	_session.ais[1] = _pass_ai()
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


# Doble de test: decisiones pre-programadas, cero RNG. Solo sobreescribe lo que
# el modo tick consulta; si el motor llamara a un método no sobreescrito (p. ej.
# choose_blockers), CombatAI hace push_error y el test falla ruidosamente.
class _ScriptedAI:
	extends CombatAI
	var next_card: CardData = null
	var spell_target: Variant = null
	var swing: bool = false          # choose_attackers devuelve el tablero entero
	var attack_target: Variant = null  # objetivo dirigido; null = swing al héroe
	var card_calls: int = 0
	var attackers_calls: int = 0

	func choose_card_to_play(_hand: Array[CardData], _mana: int) -> CardData:
		card_calls += 1
		return next_card

	func choose_spell_target(_spell: CardData, _own_board: Array[CardInstance],
			_enemy_board: Array[CardInstance]) -> Variant:
		return spell_target

	func choose_attackers(board: Array[CardInstance],
			_enemy_heroes: Array[Combatant] = []) -> Array[CardInstance]:
		attackers_calls += 1
		if not swing:
			return []
		return board

	func choose_attack_target(_attacker: CardInstance, _enemy_board: Array[CardInstance],
			_enemy_heroes: Array[Combatant] = []) -> Variant:
		return attack_target


func _spell(cost: int, type: SpellEffect.EffectType, value: int, target: SpellEffect.TargetType) -> CardData:
	var d := CardData.new()
	d.cost = cost
	d.play_kind = CardData.PlayKind.EFFECT
	var e := SpellEffect.new()
	e.effect_type = type
	e.value = value
	e.target_type = target
	var effects: Array[SpellEffect] = [e]
	d.spell_effects = effects
	return d


func test_una_sola_consulta_de_carta_por_lado_por_tick() -> void:
	# La selección del tick es UNA llamada a choose_card_to_play por lado ready:
	# no hay loop de mano como el MAIN secuencial (una acción por tick).
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	ai0.next_card = _session.decks[0].get_hand()[0]
	_session.run_tick()
	assert_eq(ai0.card_calls, 1, "una única consulta por tick")
	assert_eq(_session.decks[0].hand_size, 2, "jugó exactamente una carta (mano 3 -> 2)")
	assert_eq(_session.decks[0].board_size, 1, "la criatura entró al tablero")


func test_jugadas_resuelven_en_orden_de_indice_de_lado() -> void:
	# La resolución secuencial por orden de lado es lo determinista; la
	# simultaneidad real vive en la selección y en el batch de ataques.
	var ai0 := _ScriptedAI.new()
	var ai1 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.ais[1] = ai1
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	ai0.next_card = _session.decks[0].get_hand()[0]
	ai1.next_card = _session.decks[1].get_hand()[0]
	_session.run_tick()
	var owners: Array = []
	for ev in _session.event_log:
		if ev.type == CombatEvent.EventType.CARD_PLAYED:
			owners.append(ev.payload["owner"])
	assert_eq(owners, [0, 1], "las jugadas resuelven en orden de lado")


func test_target_declarado_muerto_por_jugada_previa_fizzlea() -> void:
	# El observable de la selección simultánea: el lado 1 eligió a la víctima
	# contra el board pre-tick; al ejecutar, la jugada del lado 0 ya la mató.
	# Fizzle ATÓMICO (contrato de la base): la carta y el maná quedan intactos.
	var ai0 := _ScriptedAI.new()
	var ai1 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.ais[1] = ai1
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var victima := _board_creature(1, _creature(1, 2, 2))
	var aoe := _spell(2, SpellEffect.EffectType.AOE_DAMAGE, 5, SpellEffect.TargetType.ENEMY_CREATURES)
	_session.decks[0]._hand.append(aoe)
	ai0.next_card = aoe
	var buff := _spell(2, SpellEffect.EffectType.BUFF_ATTACK, 2, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.decks[1]._hand.append(buff)
	ai1.next_card = buff
	ai1.spell_target = victima
	_session.run_tick()
	assert_true(victima.is_dead, "el AOE del lado 0 mató a la víctima")
	assert_true(_session.decks[1].get_hand().has(buff), "la carta del lado 1 NO se consumió")
	assert_eq(_session.decks[1].mana, 2, "el maná del lado 1 quedó intacto")
	var fizzled := false
	for ev in _session.event_log:
		if ev.type == CombatEvent.EventType.SPELL_FIZZLED:
			fizzled = true
	assert_true(fizzled, "el fizzle quedó registrado en el log")


func test_pase_de_ia_no_juga_nada() -> void:
	# null = "paso" (en el chunk 4 ese paso habilita la acción de ataque).
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_session.run_tick()
	assert_eq(ai0.card_calls, 1, "el paso también se consulta")
	assert_eq(_session.decks[0].hand_size, 3, "no jugó nada")
	assert_eq(_session.decks[0].board_size, 0, "nada entró al tablero")


func test_declare_tick_intent_overridea_a_la_ia_un_tick() -> void:
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	ai0.next_card = _session.decks[0].get_hand()[0]
	var manual := _session.decks[0].get_hand()[1]
	assert_true(_session.declare_tick_intent(0, manual), "el intent manual se acepta")
	_session.run_tick()
	assert_eq(_session.decks[0].hand_size, 2, "jugó exactamente una")
	assert_false(_session.decks[0].get_hand().has(manual), "jugó la del intent manual")
	assert_eq(ai0.card_calls, 0, "el intent pisa a la IA ese tick")
	ai0.next_card = _session.decks[0].get_hand()[0]
	_session.run_tick()
	assert_eq(ai0.card_calls, 1, "el intent se consume y la IA vuelve")


func test_carta_no_jugable_se_trata_como_pase() -> void:
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var cara := _creature(9, 2, 2)
	_session.decks[0]._hand.append(cara)
	ai0.next_card = cara
	_session.run_tick()
	assert_true(_session.decks[0].get_hand().has(cara), "la carta ilegal no se consume")
	assert_eq(_session.decks[0].board_size, 0, "y no entra al tablero")


func test_on_play_y_on_cast_se_disparan_en_modo_tick() -> void:
	# Una acción por tick: la criatura entra en el tick 1 (ON_PLAY), el hechizo
	# en el tick 2 (ON_CAST side-level con inst null).
	var triggers: Array = []
	_session.ability_fn = func(_inst: Variant, trigger: int, _ctx: Dictionary) -> void:
		triggers.append(trigger)
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	ai0.next_card = _session.decks[0].get_hand()[0]
	_session.run_tick()
	assert_true(CardInstance.Trigger.ON_PLAY in triggers, "ON_PLAY disparó al jugar criatura")
	var hechizo := _spell(1, SpellEffect.EffectType.DAMAGE, 1, SpellEffect.TargetType.ENEMY_CREATURES)
	_session.decks[0]._hand.append(hechizo)
	ai0.next_card = hechizo
	_session.run_tick()
	assert_true(CardInstance.Trigger.ON_CAST in triggers, "ON_CAST disparó al lanzar el hechizo")


func test_jugar_carta_con_recovery_arma_el_contador_y_bloquea() -> void:
	# End-to-end del recovery: la jugada arma el contador; en recovery el lado
	# ni se consulta (acción bloqueada) pero su economía sigue viva.
	_session.recovery_fn = func(_card: CardData, _owner: int) -> int:
		return 1
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	ai0.next_card = _session.decks[0].get_hand()[0]
	_session.run_tick()
	assert_eq(_session.recovery_remaining(0), 1, "la jugada armó 1 tick de recovery")
	assert_eq(_session.decks[0].hand_size, 2, "la carta se jugó")
	ai0.next_card = _session.decks[0].get_hand()[0]
	_session.run_tick()
	assert_eq(ai0.card_calls, 1, "en recovery la IA no se consulta")
	assert_eq(_session.recovery_remaining(0), 0, "el upkeep decrementó")
	assert_eq(_session.decks[0].mana, 4, "la economía del lado siguió viva")


func test_ambos_heroes_mueren_en_el_mismo_tick() -> void:
	# EL caso discriminante del paradigma: dos swings a héroe que resuelven en
	# UN batch => ambos héroes caen a 0 en el tick 1 => tablas. En el secuencial
	# esto es imposible: el primer swing mata al héroe rival, _check_victory
	# corta el combate y el otro héroe sobrevive.
	var ai0 := _ScriptedAI.new()
	var ai1 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.ais[1] = ai1
	_session.setup(_hero(3), _deck(4), _hero(3), _deck(4), 1)
	_board_creature(0, _creature(1, 3, 3))
	_board_creature(1, _creature(1, 3, 3))
	ai0.swing = true
	ai1.swing = true
	assert_true(_session.run_tick(), "el tick ejecuta")
	assert_eq(_session.tick_number, 1, "un solo tick corrió")
	assert_eq(_session.heroes[0].current_health, 0, "héroe 0 murió en este tick")
	assert_eq(_session.heroes[1].current_health, 0, "héroe 1 murió en el MISMO tick")
	assert_eq(_session.winner_team, -1, "ambos equipos cayeron: tablas")
	assert_eq(_session.phase, CombatState.Phase.END, "la victoria se settleó al cierre")
	assert_eq(ai0.card_calls, 1, "cada lado fue consultado UNA vez (paso = atacar)")
	assert_eq(ai1.card_calls, 1, "el lado 1 decidió contra el mismo snapshot pre-tick")


func test_trade_mutuo_entre_lados_muere_en_el_mismo_tick() -> void:
	# Dos criaturas enemigas se declaran mutuamente en el mismo batch: el
	# resolver calcula TODO antes de aplicar, así ambas caen (trade real).
	var ai0 := _ScriptedAI.new()
	var ai1 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.ais[1] = ai1
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var a := _board_creature(0, _creature(1, 3, 3))
	var b := _board_creature(1, _creature(1, 3, 3))
	ai0.swing = true
	ai0.attack_target = b
	ai1.swing = true
	ai1.attack_target = a
	_session.run_tick()
	assert_true(a.is_dead, "la criatura del lado 0 murió")
	assert_true(b.is_dead, "la criatura del lado 1 murió en el MISMO batch")


func test_danio_a_heroe_se_agrega_por_target_side_en_un_solo_evento() -> void:
	# Dos swings 2/2 al mismo héroe => UN evento COMBATANT_DAMAGED de 4,
	# igual que la agregación de _resolve_active_attacks en el secuencial.
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_board_creature(0, _creature(1, 2, 2))
	_board_creature(0, _creature(1, 2, 2))
	ai0.swing = true
	_session.run_tick()
	var hits: Array = []
	for ev in _session.event_log:
		if ev.type == CombatEvent.EventType.COMBATANT_DAMAGED:
			hits.append([ev.payload["side"], ev.payload["amount"]])
	assert_eq(hits, [[1, 4]], "un único evento agregado por lado objetivo")
	assert_eq(_session.heroes[1].current_health, 6, "el héroe 1 recibió 4")


func test_pase_de_ia_convierte_en_ataque() -> void:
	# null en choose_card_to_play = "agredir": la acción del tick es el swing.
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_board_creature(0, _creature(1, 3, 3))
	ai0.swing = true
	_session.run_tick()
	assert_eq(ai0.attackers_calls, 1, "el paso consultó los atacantes")
	assert_eq(_session.heroes[1].current_health, 7, "el swing conectó (10 - 3)")


func test_carta_jugada_excluye_de_atacar_ese_tick() -> void:
	# Una acción por tick: el lado que jugó carta NO también ataca.
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	_board_creature(0, _creature(1, 3, 3))
	ai0.next_card = _session.decks[0].get_hand()[0]
	_session.run_tick()
	assert_eq(ai0.attackers_calls, 0, "quien jugó carta no ataca ese tick")
	assert_eq(_session.heroes[1].current_health, 10, "el héroe 1 no recibió daño")


func test_atacante_muerto_por_reaccion_se_descarta_del_batch() -> void:
	# La reacción ON_ATTACK de una criatura declarada DESPUÉS mata a otra
	# declarada antes: el whiff filter la saca del batch (su daño no cae).
	# El contenedor mutable es el patrón de capture de los tests existentes
	# (ability_fn se siembra antes del setup, la criatura existe recién después).
	var victima: Array = []
	_session.ability_fn = func(inst: CardInstance, trigger: int, _ctx: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_ATTACK and inst != null \
				and inst.card_data.attack >= 3 and not victima.is_empty():
			(victima[0] as CardInstance).take_damage(5)
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	victima.append(_board_creature(0, _creature(1, 2, 2)))
	_board_creature(0, _creature(1, 3, 3))  # declarada después; su reacción mata
	ai0.swing = true
	_session.run_tick()
	assert_true((victima[0] as CardInstance).is_dead, "la reacción la mató antes del batch")
	assert_eq(_session.heroes[1].current_health, 7, "solo el 3/3 conectó (10 - 3), no 5")


func test_taunt_redirige_la_seleccion_en_autobatch() -> void:
	# El hook de restricción evalúa contra los enemigos del ATACANTE (no del
	# active_side): la IA pidió swing a héroe y fue redirigida a la criatura.
	_session.attack_restriction_fn = func(_attacker: CardInstance, enemy_creatures: Array) -> Array:
		return enemy_creatures
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var taunto := _board_creature(1, _creature(1, 2, 5))
	_board_creature(0, _creature(1, 3, 3))
	ai0.swing = true
	ai0.attack_target = null  # pidió héroe
	_session.run_tick()
	assert_eq(_session.heroes[1].current_health, 10, "el swing al héroe fue redirigido")
	assert_eq(taunto.current_health, 2, "el taunto absorbió el golpe (5 - 3)")


func test_congelado_no_ataca_ese_tick() -> void:
	var ai0 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.setup(_hero(10), _deck(4), _hero(10), _deck(4), 1)
	var congelada := _board_creature(0, _creature(1, 3, 3))
	congelada.freeze(1)
	ai0.swing = true
	_session.run_tick()
	assert_eq(_session.heroes[1].current_health, 10, "congelada no atacó este tick")
	assert_false(congelada.is_frozen(), "el freeze se consumió en el upkeep")
	_session.run_tick()
	assert_eq(_session.heroes[1].current_health, 7, "al tick siguiente ataca")


func test_heroe_muerto_a_mitad_de_tick_no_ataca_y_victoria_al_cierre() -> void:
	# Liveness inmediata, victoria diferida: el hechizo del lado 0 mata al héroe
	# 1 en la etapa de jugadas; el lado 1 ya no ataca ese tick y el settle corre
	# una sola vez al cierre.
	var ai0 := _ScriptedAI.new()
	var ai1 := _ScriptedAI.new()
	_session.ais[0] = ai0
	_session.ais[1] = ai1
	_session.setup(_hero(10), _deck(4), _hero(5), _deck(4), 1)
	_board_creature(1, _creature(1, 3, 3))
	var bolt := _spell(2, SpellEffect.EffectType.DAMAGE, 5, SpellEffect.TargetType.ENEMY_HERO)
	_session.decks[0]._hand.append(bolt)
	ai0.next_card = bolt
	ai1.swing = true
	_session.run_tick()
	assert_eq(_session.heroes[1].current_health, 0, "el bolt mató al héroe 1")
	assert_eq(_session.heroes[0].current_health, 10, "el lado muerto no ejecutó su swing")
	assert_eq(_session.winner_team, 0, "victoria settleada al cierre del tick")
	assert_false(_session.run_tick(), "el combate terminó")
