extends GutTest
## Caracterizacion de CombatSession: FSM de turnos alternados, rampa de mana,
## auto_resolve, bloqueo bilateral, regresiones de hechizos y declaracion de ataque.


var _session: CombatSession


func before_each() -> void:
	_session = CombatSession.new()


func _hero(hp: int = 30) -> Combatant:
	var c := Combatant.new()
	c.max_health = hp
	c.current_health = hp
	return c


func _creature(cost: int, attack: int, health: int) -> CardData:
	var d := CardData.new()
	d.cost = cost
	d.attack = attack
	d.health = health
	d.card_type = CardData.CardType.CRIATURA
	return d


func _spell(cost: int, type: SpellEffect.EffectType, value: int, target: SpellEffect.TargetType) -> CardData:
	var d := CardData.new()
	d.cost = cost
	d.card_type = CardData.CardType.HECHIZO
	var e := SpellEffect.new()
	e.effect_type = type
	e.value = value
	e.target_type = target
	var effects: Array[SpellEffect] = [e]
	d.spell_effects = effects
	return d


func _empty() -> Array[CardData]:
	var a: Array[CardData] = []
	return a


func _setup_basico() -> void:
	_session.setup(_hero(), _empty(), _hero(), _empty(), 1)


func _starter() -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.append(_creature(1, 2, 1))
	cards.append(_creature(2, 2, 3))
	cards.append(_creature(3, 4, 4))
	cards.append(_creature(4, 4, 6))
	cards.append(_creature(1, 1, 2))
	return cards


func _run_seeded(combat_seed: int) -> Dictionary:
	var session := CombatSession.new()
	session.setup(_hero(), _starter(), _hero(), _starter(), combat_seed)
	session.auto_resolve()
	return session.get_result()


func test_mismo_seed_reproduce_la_partida() -> void:
	# Replay guarantee: same combat seed (seeds both deck shuffles + both AIs) plus
	# the same starting cards => identical match.
	var first := _run_seeded(7)
	var second := _run_seeded(7)
	assert_gt(first["turn_number"], 1, "la partida realmente avanzó turnos")
	assert_eq(first, second, "mismo seed reproduce el resultado del combate")


func test_start_va_a_principal_en_turno_uno() -> void:
	_setup_basico()
	_session.start()
	assert_eq(_session.phase, CombatState.Phase.MAIN, "tras start queda en MAIN")
	assert_eq(_session.turn_number, 1, "primer turno")
	assert_eq(_session.active_side, 0, "el lado 0 arranca activo")


func _serialized_log(session: CombatSession) -> Array:
	var out: Array = []
	for ev in session.event_log:
		out.append(ev.serialize())
	return out


func test_event_log_registra_el_combate() -> void:
	var hero_cards: Array[CardData] = [_creature(1, 2, 2)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(10), hero_cards, _hero(10), enemy_cards, 7)
	_session.auto_resolve()
	assert_gt(_session.event_log.size(), 0, "el combate deja eventos en el log")
	var last: CombatEvent = _session.event_log[-1]
	assert_eq(last.type, CombatEvent.EventType.COMBAT_ENDED, "el último evento es el fin del combate")


func test_event_log_es_determinista_por_seed() -> void:
	# Same seeds => identical serialized event stream (replay-friendly).
	var first := CombatSession.new()
	first.setup(_hero(10), _starter(), _hero(10), _starter(), 11)
	first.auto_resolve()
	var second := CombatSession.new()
	second.setup(_hero(10), _starter(), _hero(10), _starter(), 11)
	second.auto_resolve()
	assert_eq(_serialized_log(first), _serialized_log(second), "mismo seed reproduce el log de eventos")


func test_integracion_event_log_incluye_muerte_por_hechizo_serializada() -> void:
	# End-to-end: jugar un hechizo AOE que mata debe dejar un CREATURE_DIED en el
	# event_log, serializable con el card_id y owner correctos (replay-friendly).
	var session := CombatSession.new()
	var aoe := _spell(1, SpellEffect.EffectType.AOE_DAMAGE, 5, SpellEffect.TargetType.ENEMY_CREATURES)
	aoe.card_id = "meteoro"
	var s0_cards: Array[CardData] = [aoe]
	session.setup(_hero(10), s0_cards, _hero(10), _empty(), 3)
	session.start()
	var victima := CardInstance.new()
	var victim_data := _creature(1, 0, 1)
	victim_data.card_id = "goblin"
	victima.setup(victim_data, 1)
	session.decks[1].add_to_board(victima)
	assert_true(session.play_card(aoe), "el AOE se juega desde la mano")
	assert_true(victima.is_dead, "el AOE mata a la criatura enemiga")
	var serial := _serialized_log(session)
	var deaths := serial.filter(func(e: Dictionary) -> bool: return e["type"] == "CREATURE_DIED")
	assert_eq(deaths.size(), 1, "la muerte por hechizo queda en el log serializado")
	assert_eq(deaths[0]["payload"]["card_id"], "goblin", "con el card_id correcto")
	assert_eq(deaths[0]["payload"]["owner"], 1, "y el owner correcto")


func test_event_log_se_limpia_en_setup() -> void:
	_setup_basico()
	_session.auto_resolve()
	assert_gt(_session.event_log.size(), 0, "hay eventos tras un combate")
	_session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	assert_eq(_session.event_log.size(), 0, "setup limpia el log para reutilizar la sesión")


func test_advance_desde_inicio_arranca_el_combate() -> void:
	# advance() keeps BEGIN actionable after dropping the dead RESOLVE/END arms.
	_setup_basico()
	assert_eq(_session.phase, CombatState.Phase.BEGIN, "arranca en BEGIN")
	_session.advance()
	assert_eq(_session.phase, CombatState.Phase.MAIN, "advance desde BEGIN encadena hasta MAIN")


func _dead_instance(owner: int) -> CardInstance:
	var inst := CardInstance.new()
	inst.setup(_creature(1, 1, 1), owner)
	inst.is_dead = true
	return inst


func _live_instance(owner: int, attack: int, health: int) -> CardInstance:
	var inst := CardInstance.new()
	inst.setup(_creature(1, attack, health), owner)
	return inst


func _logged_types(session: CombatSession) -> Array:
	var types: Array = []
	for ev in session.event_log:
		types.append(ev.type)
	return types


func test_muerte_por_hechizo_aoe_se_reporta() -> void:
	# Regression: AOE/ENEMY_CREATURES kills must surface like combat deaths, or the
	# event_log and get_dead_creatures would silently miss them and break replay.
	_setup_basico()
	var victima := _live_instance(1, 0, 1)
	_session.decks[1].add_to_board(victima)
	var deaths: Array = []
	_session.creature_died.connect(func(card: CardInstance, owner: int) -> void: deaths.append(owner))
	var aoe := SpellEffect.new()
	aoe.effect_type = SpellEffect.EffectType.AOE_DAMAGE
	aoe.value = 5
	aoe.target_type = SpellEffect.TargetType.ENEMY_CREATURES
	_session._apply_single_spell_effect(aoe, 0)
	assert_true(victima.is_dead, "el AOE mata a la criatura")
	assert_eq(deaths.size(), 1, "emite creature_died exactamente una vez")
	assert_eq(deaths[0], 1, "el owner reportado es el lado 1")
	assert_true(_session.get_dead_creatures(1).has(victima), "queda rastreada en get_dead_creatures")
	assert_false(_session.decks[1].get_board().has(victima), "sale del tablero")
	assert_true(_logged_types(_session).has(CombatEvent.EventType.CREATURE_DIED), "el event_log registra la muerte")


