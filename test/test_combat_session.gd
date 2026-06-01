extends GutTest
## Caracterizacion de CombatSession: FSM, rampa de mana, auto_resolve, regresiones
## de hechizos y validacion de declaracion de ataque.


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


func _run_seeded(combat_seed: int, player_seed: int) -> Dictionary:
	var session := CombatSession.new()
	var player_ai := DummyAI.new()
	player_ai.setup(player_seed)
	session.setup(_hero(), _starter(), _hero(), _starter(), combat_seed)
	session.auto_resolve(player_ai)
	return session.get_result()


func test_mismo_seed_reproduce_la_partida() -> void:
	# Replay guarantee: same combat seed (seeds both deck shuffles + enemy AI)
	# plus same player AI seed and starting cards => identical match.
	var first := _run_seeded(7, 3)
	var second := _run_seeded(7, 3)
	assert_gt(first["turn_number"], 1, "la partida realmente avanzó turnos")
	assert_eq(first, second, "mismo seed reproduce el resultado del combate")


func test_start_va_a_principal_en_turno_uno() -> void:
	_setup_basico()
	_session.start()
	assert_eq(_session.phase, CombatState.Phase.PRINCIPAL, "tras start queda en PRINCIPAL")
	assert_eq(_session.turn_number, 1, "primer turno")


func _serialized_log(session: CombatSession) -> Array:
	var out: Array = []
	for ev in session.event_log:
		out.append(ev.serialize())
	return out


func test_event_log_registra_el_combate() -> void:
	var hero_cards: Array[CardData] = [_creature(1, 2, 2)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(10), hero_cards, _hero(10), enemy_cards, 7)
	_session.auto_resolve(null, 7)
	assert_gt(_session.event_log.size(), 0, "el combate deja eventos en el log")
	var last: CombatEvent = _session.event_log[-1]
	assert_eq(last.type, CombatEvent.EventType.COMBAT_ENDED, "el último evento es el fin del combate")


func test_event_log_es_determinista_por_seed() -> void:
	# Same seeds => identical serialized event stream (replay-friendly).
	var first := CombatSession.new()
	first.setup(_hero(10), _starter(), _hero(10), _starter(), 11)
	first.auto_resolve(null, 5)
	var second := CombatSession.new()
	second.setup(_hero(10), _starter(), _hero(10), _starter(), 11)
	second.auto_resolve(null, 5)
	assert_eq(_serialized_log(first), _serialized_log(second), "mismo seed reproduce el log de eventos")


func test_event_log_se_limpia_en_setup() -> void:
	_setup_basico()
	_session.auto_resolve(null, 7)
	assert_gt(_session.event_log.size(), 0, "hay eventos tras un combate")
	_session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	assert_eq(_session.event_log.size(), 0, "setup limpia el log para reutilizar la sesión")


func test_advance_desde_inicio_arranca_el_combate() -> void:
	# advance() keeps INICIO actionable after dropping the dead RESOLVER/FINAL arms.
	_setup_basico()
	assert_eq(_session.phase, CombatState.Phase.INICIO, "arranca en INICIO")
	_session.advance()
	assert_eq(_session.phase, CombatState.Phase.PRINCIPAL, "advance desde INICIO encadena hasta PRINCIPAL")


func _dead_instance(owner: int) -> CardInstance:
	var inst := CardInstance.new()
	inst.setup(_creature(1, 1, 1), owner)
	inst.is_dead = true
	return inst


func test_get_dead_creatures_rastrea_cada_lado() -> void:
	_setup_basico()
	var dead_enemy := _dead_instance(1)
	var dead_player := _dead_instance(0)
	var pairs: Array = [{
		"attacker": dead_player,
		"defender": dead_enemy,
		"attacker_died": true,
		"defender_died": true,
	}]
	_session._process_death_results(pairs)
	var enemy_dead := _session.get_dead_enemy_creatures()
	var player_dead := _session.get_dead_player_creatures()
	assert_eq(enemy_dead.size(), 1, "la criatura enemiga muerta se rastrea")
	assert_true(enemy_dead.has(dead_enemy), "es la instancia enemiga correcta")
	assert_eq(player_dead.size(), 1, "la criatura del jugador sigue rastreándose")
	assert_true(player_dead.has(dead_player), "es la instancia del jugador correcta")


