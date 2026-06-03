extends GutTest
## Caracterización de HeuristicAI: contrato de IA con decisiones por valor
## (curva de maná, trades favorables, targeting por efecto, bloqueo de amenazas)
## y determinismo desde el estado del tablero.


func _card(id: String, cost: int) -> CardData:
	var c := CardData.new()
	c.card_id = id
	c.cost = cost
	c.card_type = CardData.CardType.CRIATURA
	return c


func _inst(attack: int, health: int, owner: int = 0) -> CardInstance:
	var data := CardData.new()
	data.attack = attack
	data.health = health
	var i := CardInstance.new()
	i.setup(data, owner)
	return i


func _spell_card(type: SpellEffect.EffectType, value: int = 0) -> CardData:
	var c := CardData.new()
	c.card_id = "hechizo"
	c.card_type = CardData.CardType.HECHIZO
	var e := SpellEffect.new()
	e.effect_type = type
	e.value = value
	var effects: Array[SpellEffect] = [e]
	c.spell_effects = effects
	return c


func test_choose_card_juega_la_mas_cara_asequible() -> void:
	var ai := HeuristicAI.new()
	var hand: Array[CardData] = [_card("barata", 1), _card("media", 3), _card("cara", 9)]
	assert_eq(ai.choose_card_to_play(hand, 5).card_id, "media", "gasta el maná en la carta más cara que alcanza")


func test_choose_card_null_si_no_alcanza() -> void:
	var ai := HeuristicAI.new()
	var hand: Array[CardData] = [_card("cara", 9)]
	assert_null(ai.choose_card_to_play(hand, 2), "sin cartas asequibles devuelve null")


func test_choose_attackers_solo_vivos_y_listos() -> void:
	var ai := HeuristicAI.new()
	var listo := _inst(2, 2)
	listo.can_attack_this_turn = true
	var no_listo := _inst(2, 2)
	var board: Array[CardInstance] = [listo, no_listo]
	var atacantes := ai.choose_attackers(board)
	assert_eq(atacantes.size(), 1, "solo el vivo y listo ataca")
	assert_eq(atacantes[0], listo)


func test_choose_attack_target_prefiere_trade_favorable() -> void:
	var ai := HeuristicAI.new()
	var attacker := _inst(3, 3)
	var matable_fuerte := _inst(2, 2, 1)   # muere (3>=2) y no me mata (2<3)
	var matable_debil := _inst(1, 1, 1)    # también trade favorable, menor ataque
	var board: Array[CardInstance] = [matable_debil, matable_fuerte]
	assert_eq(ai.choose_attack_target(attacker, board), matable_fuerte, "elimina la mayor amenaza que puede matar sin morir")


func test_choose_attack_target_cara_si_no_hay_trade() -> void:
	var ai := HeuristicAI.new()
	var attacker := _inst(1, 1)
	var grande := _inst(5, 5, 1)  # no lo mato y me mata
	var board: Array[CardInstance] = [grande]
	assert_null(ai.choose_attack_target(attacker, board), "sin trade favorable ataca al héroe (null)")


func test_lethal_global_manda_todo_a_la_cara() -> void:
	# Con lethal disponible (la suma de ataques mata al héroe), la IA sacrifica
	# trades favorables y manda todos los ataques a la cara para cerrar la partida.
	var ai := HeuristicAI.new()
	var atacante := _inst(3, 3)
	atacante.can_attack_this_turn = true
	var hero := _hero(3)
	ai.choose_attackers([atacante], [hero] as Array[Combatant])
	var trade := _inst(2, 2, 1)  # normalmente sería un trade favorable
	assert_null(ai.choose_attack_target(atacante, [trade], [hero] as Array[Combatant]), "con lethal ignora el trade y va al héroe")


func test_sin_lethal_mantiene_trade_por_valor() -> void:
	# Si la suma de ataques NO mata al héroe, la IA conserva su lógica de trade.
	var ai := HeuristicAI.new()
	var atacante := _inst(3, 3)
	atacante.can_attack_this_turn = true
	var hero := _hero(30)
	ai.choose_attackers([atacante], [hero] as Array[Combatant])
	var trade := _inst(2, 2, 1)
	assert_eq(ai.choose_attack_target(atacante, [trade], [hero] as Array[Combatant]), trade, "sin lethal prioriza el trade favorable")


