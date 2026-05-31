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


func test_start_va_a_principal_en_turno_uno() -> void:
	_setup_basico()
	_session.start()
	assert_eq(_session.phase, CombatState.Phase.PRINCIPAL, "tras start queda en PRINCIPAL")
	assert_eq(_session.turn_number, 1, "primer turno")


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


func test_auto_resolve_termina_en_final() -> void:
	var hero_cards: Array[CardData] = [_creature(1, 2, 2), _creature(1, 1, 3)]
	var enemy_cards: Array[CardData] = [_creature(1, 1, 2)]
	_session.setup(_hero(10), hero_cards, _hero(10), enemy_cards, 7)
	_session.auto_resolve(7)
	assert_eq(_session.phase, CombatState.Phase.FINAL, "auto_resolve llega a FINAL sin colgarse")


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