func test_get_dead_enemy_creatures_vacio_sin_combate() -> void:
	assert_eq(_session.get_dead_enemy_creatures(), [], "sin enemy_deck devuelve vacío")


func test_emite_phase_changed_al_iniciar() -> void:
	_setup_basico()
	watch_signals(_session)
	_session.start()
	assert_signal_emitted(_session, "phase_changed")


func test_rampa_de_mana_primer_turno() -> void:
	_setup_basico()
	_session.start()
	assert_eq(_session.player_deck.mana, 2, "gana mana hasta su max inicial (2)")
	assert_eq(_session.player_deck.max_mana, 4, "el max sube por la rampa (2 -> 4)")


func test_rampa_de_mana_es_simetrica_para_ambos_lados() -> void:
	# _ramp_mana_for applies the same rule to both decks.
	_setup_basico()
	_session.start()
	assert_eq(_session.enemy_deck.mana, _session.player_deck.mana, "ambos lados ganan el mismo maná")
	assert_eq(_session.enemy_deck.max_mana, _session.player_deck.max_mana, "ambos lados rampean igual el max")


func test_auto_resolve_termina_en_final() -> void:
	var hero_cards: Array[CardData] = [_creature(1, 2, 2), _creature(1, 1, 3)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(10), hero_cards, _hero(10), enemy_cards, 7)
	_session.auto_resolve(null, 7)
	assert_eq(_session.phase, CombatState.Phase.FINAL, "auto_resolve llega a FINAL sin colgarse")


func test_auto_resolve_corta_al_agotar_iteraciones() -> void:
	# With a tiny cap the loop exits in ATAQUE, before any damage resolves: the
	# guard must force FINAL even though nobody won, lost, or stalemated.
	var hero_cards: Array[CardData] = [_creature(1, 2, 2)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(30), hero_cards, _hero(30), enemy_cards, 7)
	_session._auto_resolve_max_iterations = 1
	_session.auto_resolve(null, 7)
	assert_eq(_session.phase, CombatState.Phase.FINAL, "el guard fuerza FINAL al agotar iteraciones")
	assert_gt(_session.enemy.current_health, 0, "no terminó por victoria (corte forzado)")
	assert_gt(_session.player_hero.current_health, 0, "no terminó por derrota (corte forzado)")
	assert_lt(_session.turn_number, _session.config.stalemate_turn_limit, "tampoco es tablas")


func test_get_result_tiene_claves_esperadas() -> void:
	_setup_basico()
	_session.start()
	var result := _session.get_result()
	assert_has(result, "player_won")
	assert_has(result, "turn_number")
	assert_has(result, "hero_hp")
	assert_has(result, "enemy_hp")


func test_play_card_hechizo_dana_al_enemigo() -> void:
	_setup_basico()
	_session.start()
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 6, SpellEffect.TargetType.ENEMY_HERO)
	_session.player_deck._hand.append(spell)
	var ok := _session.play_card(spell)
	assert_true(ok, "el hechizo se juega")
	assert_eq(_session.enemy.current_health, 24, "30 - 6 al heroe enemigo")


func test_hechizo_enemigo_player_hero_cura_al_enemigo() -> void:
	_setup_basico()
	_session.start()
	_session.enemy.take_damage(10)
	var heal := _spell(0, SpellEffect.EffectType.HEAL, 5, SpellEffect.TargetType.PLAYER_HERO)
	_session._apply_spell_effects(heal, 1)
	assert_eq(_session.enemy.current_health, 25, "PLAYER_HERO = heroe propio del lanzador")
	assert_eq(_session.player_hero.current_health, 30, "el jugador NO recibe dano")


func test_invocacion_enemiga_owner_uno() -> void:
	_setup_basico()
	_session.start()
	var summon := _spell(0, SpellEffect.EffectType.SUMMON, 0, SpellEffect.TargetType.SUMMON_BOARD)
	summon.spell_effects[0].summon_name = "Eco"
	summon.spell_effects[0].summon_attack = 1
	summon.spell_effects[0].summon_health = 1
	summon.spell_effects[0].summon_count = 2
	_session._apply_spell_effects(summon, 1)
	var board := _session.enemy_deck.get_board()
	assert_eq(board.size(), 2, "dos criaturas invocadas al board enemigo")
	assert_eq(board[0].owner_id, 1, "owner del enemigo, no 0")