func test_muerte_por_hechizo_single_target_se_reporta_una_vez() -> void:
	# A single-target damage that kills also reports; the idempotent _record_death
	# guarantees a single emission despite the post-effect board sweep.
	_setup_basico()
	var victima := _live_instance(1, 0, 1)
	_session.decks[1].add_to_board(victima)
	var deaths: Array = []
	_session.creature_died.connect(func(card: CardInstance, owner: int) -> void: deaths.append(owner))
	var dmg := SpellEffect.new()
	dmg.effect_type = SpellEffect.EffectType.DAMAGE
	dmg.value = 5
	dmg.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	_session._apply_single_spell_effect(dmg, 0, victima)
	assert_true(victima.is_dead, "el hechizo single-target mata a la criatura")
	assert_eq(deaths.size(), 1, "una sola emisión pese al barrido de muertes")
	assert_true(_session.get_dead_creatures(1).has(victima), "queda rastreada en get_dead_creatures")


func test_get_dead_creatures_rastrea_cada_lado() -> void:
	_setup_basico()
	var dead_side1 := _dead_instance(1)
	var dead_side0 := _dead_instance(0)
	var pairs: Array = [{
		"attacker": dead_side0,
		"defender": dead_side1,
		"attacker_died": true,
		"defender_died": true,
	}]
	_session._process_death_results(pairs)
	var s1_dead := _session.get_dead_creatures(1)
	var s0_dead := _session.get_dead_creatures(0)
	assert_eq(s1_dead.size(), 1, "la criatura del lado 1 muerta se rastrea")
	assert_true(s1_dead.has(dead_side1), "es la instancia del lado 1 correcta")
	assert_eq(s0_dead.size(), 1, "la criatura del lado 0 sigue rastreándose")
	assert_true(s0_dead.has(dead_side0), "es la instancia del lado 0 correcta")


func test_get_dead_creatures_vacio_sin_combate() -> void:
	assert_eq(_session.get_dead_creatures(1), [], "sin deck del lado devuelve vacío")


func test_emite_phase_changed_al_iniciar() -> void:
	_setup_basico()
	watch_signals(_session)
	_session.start()
	assert_signal_emitted(_session, "phase_changed")


func test_rampa_de_mana_primer_turno() -> void:
	_setup_basico()
	_session.start()
	assert_eq(_session.decks[0].mana, 2, "gana mana hasta su max inicial (2)")
	assert_eq(_session.decks[0].max_mana, 4, "el max sube por la rampa (2 -> 4)")


func test_solo_el_lado_activo_rampa_en_su_turno() -> void:
	# Alternating turns: only the active side ramps/draws on its own turn; the
	# passive side does not ramp while it's not its turn.
	_setup_basico()
	_session.start()
	assert_eq(_session.active_side, 0, "es el turno del lado 0")
	assert_eq(_session.decks[0].mana, 2, "el lado activo gana mana")
	assert_eq(_session.decks[1].mana, 0, "el lado pasivo NO rampa en el turno del 0")


func test_el_turno_alterna_el_lado_activo() -> void:
	# After RESOLVE the turn passes to the other side.
	_session.setup(_hero(30), [_creature(5, 1, 1)], _hero(30), [_creature(5, 1, 1)], 1)
	_session.start()
	assert_eq(_session.active_side, 0, "arranca el lado 0")
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.end_defense_phase()
	assert_eq(_session.active_side, 1, "tras resolver, el turno pasa al lado 1")
	assert_eq(_session.phase, CombatState.Phase.MAIN, "y arranca el MAIN del lado 1")


func test_auto_resolve_termina_en_final() -> void:
	var hero_cards: Array[CardData] = [_creature(1, 2, 2), _creature(1, 1, 3)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(10), hero_cards, _hero(10), enemy_cards, 7)
	_session.auto_resolve()
	assert_eq(_session.phase, CombatState.Phase.END, "auto_resolve llega a END sin colgarse")


func test_auto_resolve_corta_al_agotar_iteraciones() -> void:
	# With a tiny cap the loop exits in ATTACK, before any damage resolves: the
	# guard must force END even though nobody won, lost, or stalemated.
	var hero_cards: Array[CardData] = [_creature(1, 2, 2)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(30), hero_cards, _hero(30), enemy_cards, 7)
	_session._auto_resolve_max_iterations = 1
	_session.auto_resolve()
	assert_eq(_session.phase, CombatState.Phase.END, "el guard fuerza END al agotar iteraciones")
	assert_gt(_session.heroes[1].current_health, 0, "no terminó por victoria (corte forzado)")
	assert_gt(_session.heroes[0].current_health, 0, "no terminó por derrota (corte forzado)")
	assert_lt(_session.turn_number, _session.config.stalemate_turn_limit, "tampoco es tablas")


func test_get_result_tiene_claves_esperadas() -> void:
	_setup_basico()
	_session.start()
	var result := _session.get_result()
	assert_has(result, "winner_side")
	assert_has(result, "turn_number")
	assert_has(result, "hp")


func test_winner_side_es_el_lado_del_heroe_vivo() -> void:
	_session.setup(_hero(5), _empty(), _hero(30), _empty(), 1)
	_session.heroes[0].take_damage(5)
	_session._check_victory()
	assert_eq(_session.phase, CombatState.Phase.END, "muerto un héroe, el combate termina")
	assert_eq(_session.winner_side, 1, "gana el lado cuyo héroe sigue vivo")


func test_winner_side_menos_uno_en_tablas() -> void:
	# Empty decks resolve to a stalemate on the first turn: no winner.
	_setup_basico()
	_session.auto_resolve()
	assert_eq(_session.phase, CombatState.Phase.END, "termina por tablas")
	assert_eq(_session.winner_side, -1, "tablas: sin ganador")


func test_play_card_hechizo_dana_al_lado_opuesto() -> void:
	_setup_basico()
	_session.start()
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 6, SpellEffect.TargetType.ENEMY_HERO)
	_session.decks[0]._hand.append(spell)
	var ok := _session.play_card(spell)
	assert_true(ok, "el hechizo se juega")
	assert_eq(_session.heroes[1].current_health, 24, "30 - 6 al héroe del lado opuesto")


func test_combatant_damaged_espejado_en_event_log() -> void:
	_setup_basico()
	_session.start()
	watch_signals(_session)
	_session.deal_damage_to_hero(1, 5)
	assert_signal_emitted(_session, "combatant_damaged")
	var dmg := _session.event_log.filter(
		func(e: CombatEvent) -> bool: return e.type == CombatEvent.EventType.COMBATANT_DAMAGED)
	assert_eq(dmg.size(), 1, "el daño al héroe queda espejado en el log")
	assert_eq(dmg[0].payload["side"], 1, "el payload guarda el lado dañado")
	assert_eq(dmg[0].payload["amount"], 5, "y la cantidad")


