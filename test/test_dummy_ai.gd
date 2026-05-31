extends GutTest
## Caracterizacion de DummyAI: contrato de IA (jugar/atacar/bloquear) y
## determinismo por seed. Incluye regresion del bug #4 (bloqueador reutilizado).


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