func test_invocacion_siembra_ability_fn_antes_del_setup() -> void:
	# Regresion: la criatura invocada hereda el ability_fn del lado y dispara
	# ON_SETUP con el handler ya sembrado (antes se re-sembraba tras setup()).
	var triggers: Array = []
	_session.ability_fn = func(_inst: CardInstance, trigger: int) -> void:
		triggers.append(trigger)
	_session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	_session.start()
	var summon := _spell(0, SpellEffect.EffectType.SUMMON, 0, SpellEffect.TargetType.SUMMON_BOARD)
	summon.spell_effects[0].summon_name = "Eco"
	summon.spell_effects[0].summon_attack = 1
	summon.spell_effects[0].summon_health = 1
	summon.spell_effects[0].summon_count = 1
	_session._apply_spell_effects(summon, 0)
	var board := _session.player_deck.get_board()
	assert_eq(board.size(), 1, "la criatura se invoca al board del lanzador")
	assert_true(board[0].ability_fn.is_valid(), "hereda el ability_fn del lado")
	assert_true(triggers.has(CardInstance.Trigger.ON_SETUP), "ON_SETUP se dispara con el handler ya sembrado")


func test_auto_play_aplica_hechizo_del_jugador() -> void:
	_setup_basico()
	_session.start()
	var spell := _spell(0, SpellEffect.EffectType.DAMAGE, 7, SpellEffect.TargetType.ENEMY_HERO)
	_session.player_deck._hand.append(spell)
	var ai := DummyAI.new()
	ai.setup(1)
	_session._auto_play_player(ai)
	assert_eq(_session.enemy.current_health, 23, "el hechizo del jugador surte efecto en auto_resolve")


func test_declare_attacker_rechaza_doble_declaracion() -> void:
	# Regresion bug #1: declarar el mismo atacante dos veces no duplica el par.
	_setup_basico()
	_session.start()
	var inst := CardInstance.new()
	inst.setup(_creature(0, 2, 2), 0)
	inst.can_attack_this_turn = true
	_session.player_deck.add_to_board(inst)
	_session.declare_attacker(inst, null)
	_session.declare_attacker(inst, null)
	assert_eq(_session._player_attack_pairs.size(), 1, "la segunda declaracion se ignora")


func test_declare_attacker_rechaza_mareo_de_invocacion() -> void:
	# Regresion bug #1: una criatura que no puede atacar este turno se rechaza.
	_setup_basico()
	_session.start()
	var inst := CardInstance.new()
	inst.setup(_creature(0, 2, 2), 0)
	inst.can_attack_this_turn = false
	_session.player_deck.add_to_board(inst)
	_session.declare_attacker(inst, null)
	assert_eq(_session._player_attack_pairs.size(), 0, "sin can_attack no se declara")


# Minimal AI subclass honoring the DummyAI contract; used to prove that
# setup() does not overwrite an AI injected by the game layer.
class _StubAI:
	extends DummyAI


# Spy AI that records whether auto_resolve routed the player turn through it.
class _SpyPlayerAI:
	extends DummyAI
	var chose_card: bool = false

	func choose_card_to_play(hand: Array[CardData], mana: int) -> CardData:
		chose_card = true
		return super.choose_card_to_play(hand, mana)


func test_auto_resolve_usa_ai_de_jugador_inyectada() -> void:
	# Chunk D: la IA de jugador inyectada conduce el turno del jugador.
	var hero_cards: Array[CardData] = [_creature(1, 2, 2)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(10), hero_cards, _hero(10), enemy_cards, 7)
	var spy := _SpyPlayerAI.new()
	spy.setup(7)
	_session.auto_resolve(spy)
	assert_true(spy.chose_card, "auto_resolve usa la IA de jugador inyectada")


func test_auto_resolve_sin_ai_es_determinista_por_seed() -> void:
	# Chunk D: sin IA inyectada, auto_resolve sigue siendo determinista por seed.
	var first := CombatSession.new()
	first.setup(_hero(10), [_creature(1, 2, 2)], _hero(10), [_creature(1, 1, 2)], 7)
	first.auto_resolve(null, 42)
	var second := CombatSession.new()
	second.setup(_hero(10), [_creature(1, 2, 2)], _hero(10), [_creature(1, 1, 2)], 7)
	second.auto_resolve(null, 42)
	assert_eq(first.get_result(), second.get_result(), "mismo seed = mismo resultado")


