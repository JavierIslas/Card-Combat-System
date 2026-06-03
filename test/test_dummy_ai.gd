extends GutTest
## Caracterizacion de DummyAI: contrato de IA (jugar/atacar/bloquear) y
## determinismo por seed. Incluye regresion del bug #4 (bloqueador reutilizado).


func _card(id: String, cost: int) -> CardData:
	var c := CardData.new()
	c.card_id = id
	c.cost = cost
	c.card_type = CardData.CardType.CREATURE
	return c


func _inst(attack: int, health: int, owner: int = 0) -> CardInstance:
	var data := CardData.new()
	data.attack = attack
	data.health = health
	var i := CardInstance.new()
	i.setup(data, owner)
	return i


func test_choose_card_solo_asequibles() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var hand: Array[CardData] = [_card("barata", 1), _card("cara", 9)]
	assert_eq(ai.choose_card_to_play(hand, 2).card_id, "barata", "solo elige lo que alcanza el mana")


func test_choose_card_null_si_no_alcanza() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var hand: Array[CardData] = [_card("cara", 9)]
	assert_null(ai.choose_card_to_play(hand, 2), "sin cartas asequibles devuelve null")


func test_choose_card_determinista_con_seed() -> void:
	var hand: Array[CardData] = [_card("a", 1), _card("b", 1), _card("c", 1)]
	var ai1 := DummyAI.new()
	ai1.setup(42)
	var ai2 := DummyAI.new()
	ai2.setup(42)
	assert_eq(ai1.choose_card_to_play(hand, 5).card_id, ai2.choose_card_to_play(hand, 5).card_id, "mismo seed, misma eleccion")


func test_choose_attackers_omite_muertos_y_no_listos() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var listo := _inst(2, 2)
	listo.can_attack_this_turn = true
	var no_listo := _inst(2, 2)
	no_listo.can_attack_this_turn = false
	var muerto := _inst(2, 2)
	muerto.can_attack_this_turn = true
	muerto.is_dead = true
	var board: Array[CardInstance] = [listo, no_listo, muerto]
	var atacantes := ai.choose_attackers(board)
	assert_eq(atacantes.size(), 1, "solo el vivo y listo ataca")
	assert_eq(atacantes[0], listo)


func test_choose_attack_target_null_si_board_vacio() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var vacio: Array[CardInstance] = []
	assert_null(ai.choose_attack_target(_inst(1, 1), vacio), "sin defensores, ataca al heroe (null)")


func _spell_card(type: SpellEffect.EffectType) -> CardData:
	var c := CardData.new()
	c.card_id = "hechizo"
	c.card_type = CardData.CardType.SPELL
	var e := SpellEffect.new()
	e.effect_type = type
	var effects: Array[SpellEffect] = [e]
	c.spell_effects = effects
	return c


func test_choose_spell_target_dano_va_al_enemigo() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var ally := _inst(2, 2, 0)
	var enemy := _inst(3, 3, 1)
	var target: Variant = ai.choose_spell_target(_spell_card(SpellEffect.EffectType.DAMAGE), [ally], [enemy])
	assert_eq(target, enemy, "un hechizo de daño targetea el tablero enemigo, no el propio")


func test_choose_spell_target_cura_va_al_aliado() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var ally := _inst(2, 2, 0)
	var enemy := _inst(3, 3, 1)
	var target: Variant = ai.choose_spell_target(_spell_card(SpellEffect.EffectType.HEAL), [ally], [enemy])
	assert_eq(target, ally, "un hechizo de cura targetea el tablero propio")


func test_choose_spell_target_null_sin_criaturas_vivas() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var muerto := _inst(2, 2, 1)
	muerto.is_dead = true
	var vacio: Array[CardInstance] = []
	assert_null(ai.choose_spell_target(_spell_card(SpellEffect.EffectType.DAMAGE), vacio, [muerto]), "sin criaturas vivas devuelve null")


func test_choose_spell_target_determinista_con_seed() -> void:
	var spell := _spell_card(SpellEffect.EffectType.DAMAGE)
	var own: Array[CardInstance] = [_inst(1, 1, 0)]
	var enemy: Array[CardInstance] = [_inst(3, 3, 1), _inst(4, 4, 1)]
	var ai1 := DummyAI.new()
	ai1.setup(7)
	var ai2 := DummyAI.new()
	ai2.setup(7)
	assert_eq(ai1.choose_spell_target(spell, own, enemy), ai2.choose_spell_target(spell, own, enemy), "mismo seed, mismo target")


func test_choose_blockers_no_reutiliza_bloqueador() -> void:
	# Regresion bug #4: un bloqueador no puede asignarse a mas de un atacante.
	var ai := DummyAI.new()
	ai.setup(1)
	var attackers: Array[CardInstance] = [_inst(1, 1), _inst(1, 1), _inst(1, 1), _inst(1, 1)]
	var own: Array[CardInstance] = [_inst(1, 1, 1), _inst(1, 1, 1)]
	var blocks := ai.choose_blockers(attackers, own)
	assert_true(blocks.size() <= 2, "no asigna mas bloqueos que defensores disponibles")
	var usados := {}
	for atk in blocks:
		var b: CardInstance = blocks[atk]
		assert_false(usados.has(b), "ningun bloqueador se reutiliza")
		usados[b] = true


func test_choose_blockers_vacio_sin_defensores() -> void:
	var ai := DummyAI.new()
	ai.setup(1)
	var attackers: Array[CardInstance] = [_inst(1, 1)]
	var own: Array[CardInstance] = []
	assert_eq(ai.choose_blockers(attackers, own).size(), 0, "sin board no hay bloqueos")


func test_serialize_state_round_trip_reanuda_secuencia_rng() -> void:
	# #5: a restored AI reproduces the exact same picks as the original from the
	# point of capture, so a resumed combat stays deterministic.
	var ai := DummyAI.new()
	ai.setup(7)
	var hand: Array[CardData] = [_card("a", 1), _card("b", 1), _card("c", 1)]
	ai.choose_card_to_play(hand, 5)  # advance the RNG past its initial state
	var restored := DummyAI.new()
	restored.restore_state(ai.serialize_state())
	assert_eq(
		restored.choose_card_to_play(hand, 5).card_id,
		ai.choose_card_to_play(hand, 5).card_id,
		"el AI restaurado continúa la misma secuencia que el original")


func test_serialize_state_captura_seed_y_estado() -> void:
	# #5: the serialized state exposes both the seed and the live RNG position.
	var ai := DummyAI.new()
	ai.setup(3)
	var state := ai.serialize_state()
	assert_eq(int(state.get("seed", -99)), 3, "guarda el seed")
	assert_true(state.has("rng_state"), "guarda el estado vivo del RNG")