func test_sin_heroe_no_hay_lethal() -> void:
	# enemy_heroes vacío (escenario board-only): no se activa lethal, mantiene trades.
	var ai := HeuristicAI.new()
	var atacante := _inst(9, 9)
	atacante.can_attack_this_turn = true
	ai.choose_attackers([atacante], [] as Array[Combatant])
	var trade := _inst(2, 2, 1)
	assert_eq(ai.choose_attack_target(atacante, [trade], [] as Array[Combatant]), trade, "sin héroe enemigo no hay lethal")


func test_choose_spell_target_dano_prefiere_letal() -> void:
	var ai := HeuristicAI.new()
	var sano := _inst(4, 5, 1)
	var letal := _inst(3, 2, 1)  # 3 de daño lo mata
	var target: Variant = ai.choose_spell_target(_spell_card(SpellEffect.EffectType.DAMAGE, 3), [], [sano, letal])
	assert_eq(target, letal, "un hechizo de daño busca un objetivo que pueda matar")


func test_choose_spell_target_cura_al_mas_herido() -> void:
	var ai := HeuristicAI.new()
	var sano := _inst(2, 5, 0)
	var herido := _inst(2, 5, 0)
	herido.take_damage(3)
	var target: Variant = ai.choose_spell_target(_spell_card(SpellEffect.EffectType.HEAL, 2), [sano, herido], [])
	assert_eq(target, herido, "la cura va al aliado más dañado")


func test_choose_blockers_no_hace_chump_block() -> void:
	var ai := HeuristicAI.new()
	var amenaza := _inst(5, 5)
	var chump := _inst(1, 1, 1)  # no mata ni sobrevive
	var blocks := ai.choose_blockers([amenaza], [chump])
	assert_eq(blocks.size(), 0, "no malgasta un bloqueador que solo muere sin valor")


func test_choose_blockers_bloquea_la_mayor_amenaza() -> void:
	var ai := HeuristicAI.new()
	var grande := _inst(4, 4)
	var chico := _inst(1, 1)
	var muro := _inst(0, 6, 1)  # sobrevive a cualquiera
	var blocks := ai.choose_blockers([chico, grande], [muro])
	assert_true(blocks.has(grande), "asigna el único defensor a la mayor amenaza")
	assert_false(blocks.has(chico), "no al atacante menor")


func test_es_determinista_desde_el_estado() -> void:
	var spell := _spell_card(SpellEffect.EffectType.DAMAGE, 2)
	var enemy1: Array[CardInstance] = [_inst(3, 2, 1), _inst(4, 2, 1)]
	var enemy2: Array[CardInstance] = [_inst(3, 2, 1), _inst(4, 2, 1)]
	var ai := HeuristicAI.new()
	var t1: Variant = ai.choose_spell_target(spell, [], enemy1)
	var t2: Variant = ai.choose_spell_target(spell, [], enemy2)
	assert_eq(t1.current_attack, t2.current_attack, "mismo estado, misma decisión")


func test_auto_resolve_heuristic_vs_dummy_no_pierde_winrate() -> void:
	# Sanity (no balance fino): en una tanda seedeada, HeuristicAI gana al menos
	# tantas veces como DummyAI controlando el otro lado.
	var heuristic_wins: int = 0
	var dummy_wins: int = 0
	for s in range(20):
		var session := CombatSession.new()
		var heuristic := HeuristicAI.new()
		heuristic.setup(s)
		var dummy := DummyAI.new()
		dummy.setup(s)
		session.ais[0] = heuristic
		session.ais[1] = dummy
		session.setup(_hero(), _starter(), _hero(), _starter(), s)
		session.auto_resolve()
		var winner: int = session.get_result()["winner_side"]
		if winner == 0:
			heuristic_wins += 1
		elif winner == 1:
			dummy_wins += 1
	assert_gte(heuristic_wins, dummy_wins, "HeuristicAI no pierde win-rate frente a DummyAI")


func _hero(hp: int = 30) -> Combatant:
	var c := Combatant.new()
	c.max_health = hp
	c.current_health = hp
	return c


func _starter() -> Array[CardData]:
	var cards: Array[CardData] = []
	var stats := [[1, 2, 1], [2, 2, 3], [3, 4, 4], [4, 4, 6], [1, 1, 2]]
	for s in stats:
		var d := CardData.new()
		d.cost = s[0]
		d.attack = s[1]
		d.health = s[2]
		d.card_type = CardData.CardType.CRIATURA
		cards.append(d)
	return cards