func test_setup_usa_dummy_ai_por_defecto() -> void:
	# Sin inyeccion, setup() instancia el DummyAI de referencia.
	_setup_basico()
	assert_true(_session.ai is DummyAI, "cae al DummyAI por defecto")


func test_setup_respeta_ai_inyectada() -> void:
	# Regresion Chunk 1: una IA asignada antes de setup() no debe ser pisada.
	var stub := _StubAI.new()
	_session.ai = stub
	_setup_basico()
	assert_eq(_session.ai, stub, "setup conserva la IA inyectada")


func test_setup_propaga_damage_fn_al_resolver() -> void:
	# Chunk E: el damage_fn opcional de la sesion se siembra en el resolver.
	_session.damage_fn = func(a: CardInstance, _d: CardInstance) -> int:
		return a.current_attack * 2
	_setup_basico()
	assert_true(_session._resolver.damage_fn.is_valid(), "el hook llega al resolver")


func test_setup_propaga_exhaust_fn_a_los_decks() -> void:
	# Chunk F: el exhaust_fn opcional de la sesion se siembra en ambos mazos.
	_session.exhaust_fn = func(_owner: int) -> void:
		pass
	_setup_basico()
	assert_true(_session.player_deck.exhaust_fn.is_valid(), "el hook llega al mazo del jugador")
	assert_true(_session.enemy_deck.exhaust_fn.is_valid(), "el hook llega al mazo enemigo")


func test_play_card_hechizo_usa_target_explicito_en_player_creature() -> void:
	# Chunk B: un hechizo PLAYER_CREATURE aplica al target explicito provisto a
	# play_card(), no siempre a board[0].
	_setup_basico()
	_session.start()
	var c0 := CardInstance.new()
	c0.setup(_creature(0, 1, 1), 0)
	var c1 := CardInstance.new()
	c1.setup(_creature(0, 1, 1), 0)
	_session.player_deck.add_to_board(c0)
	_session.player_deck.add_to_board(c1)
	var spell := _spell(0, SpellEffect.EffectType.BUFF_ATTACK, 2, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.player_deck._hand.append(spell)
	var ok := _session.play_card(spell, false, 0, 0, c1)
	assert_true(ok, "el hechizo se juega")
	assert_eq(c1.current_attack, 3, "el buff va al target explicito (1 + 2)")
	assert_eq(c0.current_attack, 1, "board[0] no se toca")


func test_play_card_hechizo_player_creature_sin_target_no_aplica() -> void:
	# FIX 4.2 (breaking): sin target explicito, un hechizo PLAYER_CREATURE NO se
	# aplica (falla ruidoso con push_warning), en vez de caer a board[0].
	_setup_basico()
	_session.start()
	var c0 := CardInstance.new()
	c0.setup(_creature(0, 1, 1), 0)
	var c1 := CardInstance.new()
	c1.setup(_creature(0, 1, 1), 0)
	_session.player_deck.add_to_board(c0)
	_session.player_deck.add_to_board(c1)
	var spell := _spell(0, SpellEffect.EffectType.BUFF_ATTACK, 2, SpellEffect.TargetType.PLAYER_CREATURE)
	_session.player_deck._hand.append(spell)
	var ok := _session.play_card(spell)
	assert_true(ok, "el hechizo se consume aunque no haya target")
	assert_eq(c0.current_attack, 1, "ya no hay fallback a board[0]")
	assert_eq(c1.current_attack, 1, "el resto del board tampoco se toca")


func test_play_spell_aplica_effect_a_target_explicito() -> void:
	# Chunk 3: play_spell aplica el effect pasado al target explicito, sin usar
	# los spell_effects propios de la carta.
	_setup_basico()
	_session.start()
	_session.enemy.take_damage(10)
	var card := _spell(0, SpellEffect.EffectType.HEAL, 1, SpellEffect.TargetType.PLAYER_HERO)
	_session.player_deck._hand.append(card)
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.HEAL
	effect.value = 5
	var ok := _session.play_spell(card, effect, _session.enemy)
	assert_true(ok, "el hechizo manual se juega")
	assert_eq(_session.enemy.current_health, 25, "cura 5 al target explicito (20 -> 25)")