func test_combatant_healed_espejado_en_event_log() -> void:
	# #2: a hero heal emits combatant_healed AND enters the event_log with the actual
	# amount restored, so a log-only replay reproduces the heal.
	_setup_basico()
	_session.start()
	_session.heroes[1].take_damage(10)
	watch_signals(_session)
	_session.heal_hero(1, 4)
	assert_signal_emitted(_session, "combatant_healed")
	var heals := _session.event_log.filter(
		func(e: CombatEvent) -> bool: return e.type == CombatEvent.EventType.COMBATANT_HEALED)
	assert_eq(heals.size(), 1, "la cura del héroe queda espejada en el log")
	assert_eq(heals[0].payload["side"], 1, "el payload guarda el lado curado")
	assert_eq(heals[0].payload["amount"], 4, "y la cantidad realmente curada")


func test_heal_hero_no_emite_si_esta_a_tope() -> void:
	# #2: healing a full-health hero restores nothing, so no event/signal is fired.
	_setup_basico()
	_session.start()
	watch_signals(_session)
	_session.heal_hero(1, 5)
	assert_signal_not_emitted(_session, "combatant_healed")
	var heals := _session.event_log.filter(
		func(e: CombatEvent) -> bool: return e.type == CombatEvent.EventType.COMBATANT_HEALED)
	assert_eq(heals.size(), 0, "curar a tope no deja evento")


func test_hechizo_player_hero_cura_al_lanzador() -> void:
	_setup_basico()
	_session.start()
	_session.heroes[1].take_damage(10)
	var heal := _spell(0, SpellEffect.EffectType.HEAL, 5, SpellEffect.TargetType.PLAYER_HERO)
	_session._apply_spell_effects(heal, 1)
	assert_eq(_session.heroes[1].current_health, 25, "PLAYER_HERO = héroe propio del lanzador (lado 1)")
	assert_eq(_session.heroes[0].current_health, 30, "el otro lado NO recibe daño")


func test_invocacion_lado_uno_owner_uno() -> void:
	_setup_basico()
	_session.start()
	var summon := _spell(0, SpellEffect.EffectType.SUMMON, 0, SpellEffect.TargetType.SUMMON_BOARD)
	summon.spell_effects[0].summon_name = "Eco"
	summon.spell_effects[0].summon_attack = 1
	summon.spell_effects[0].summon_health = 1
	summon.spell_effects[0].summon_count = 2
	_session._apply_spell_effects(summon, 1)
	var board := _session.decks[1].get_board()
	assert_eq(board.size(), 2, "dos criaturas invocadas al board del lado 1")
	assert_eq(board[0].owner_id, 1, "owner del lado 1, no 0")


func test_invocacion_emite_creature_summoned_y_lo_espeja_en_log() -> void:
	# #6: a spell summon emits creature_summoned AND enters the event_log, so a
	# log-only replay sees the creature appear (play_creature would emit CARD_PLAYED,
	# but spell summons bypass it).
	_setup_basico()
	_session.start()
	watch_signals(_session)
	var summon := _spell(0, SpellEffect.EffectType.SUMMON, 0, SpellEffect.TargetType.SUMMON_BOARD)
	summon.spell_effects[0].summon_name = "Eco"
	summon.spell_effects[0].summon_attack = 1
	summon.spell_effects[0].summon_health = 1
	summon.spell_effects[0].summon_count = 2
	_session._apply_spell_effects(summon, 1)
	assert_signal_emit_count(_session, "creature_summoned", 2, "una señal por criatura invocada")
	var summons := _session.event_log.filter(
		func(e: CombatEvent) -> bool: return e.type == CombatEvent.EventType.CREATURE_SUMMONED)
	assert_eq(summons.size(), 2, "ambas invocaciones quedan en el log")
	assert_eq(summons[0].payload["owner"], 1, "el payload guarda el lado invocador")


func test_invocacion_siembra_ability_fn_antes_del_setup() -> void:
	# Regresion: la criatura invocada hereda el ability_fn del lado y dispara
	# ON_SETUP con el handler ya sembrado (antes se re-sembraba tras setup()).
	var triggers: Array = []
	_session.ability_fn = func(_inst: CardInstance, trigger: int, _ctx: Dictionary) -> void:
		triggers.append(trigger)
	_session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	_session.start()
	var summon := _spell(0, SpellEffect.EffectType.SUMMON, 0, SpellEffect.TargetType.SUMMON_BOARD)
	summon.spell_effects[0].summon_name = "Eco"
	summon.spell_effects[0].summon_attack = 1
	summon.spell_effects[0].summon_health = 1
	summon.spell_effects[0].summon_count = 1
	_session._apply_spell_effects(summon, 0)
	var board := _session.decks[0].get_board()
	assert_eq(board.size(), 1, "la criatura se invoca al board del lanzador")
	assert_true(board[0].ability_fn.is_valid(), "hereda el ability_fn del lado")
	assert_true(triggers.has(CardInstance.Trigger.ON_SETUP), "ON_SETUP se dispara con el handler ya sembrado")


func test_auto_play_aplica_hechizo_del_lado_activo() -> void:
	_setup_basico()
	var ai := DummyAI.new()
	ai.setup(1)
	_session.ais[0] = ai
	_session.start()
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 7, SpellEffect.TargetType.ENEMY_HERO)
	_session.decks[0]._hand.append(spell)
	_session._auto_play_active()
	assert_eq(_session.heroes[1].current_health, 23, "el hechizo del lado activo surte efecto en auto-play")


func test_auto_play_targetea_hechizo_single_target_via_ai() -> void:
	# La IA elige el target de un hechizo PLAYER_CREATURE en auto-play; antes el
	# hechizo caia al push_warning por falta de target.
	_setup_basico()
	var ai := DummyAI.new()
	ai.setup(1)
	_session.ais[0] = ai
	_session.start()
	var ally := CardInstance.new()
	ally.setup(_creature(0, 2, 2), 0)
	_session.decks[0].add_to_board(ally)
	var buff := _spell(0, SpellEffect.EffectType.BUFF_ATTACK, 3, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.decks[0]._hand.append(buff)
	_session._auto_play_active()
	assert_eq(ally.current_attack, 5, "la IA targeteo la criatura viva y aplico el buff")


func test_auto_play_saltea_single_target_sin_criaturas() -> void:
	# Sin criaturas vivas la IA no puede targetear: el hechizo se saltea y NO se
	# consume (queda en mano), en vez de caer al guard de bajo nivel.
	_setup_basico()
	var ai := DummyAI.new()
	ai.setup(1)
	_session.ais[0] = ai
	_session.start()
	var buff := _spell(0, SpellEffect.EffectType.BUFF_ATTACK, 3, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.decks[0]._hand.append(buff)
	_session._auto_play_active()
	assert_true(_session.decks[0]._hand.has(buff), "el hechizo sin target posible queda en mano")


func test_declare_attacker_rechaza_doble_declaracion() -> void:
	# Regresion bug #1: declarar el mismo atacante dos veces no duplica el par.
	_setup_basico()
	_session.start()
	var inst := CardInstance.new()
	inst.setup(_creature(0, 2, 2), 0)
	inst.can_attack_this_turn = true
	_session.decks[0].add_to_board(inst)
	_session.declare_attacker(inst, null)
	_session.declare_attacker(inst, null)
	assert_eq(_session._attack_pairs[0].size(), 1, "la segunda declaracion se ignora")


func test_declare_attacker_rechaza_mareo_de_invocacion() -> void:
	# Regresion bug #1: una criatura que no puede atacar este turno se rechaza.
	_setup_basico()
	_session.start()
	var inst := CardInstance.new()
	inst.setup(_creature(0, 2, 2), 0)
	inst.can_attack_this_turn = false
	_session.decks[0].add_to_board(inst)
	_session.declare_attacker(inst, null)
	assert_eq(_session._attack_pairs[0].size(), 0, "sin can_attack no se declara")


func test_declare_blocker_redirige_dano_al_bloqueador() -> void:
	# Bloqueo bilateral: el lado pasivo (1) interpone un bloqueador a un ataque del
	# lado activo (0) dirigido al héroe; el daño se redirige al bloqueador.
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var atk := CardInstance.new()
	atk.setup(_creature(0, 3, 3), 0)
	atk.can_attack_this_turn = true
	_session.decks[0].add_to_board(atk)
	var blk := CardInstance.new()
	blk.setup(_creature(0, 1, 4), 1)
	_session.decks[1].add_to_board(blk)
	_session.declare_attacker(atk, null)
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.declare_blocker(atk, blk)
	_session.end_defense_phase()
	assert_eq(_session.heroes[1].current_health, 30, "el héroe pasivo no recibe daño: fue bloqueado")
	assert_eq(blk.current_health, 1, "el bloqueador recibe el ataque (4 - 3)")
	assert_eq(atk.current_health, 2, "el atacante recibe el golpe del bloqueador (3 - 1)")


func test_bloqueo_bilateral_el_lado_cero_tambien_bloquea() -> void:
	# La otra dirección: en el turno del lado 1, el lado 0 (ahora pasivo) bloquea.
	_session.setup(_hero(30), [_creature(9, 1, 1)], _hero(30), [_creature(9, 1, 1)], 1)
	_session.start()
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.end_defense_phase()
	assert_eq(_session.active_side, 1, "es el turno del lado 1")
	var atk := CardInstance.new()
	atk.setup(_creature(0, 3, 3), 1)
	atk.can_attack_this_turn = true
	_session.decks[1].add_to_board(atk)
	var blk := CardInstance.new()
	blk.setup(_creature(0, 0, 5), 0)
	_session.decks[0].add_to_board(blk)
	_session.declare_attacker(atk, null)
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.declare_blocker(atk, blk)
	_session.end_defense_phase()
	assert_eq(_session.heroes[0].current_health, 30, "el héroe del lado 0 no recibe daño: bloqueo")
	assert_eq(blk.current_health, 2, "el bloqueador del lado 0 recibe 3 (5 - 3)")


# Minimal AI subclass honoring the DummyAI contract; used to prove that
# setup() does not overwrite an AI injected by the game layer.
class _StubAI:
	extends DummyAI


# Spy AI that records whether auto_resolve routed the active turn through it.
class _SpyAI:
	extends DummyAI
	var chose_card: bool = false

	func choose_card_to_play(hand: Array[CardData], mana: int) -> CardData:
		chose_card = true
		return super.choose_card_to_play(hand, mana)


func test_auto_resolve_usa_ai_inyectada_por_lado() -> void:
	# La IA inyectada en ais[0] conduce el turno del lado 0.
	var spy := _SpyAI.new()
	spy.setup(7)
	_session.ais[0] = spy
	_session.setup(_hero(10), [_creature(1, 2, 2)], _hero(10), [_creature(1, 1, 2)], 7)
	_session.auto_resolve()
	assert_true(spy.chose_card, "auto_resolve usa la IA inyectada del lado 0")


func test_auto_resolve_sin_ai_es_determinista_por_seed() -> void:
	# Sin IA inyectada, auto_resolve sigue siendo determinista por seed.
	var first := CombatSession.new()
	first.setup(_hero(10), [_creature(1, 2, 2)], _hero(10), [_creature(1, 1, 2)], 7)
	first.auto_resolve()
	var second := CombatSession.new()
	second.setup(_hero(10), [_creature(1, 2, 2)], _hero(10), [_creature(1, 1, 2)], 7)
	second.auto_resolve()
	assert_eq(first.get_result(), second.get_result(), "mismo seed = mismo resultado")


func test_setup_siembra_dummy_ai_en_ambos_lados() -> void:
	# Sin inyeccion, setup() instancia el DummyAI de referencia por lado.
	_setup_basico()
	assert_true(_session.ais[0] is DummyAI, "lado 0 cae al DummyAI por defecto")
	assert_true(_session.ais[1] is DummyAI, "lado 1 cae al DummyAI por defecto")


func test_setup_respeta_ai_inyectada_por_lado() -> void:
	# Una IA asignada antes de setup() no debe ser pisada.
	var stub := _StubAI.new()
	_session.ais[1] = stub
	_setup_basico()
	assert_eq(_session.ais[1], stub, "setup conserva la IA inyectada del lado 1")


func test_setup_propaga_damage_fn_al_resolver() -> void:
	# El damage_fn opcional de la sesion se siembra en el resolver.
	_session.damage_fn = func(a: CardInstance, _d: CardInstance) -> int:
		return a.current_attack * 2
	_setup_basico()
	assert_true(_session._resolver.damage_fn.is_valid(), "el hook llega al resolver")


func test_setup_propaga_exhaust_fn_a_los_decks() -> void:
	# El exhaust_fn opcional de la sesion se siembra en ambos mazos.
	_session.exhaust_fn = func(_owner: int) -> void:
		pass
	_setup_basico()
	assert_true(_session.decks[0].exhaust_fn.is_valid(), "el hook llega al mazo del lado 0")
	assert_true(_session.decks[1].exhaust_fn.is_valid(), "el hook llega al mazo del lado 1")


func test_play_card_hechizo_usa_target_explicito_en_player_creature() -> void:
	# Un hechizo PLAYER_CREATURE aplica al target explicito provisto a play_card().
	_setup_basico()
	_session.start()
	var c0 := CardInstance.new()
	c0.setup(_creature(0, 1, 1), 0)
	var c1 := CardInstance.new()
	c1.setup(_creature(0, 1, 1), 0)
	_session.decks[0].add_to_board(c0)
	_session.decks[0].add_to_board(c1)
	var spell := _spell(0, SpellEffect.EffectType.BUFF_ATTACK, 2, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.decks[0]._hand.append(spell)
	var ok := _session.play_card(spell, false, 0, 0, c1)
	assert_true(ok, "el hechizo se juega")
	assert_eq(c1.current_attack, 3, "el buff va al target explicito (1 + 2)")
	assert_eq(c0.current_attack, 1, "la otra criatura no se toca")


func test_play_card_hechizo_player_creature_sin_target_fizzle() -> void:
	# FIX 4.2 (breaking): sin target valido, un hechizo PLAYER_CREATURE hace fizzle:
	# NO se consume (mana y carta intactos), emite spell_fizzled y play_card da false.
	_setup_basico()
	_session.start()
	var c0 := CardInstance.new()
	c0.setup(_creature(0, 1, 1), 0)
	_session.decks[0].add_to_board(c0)
	var spell := _spell(1, SpellEffect.EffectType.BUFF_ATTACK, 2, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.decks[0]._hand.append(spell)
	var mana_antes: int = _session.decks[0].mana
	watch_signals(_session)
	var ok := _session.play_card(spell)
	assert_false(ok, "play_card devuelve false: el hechizo no se jugo")
	assert_signal_emitted(_session, "spell_fizzled")
	assert_eq(_session.decks[0].mana, mana_antes, "el mana NO se consume")
	assert_true(spell in _session.decks[0]._hand, "la carta sigue en la mano")
	assert_eq(c0.current_attack, 1, "ninguna criatura recibe el buff (sin fallback a board[0])")
	var fizzles := _session.event_log.filter(
		func(e: CombatEvent) -> bool: return e.type == CombatEvent.EventType.SPELL_FIZZLED)
	assert_eq(fizzles.size(), 1, "el fizzle queda espejado en el event_log")


func test_play_spell_aplica_effect_a_target_explicito() -> void:
	# play_spell aplica el effect pasado al target explicito, sin usar los
	# spell_effects propios de la carta.
	_setup_basico()
	_session.start()
	_session.heroes[1].take_damage(10)
	var card := _spell(0, SpellEffect.EffectType.HEAL, 1, SpellEffect.TargetType.PLAYER_HERO)
	_session.decks[0]._hand.append(card)
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.HEAL
	effect.value = 5
	var ok := _session.play_spell(card, effect, _session.heroes[1])
	assert_true(ok, "el hechizo manual se juega")
	assert_eq(_session.heroes[1].current_health, 25, "cura 5 al target explicito (20 -> 25)")


func test_play_spell_letal_barre_la_muerte() -> void:
	# Regression: an ad-hoc play_spell that kills a creature must surface the death
	# like the play_card path — creature_died, get_dead_creatures, off the board and
	# CREATURE_DIED in the event_log — instead of leaving a zombie behind.
	_setup_basico()
	_session.start()
	var victima := _live_instance(1, 0, 1)
	_session.decks[1].add_to_board(victima)
	var card := _spell(0, SpellEffect.EffectType.DAMAGE, 5, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.decks[0]._hand.append(card)
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.value = 5
	effect.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	var deaths: Array = []
	_session.creature_died.connect(func(_c: CardInstance, owner: int) -> void: deaths.append(owner))
	var ok := _session.play_spell(card, effect, victima)
	assert_true(ok, "el hechizo manual se juega")
	assert_true(victima.is_dead, "la víctima muere por el efecto ad-hoc")
	assert_eq(deaths.size(), 1, "emite creature_died exactamente una vez")
	assert_true(_session.get_dead_creatures(1).has(victima), "queda rastreada en get_dead_creatures")
	assert_false(_session.decks[1].get_board().has(victima), "sale del tablero")
	assert_true(_logged_types(_session).has(CombatEvent.EventType.CREATURE_DIED), "CREATURE_DIED entra al event_log")


func test_play_spell_single_target_sin_target_hace_fizzle() -> void:
	# play_spell ad-hoc honra el mismo contrato de fizzle que play_card: un effect
	# PLAYER_CREATURE sin target vivo no consume la carta ni el maná.
	_setup_basico()
	_session.start()
	var card := _spell(1, SpellEffect.EffectType.DAMAGE, 2, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.decks[0]._hand.append(card)
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.value = 2
	effect.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	var mana_antes: int = _session.decks[0].mana
	watch_signals(_session)
	var ok := _session.play_spell(card, effect, null)
	assert_false(ok, "play_spell devuelve false sin target válido")
	assert_signal_emitted(_session, "spell_fizzled")
	assert_eq(_session.decks[0].mana, mana_antes, "el maná NO se consume")
	assert_true(card in _session.decks[0]._hand, "la carta sigue en la mano")


func test_check_victory_tolera_heroe_nulo() -> void:
	# Regression A1: a side may have a null hero (board-only / headless scenarios);
	# _check_victory must guard it like _resolve_winner instead of crashing.
	_setup_basico()
	_session.heroes[1] = null
	_session.auto_resolve()
	assert_eq(_session.phase, CombatState.Phase.END, "el combate cierra sin crashear con un héroe nulo")
	assert_eq(_session.winner_side, -1, "sin héroe válido no se declara ganador")


func test_effect_fn_letal_sobre_aliados_reporta_muerte() -> void:
	# Regression A3: a custom effect_fn over PLAYER_CREATURES that kills an ally must
	# surface the death (creature_died / event_log / get_dead_creatures) and clear
	# the board, just like ENEMY_CREATURES does.
	_setup_basico()
	var aliado := _live_instance(0, 1, 1)
	_session.decks[0].add_to_board(aliado)
	var deaths: Array = []
	_session.creature_died.connect(func(_card: CardInstance, owner: int) -> void: deaths.append(owner))
	var lethal := SpellEffect.new()
	lethal.target_type = SpellEffect.TargetType.PLAYER_CREATURES
	lethal.effect_fn = func(_e: SpellEffect, target: Variant, _ctx: Dictionary) -> Dictionary:
		for inst in target:
			inst.take_damage(99)
		return {"success": true}
	_session._apply_single_spell_effect(lethal, 0)
	assert_true(aliado.is_dead, "el effect_fn mata al aliado")
	assert_eq(deaths.size(), 1, "emite creature_died exactamente una vez")
	assert_eq(deaths[0], 0, "el owner reportado es el lado 0")
	assert_true(_session.get_dead_creatures(0).has(aliado), "queda rastreada en get_dead_creatures")
	assert_false(_session.decks[0].get_board().has(aliado), "sale del tablero")


func test_event_log_incluye_eventos_de_carta() -> void:
	# D: the session event_log mirrors deck-level events (draw/play/mana) so the log
	# alone is a full replay stream, not just session-level events.
	var hero_cards: Array[CardData] = [_creature(1, 2, 2)]
	_session.setup(_hero(10), hero_cards, _hero(10), _empty(), 7)
	_session.auto_resolve()
	var types := _logged_types(_session)
	assert_true(types.has(CombatEvent.EventType.CARD_DRAWN), "el log incluye robos de carta")
	assert_true(types.has(CombatEvent.EventType.MANA_CHANGED), "el log incluye cambios de maná")
	assert_true(types.has(CombatEvent.EventType.CARD_PLAYED), "el log incluye criaturas jugadas")
	assert_true(types.has(CombatEvent.EventType.MAX_MANA_CHANGED), "el log incluye la rampa del maná máximo")


func test_event_log_con_cartas_serializa_round_trip() -> void:
	# Card-level payloads carry only primitives, so the whole stream round-trips.
	_session.setup(_hero(10), [_creature(1, 2, 2)], _hero(10), _empty(), 7)
	_session.auto_resolve()
	for ev in _session.event_log:
		var data := ev.serialize()
		assert_true(data.has("type") and data.has("payload"), "cada evento serializa type+payload")


func test_damage_hero_tolera_heroe_nulo() -> void:
	# Regression: _damage_hero must guard a null hero like _check_victory does, so a
	# board-only scenario (no hero) survives a direct attack / ENEMY_HERO spell.
	_setup_basico()
	_session.heroes[0] = null
	_session.deal_damage_to_hero(0, 5)
	assert_eq(_session.heroes[0], null, "no crashea ni materializa un héroe al dañar un lado sin héroe")


# --- Trigger contract (A2): session-level triggers ----------------------------

func _collect_triggers(target_trigger: int) -> Array:
	## Helper: attach a handler that records {inst, ctx} for one trigger type.
	var hits: Array = []
	_session.ability_fn = func(inst: CardInstance, trigger: int, ctx: Dictionary) -> void:
		if trigger == target_trigger:
			hits.append({"inst": inst, "ctx": ctx})
	return hits


func test_declare_attacker_dispara_on_attack_con_target() -> void:
	var hits := _collect_triggers(CardInstance.Trigger.ON_ATTACK)
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var atk := CardInstance.with_hooks(_session.ability_fn, -1)
	atk.setup(_creature(0, 3, 3), 0)
	atk.can_attack_this_turn = true
	_session.decks[0].add_to_board(atk)
	_session.declare_attacker(atk, null)
	assert_eq(hits.size(), 1, "ON_ATTACK se dispara al declarar")
	assert_eq(hits[0]["ctx"].get("target"), null, "ataque a la cara: target null en el context")


func test_declare_blocker_dispara_on_block_con_atacante() -> void:
	var hits := _collect_triggers(CardInstance.Trigger.ON_BLOCK)
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var atk := CardInstance.new()
	atk.setup(_creature(0, 3, 3), 0)
	atk.can_attack_this_turn = true
	_session.decks[0].add_to_board(atk)
	var blk := CardInstance.with_hooks(_session.ability_fn, -1)
	blk.setup(_creature(0, 1, 4), 1)
	_session.decks[1].add_to_board(blk)
	_session.declare_attacker(atk, null)
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.declare_blocker(atk, blk)
	assert_eq(hits.size(), 1, "ON_BLOCK se dispara al asignar el bloqueador")
	assert_eq(hits[0]["ctx"].get("attacker"), atk, "el context lleva el atacante interceptado")


func test_resolucion_dispara_on_damage_dealt_a_ambos() -> void:
	var hits := _collect_triggers(CardInstance.Trigger.ON_DAMAGE_DEALT)
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var atk := CardInstance.with_hooks(_session.ability_fn, -1)
	atk.setup(_creature(0, 3, 5), 0)
	atk.can_attack_this_turn = true
	_session.decks[0].add_to_board(atk)
	var blk := CardInstance.with_hooks(_session.ability_fn, -1)
	blk.setup(_creature(0, 2, 5), 1)
	_session.decks[1].add_to_board(blk)
	_session.declare_attacker(atk, blk)
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.end_defense_phase()  # -> RESOLVE
	assert_eq(hits.size(), 2, "ambos infligen daño en el trade")
	var amounts: Array = [hits[0]["ctx"]["amount"], hits[1]["ctx"]["amount"]]
	assert_true(amounts.has(3) and amounts.has(2), "el daño infligido por cada uno entra al context")


func test_on_turn_start_y_end_disparan_en_criaturas_del_lado_activo() -> void:
	var starts: Array = []
	var ends: Array = []
	_session.ability_fn = func(_i: CardInstance, trigger: int, _c: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_TURN_START:
			starts.append(true)
		elif trigger == CardInstance.Trigger.ON_TURN_END:
			ends.append(true)
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var c := CardInstance.with_hooks(_session.ability_fn, -1)
	c.setup(_creature(0, 1, 5), 0)
	_session.decks[0].add_to_board(c)
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.end_defense_phase()  # RESOLVE -> ON_TURN_END del lado 0, swap a lado 1
	assert_eq(ends.size(), 1, "ON_TURN_END se dispara para la criatura del lado activo antes del swap")


func test_on_draw_dispara_con_inst_nulo_y_carta_en_context() -> void:
	var drawn: Array = []
	_session.ability_fn = func(inst: CardInstance, trigger: int, ctx: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_DRAW:
			drawn.append({"inst_null": inst == null, "card": ctx.get("card"), "owner": ctx.get("owner")})
	# A non-empty deck so PREPARATION draws a card.
	_session.setup(_hero(30), [_creature(1, 1, 1), _creature(1, 1, 1)], _hero(30), _empty(), 1)
	_session.start()  # PREPARATION draws for side 0
	assert_gt(drawn.size(), 0, "ON_DRAW se dispara al robar")
	assert_true(drawn[0]["inst_null"], "inst es null en ON_DRAW (la carta aún es CardData)")
	assert_true(drawn[0]["card"] is CardData, "la carta robada viaja en el context")
	assert_eq(drawn[0]["owner"], 0, "el owner del robo entra al context")


# --- effect_fn uniforme + API público de héroe (B) ----------------------------

func test_effect_fn_se_respeta_para_enemy_hero() -> void:
	# Regression B: ENEMY_HERO used to bypass effect.apply, so a custom effect_fn was
	# ignored for heroes. Now it runs and can hit the hero via context.session.
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var seen_ctx: Dictionary = {}
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 7, SpellEffect.TargetType.ENEMY_HERO)
	spell.spell_effects[0].effect_fn = func(_e: SpellEffect, _t: Variant, ctx: Dictionary) -> Dictionary:
		seen_ctx.merge(ctx, true)  # mutate (by-ref); reassigning a captured var doesn't propagate
		ctx["session"].deal_damage_to_hero(1 - int(ctx["owner_id"]), 9)
		return {"success": true}
	_session._apply_spell_effects(spell, 0)
	assert_eq(_session.heroes[1].current_health, 21, "el effect_fn dañó al héroe enemigo (30 - 9)")
	assert_true(seen_ctx.has("session") and seen_ctx.has("owner_id"), "el context lleva session y owner_id")


func test_effect_fn_a_heroe_entra_al_event_log() -> void:
	# Hero damage routed through the public API must still mirror into the event_log.
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 0, SpellEffect.TargetType.ENEMY_HERO)
	spell.spell_effects[0].effect_fn = func(_e: SpellEffect, _t: Variant, ctx: Dictionary) -> Dictionary:
		ctx["session"].deal_damage_to_hero(1, 4)
		return {"success": true}
	_session._apply_spell_effects(spell, 0)
	var dmg := _session.event_log.filter(
		func(e: CombatEvent) -> bool: return e.type == CombatEvent.EventType.COMBATANT_DAMAGED)
	assert_eq(dmg.size(), 1, "el daño a héroe vía effect_fn entra al event_log")


func test_context_unificado_llega_a_efectos_de_criatura() -> void:
	# The creature-target paths used to pass {}; now they carry session/owner_id too.
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var ally := CardInstance.new()
	ally.setup(_creature(0, 2, 5), 0)
	_session.decks[0].add_to_board(ally)
	var seen: Dictionary = {}
	var spell := _spell(0, SpellEffect.EffectType.BUFF_ATTACK, 1, SpellEffect.TargetType.PLAYER_CREATURES)
	spell.spell_effects[0].effect_fn = func(_e: SpellEffect, _t: Variant, ctx: Dictionary) -> Dictionary:
		seen.merge(ctx, true)  # mutate (by-ref); reassigning a captured var doesn't propagate
		return {"success": true}
	_session._apply_spell_effects(spell, 0)
	assert_eq(seen.get("owner_id"), 0, "owner_id del lanzador en el context")
	assert_true(seen.get("session") == _session, "la sesión viaja en el context")


# --- Chunk 0: N-side topology (setup_sides + teams + helpers) -----------------

func test_setup_legacy_es_equivalente_a_dos_lados_team_propio() -> void:
	_session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	assert_eq(_session.side_count(), 2, "el setup 1v1 deja dos lados")
	assert_eq(_session.teams, [0, 1] as Array[int], "cada lado es su propio equipo")
	assert_eq(_session.enemies_of(0), [1] as Array[int], "el enemigo del lado 0 es el 1")


func test_setup_sides_dimensiona_los_arrays_para_n_lados() -> void:
	_session.setup_sides([
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
	], [], 1)
	assert_eq(_session.side_count(), 3, "tres lados configurados")
	assert_eq(_session.heroes.size(), 3, "heroes dimensionado a 3")
	assert_eq(_session.decks.size(), 3, "decks dimensionado a 3")
	assert_eq(_session.ais.size(), 3, "ais dimensionado a 3")
	assert_eq(_session._attack_pairs.size(), 3, "_attack_pairs dimensionado a 3")
	assert_eq(_session.teams, [0, 1, 2] as Array[int], "FFA por defecto: cada lado su equipo")


func test_allies_of_incluye_al_propio_lado_y_al_companero_en_2v2() -> void:
	_session.setup_sides([
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
	], [0, 0, 1, 1], 1)
	assert_eq(_session.allies_of(0), [0, 1] as Array[int], "aliados incluyen al propio lado y al compañero")
	assert_eq(_session.enemies_of(0), [2, 3] as Array[int], "enemigos: los dos lados del otro equipo")
	assert_eq(_session.passive_sides(), [1, 2, 3] as Array[int], "pasivos: todos menos el activo")


func test_enemy_y_ally_boards_concatenan_por_equipo() -> void:
	_session.setup_sides([
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
	], [0, 0, 1, 1], 1)
	var ally_creature := CardInstance.new()
	ally_creature.setup(_creature(0, 1, 1), 1)
	_session.decks[1].add_to_board(ally_creature)
	var enemy_a := CardInstance.new()
	enemy_a.setup(_creature(0, 1, 1), 2)
	_session.decks[2].add_to_board(enemy_a)
	var enemy_b := CardInstance.new()
	enemy_b.setup(_creature(0, 1, 1), 3)
	_session.decks[3].add_to_board(enemy_b)
	assert_eq(_session.ally_boards(0), [ally_creature] as Array[CardInstance], "ally_boards toma el tablero del compañero")
	assert_eq(_session.enemy_boards(0).size(), 2, "enemy_boards concatena los dos tableros rivales")


# --- Chunk 1: spell targeting resolved by teams -------------------------------

func _put_creature(side: int, attack: int, health: int) -> CardInstance:
	var inst := CardInstance.new()
	inst.setup(_creature(0, attack, health), side)
	_session.decks[side].add_to_board(inst)
	return inst


func test_enemy_hero_default_golpea_al_primer_enemigo_vivo_en_ffa() -> void:
	# #1: an ENEMY_HERO spell with no target_side (-1) hits the first living enemy
	# side, not `1 - side` (which in FFA could be an ally or a wrong side).
	_session.setup_sides([
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
	], [], 1)
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 6, SpellEffect.TargetType.ENEMY_HERO)
	_session._apply_spell_effects(spell, 0)
	assert_eq(_session.heroes[1].current_health, 14, "el default pega al primer enemigo vivo (lado 1)")
	assert_eq(_session.heroes[2].current_health, 20, "no toca a los demás")


func test_enemy_hero_target_side_explicito_elige_al_rival_en_ffa() -> void:
	# #1: an explicit target_side directs the ENEMY_HERO spell to that enemy hero.
	_session.setup_sides([
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
	], [], 1)
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 6, SpellEffect.TargetType.ENEMY_HERO)
	_session._apply_spell_effects(spell, 0, null, 2)
	assert_eq(_session.heroes[2].current_health, 14, "target_side=2 dirige el golpe al lado 2")
	assert_eq(_session.heroes[1].current_health, 20, "el lado 1 queda intacto")


func test_enemy_hero_target_side_aliado_cae_al_default() -> void:
	# #1: a target_side pointing at an ALLY is invalid, so it falls back to the first
	# living enemy — a spell can never hit a teammate's hero via ENEMY_HERO.
	_session.setup_sides([
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
	], [0, 0, 1, 1], 1)
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 6, SpellEffect.TargetType.ENEMY_HERO)
	_session._apply_spell_effects(spell, 0, null, 1)  # lado 1 es aliado de 0
	assert_eq(_session.heroes[1].current_health, 20, "el aliado nunca recibe el golpe enemigo")
	assert_eq(_session.heroes[2].current_health, 14, "cae al primer enemigo vivo (lado 2)")


func test_play_card_enemy_hero_pasa_target_side() -> void:
	# #1 (public path): play_card forwards target_side to the ENEMY_HERO resolution.
	_session.setup_sides([
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
		{"hero": _hero(20), "cards": _empty()},
	], [], 5)
	_session.start()
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 5, SpellEffect.TargetType.ENEMY_HERO)
	_session.decks[0]._hand.append(spell)
	assert_true(_session.play_card(spell, false, 0, 0, null, 2), "play_card aplica el hechizo")
	assert_eq(_session.heroes[2].current_health, 15, "play_card dirigió el golpe al lado 2")


func test_aoe_enemigo_golpea_a_todos_los_rivales_en_ffa() -> void:
	_session.setup_sides([
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
	], [], 1)
	var own := _put_creature(0, 1, 5)
	var rival_a := _put_creature(1, 1, 5)
	var rival_b := _put_creature(2, 1, 5)
	var spell := _spell(0, SpellEffect.EffectType.AOE_DAMAGE, 2, SpellEffect.TargetType.ENEMY_CREATURES)
	_session._apply_spell_effects(spell, 0)
	assert_eq(rival_a.current_health, 3, "el AoE golpea al primer rival")
	assert_eq(rival_b.current_health, 3, "el AoE golpea al segundo rival")
	assert_eq(own.current_health, 5, "el AoE no toca a la propia criatura")


func test_aoe_enemigo_respeta_equipos_en_2v2() -> void:
	_session.setup_sides([
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
	], [0, 0, 1, 1], 1)
	var teammate := _put_creature(1, 1, 5)
	var enemy_a := _put_creature(2, 1, 5)
	var enemy_b := _put_creature(3, 1, 5)
	var spell := _spell(0, SpellEffect.EffectType.AOE_DAMAGE, 2, SpellEffect.TargetType.ENEMY_CREATURES)
	_session._apply_spell_effects(spell, 0)
	assert_eq(teammate.current_health, 5, "el AoE no daña al compañero de equipo")
	assert_eq(enemy_a.current_health, 3, "el AoE daña al primer enemigo")
	assert_eq(enemy_b.current_health, 3, "el AoE daña al segundo enemigo")


func test_buff_aliado_alcanza_al_companiero_en_2v2() -> void:
	_session.setup_sides([
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
		{"hero": _hero(), "cards": _empty()},
	], [0, 0, 1, 1], 1)
	var own := _put_creature(0, 2, 2)
	var teammate := _put_creature(1, 2, 2)
	var enemy := _put_creature(2, 2, 2)
	var spell := _spell(0, SpellEffect.EffectType.BUFF_ATTACK, 1, SpellEffect.TargetType.PLAYER_CREATURES)
	_session._apply_spell_effects(spell, 0)
	assert_eq(own.current_attack, 3, "el buff alcanza a la propia criatura")
	assert_eq(teammate.current_attack, 3, "el buff alcanza al compañero de equipo (D1)")
	assert_eq(enemy.current_attack, 2, "el buff no toca al enemigo")


# --- Chunk 2: N-side FSM (rotation, team victory, directed/blocked combat) -----

func _four_sides_2v2() -> void:
	_session.setup_sides([
		{"hero": _hero(30), "cards": _starter()},
		{"hero": _hero(30), "cards": _starter()},
		{"hero": _hero(30), "cards": _starter()},
		{"hero": _hero(30), "cards": _starter()},
	], [0, 0, 1, 1], 1)


func test_turn_order_intercala_equipos_en_2v2() -> void:
	_four_sides_2v2()
	assert_eq(_session._turn_order, [0, 2, 1, 3] as Array[int], "round-robin entre equipos: A1,B1,A2,B2")


func test_next_living_side_alterna_de_equipo() -> void:
	_four_sides_2v2()
	_session.active_side = 0
	assert_eq(_session._next_living_side(), 2, "tras el lado 0 (eq.0) juega el 2 (eq.1)")
	_session.active_side = 2
	assert_eq(_session._next_living_side(), 1, "tras el lado 2 (eq.1) juega el 1 (eq.0)")


func test_next_living_side_saltea_lado_muerto() -> void:
	_session.setup_sides([
		{"hero": _hero(30), "cards": _starter()},
		{"hero": _hero(30), "cards": _starter()},
		{"hero": _hero(30), "cards": _starter()},
	], [], 1)
	_session.heroes[1].take_damage(30)
	_session.active_side = 0
	assert_eq(_session._next_living_side(), 2, "el lado con héroe muerto se saltea")


func test_gana_el_ultimo_equipo_en_pie_en_2v2() -> void:
	_four_sides_2v2()
	_session.heroes[2].take_damage(30)
	_session.heroes[3].take_damage(30)
	_session._check_victory()
	assert_eq(_session.phase, CombatState.Phase.END, "muerto todo un equipo, el combate termina")
	assert_eq(_session.winner_team, 0, "gana el equipo 0")
	assert_eq(_session.winner_side, 0, "winner_side reporta un lado vivo del equipo ganador")


func test_combate_sigue_si_queda_un_lado_del_equipo_enemigo() -> void:
	_four_sides_2v2()
	_session.heroes[2].take_damage(30)  # cae solo un lado del equipo 1
	assert_eq(_session._living_teams().size(), 2, "siguen vivos los dos equipos")
	_session._check_victory()
	assert_ne(_session.phase, CombatState.Phase.END, "el combate continúa mientras el rival tenga un lado")


func test_ataque_a_heroe_dirigido_a_un_enemigo_concreto() -> void:
	_session.setup_sides([
		{"hero": _hero(30), "cards": _starter()},
		{"hero": _hero(30), "cards": _starter()},
		{"hero": _hero(30), "cards": _starter()},
	], [], 1)
	var atk := _put_creature(0, 5, 5)
	_session.start()  # MAIN, lado 0 (refresh habilita la criatura)
	_session.declare_attacker(atk, null, 2)
	_session.end_main_phase()
	_session.end_attack_phase()
	_session.end_defense_phase()  # RESOLVE
	assert_eq(_session.heroes[2].current_health, 25, "el héroe del lado objetivo recibe el daño")
	assert_eq(_session.heroes[1].current_health, 30, "el otro enemigo no recibe daño")


func test_bloqueador_de_cualquier_lado_enemigo_redirige_el_dano() -> void:
	_four_sides_2v2()
	var atk := _put_creature(0, 4, 4)
	var blk := _put_creature(3, 1, 10)  # compañero (eq.1) del lado atacado (lado 2)
	_session.start()  # MAIN, lado 0
	_session.declare_attacker(atk, null, 2)
	_session.end_main_phase()
	_session.end_attack_phase()  # DEFENSE
	_session.declare_blocker(atk, blk)
	_session.end_defense_phase()  # RESOLVE
	assert_eq(_session.heroes[2].current_health, 30, "el ataque fue bloqueado, el héroe no recibe daño")
	assert_eq(blk.current_health, 6, "el bloqueador del lado aliado del objetivo recibe el daño")


# --- Chunk 3: AI contract (enemy arrays) + multi-side auto_resolve ------------

func _2v2_sides() -> Array:
	return [
		{"hero": _hero(20), "cards": _starter()},
		{"hero": _hero(20), "cards": _starter()},
		{"hero": _hero(20), "cards": _starter()},
		{"hero": _hero(20), "cards": _starter()},
	]


func test_auto_resolve_ffa_de_tres_lados_llega_a_end() -> void:
	_session.setup_sides([
		{"hero": _hero(3), "cards": _starter()},
		{"hero": _hero(3), "cards": _starter()},
		{"hero": _hero(3), "cards": _starter()},
	], [], 5)
	_session.auto_resolve()
	assert_eq(_session.phase, CombatState.Phase.END, "el FFA headless llega a END")
	assert_between(_session.winner_team, -1, 2, "winner_team es un equipo válido o -1")


func test_auto_resolve_2v2_es_determinista_con_seed() -> void:
	var a := CombatSession.new()
	a.setup_sides(_2v2_sides(), [0, 0, 1, 1], 11)
	a.auto_resolve()
	var b := CombatSession.new()
	b.setup_sides(_2v2_sides(), [0, 0, 1, 1], 11)
	b.auto_resolve()
	assert_eq(a.winner_team, b.winner_team, "mismo seed -> mismo equipo ganador")
	assert_eq(a.turn_number, b.turn_number, "mismo seed -> misma duración")
