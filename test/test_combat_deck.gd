extends GutTest
## Caracterización de CombatDeck: robo, maná, jugar criatura/hechizo, cementerio,
## limpieza de muertos y siembra del tope de mejoras.


var _deck: CombatDeck


func before_each() -> void:
	_deck = CombatDeck.new()


func _make_card(cost: int, attack: int, health: int, type := CardData.CardType.CRIATURA) -> CardData:
	var data := CardData.new()
	data.cost = cost
	data.attack = attack
	data.health = health
	data.card_type = type
	return data


func _cards(n: int) -> Array[CardData]:
	var result: Array[CardData] = []
	for i in n:
		result.append(_make_card(1, 1, 1))
	return result


func _ided_cards(n: int) -> Array[CardData]:
	var result: Array[CardData] = []
	for i in n:
		var c := _make_card(1, 1, 1)
		c.card_id = "c%d" % i
		result.append(c)
	return result


# --- Barajado determinista ---

func test_shuffle_seed_fijo_reproduce_el_orden_de_robo() -> void:
	var deck_a := CombatDeck.new()
	var deck_b := CombatDeck.new()
	deck_a.setup(_ided_cards(10), 0, 2, Callable(), -1, 42)
	deck_b.setup(_ided_cards(10), 0, 2, Callable(), -1, 42)
	var order_a: Array[String] = []
	var order_b: Array[String] = []
	for i in 10:
		order_a.append(deck_a.draw_card().card_id)
		order_b.append(deck_b.draw_card().card_id)
	assert_eq(order_a, order_b, "mismo seed de barajado reproduce el orden de robo")


func test_shuffle_realmente_baraja_el_mazo() -> void:
	var deck := CombatDeck.new()
	deck.setup(_ided_cards(10), 0, 2, Callable(), -1, 42)
	var order: Array[String] = []
	for i in 10:
		order.append(deck.draw_card().card_id)
	var insertion_order: Array[String] = []
	for i in 10:
		insertion_order.append("c%d" % i)
	assert_ne(order, insertion_order, "el seed 42 no deja el orden de inserción")


# --- Robo ---

func test_draw_initial_hand() -> void:
	_deck.setup(_cards(5), 0)
	_deck.draw_initial_hand(3)
	assert_eq(_deck.hand_size, 3, "roba 3 a la mano")
	assert_eq(_deck.draw_pile_size, 2, "quedan 2 en el mazo")


func test_draw_card_vacio_emite_deck_exhausted() -> void:
	_deck.setup(_cards(0), 0)
	watch_signals(_deck)
	var card := _deck.draw_card()
	assert_null(card, "no hay carta para robar")
	assert_signal_emitted(_deck, "deck_exhausted")


func test_draw_card_vacio_invoca_exhaust_fn_con_owner() -> void:
	# Chunk F: con exhaust_fn inyectada, un robo fallido por mazo vacio invoca el
	# hook con el owner del mazo (para que el juego aplique fatiga). Sin hook =
	# solo la senal (ver test anterior).
	_deck.setup(_cards(0), 3)
	var seen := {"owner": -1}
	_deck.exhaust_fn = func(owner: int) -> void:
		seen["owner"] = owner
	_deck.draw_card()
	assert_eq(seen["owner"], 3, "exhaust_fn recibe el owner del mazo agotado")


# --- Maná ---

func test_gain_mana_se_topa_a_max_mana() -> void:
	_deck.setup(_cards(1), 0, 3)  # max_mana = 3
	_deck.gain_mana(10)
	assert_eq(_deck.mana, 3, "el maná se topa al máximo")


func test_spend_mana_insuficiente_retorna_false() -> void:
	_deck.setup(_cards(1), 0, 3)
	_deck.gain_mana(2)
	assert_false(_deck.spend_mana(5), "no alcanza el maná")
	assert_eq(_deck.mana, 2, "no se descuenta nada")


func test_increment_max_mana() -> void:
	_deck.setup(_cards(1), 0, 2)
	_deck.increment_max_mana(2)
	assert_eq(_deck.max_mana, 4)


# --- can_play_card / play_creature ---

func test_can_play_card_requiere_mana_y_estar_en_mano() -> void:
	_deck.setup(_cards(0), 0, 5)
	var card := _make_card(3, 2, 2)
	_deck._hand.append(card)
	_deck.gain_mana(5)
	assert_true(_deck.can_play_card(card))
	var foreign := _make_card(1, 1, 1)
	assert_false(_deck.can_play_card(foreign), "carta que no está en la mano no se puede jugar")


func test_play_creature_descuenta_mana_y_va_al_board() -> void:
	_deck.setup(_cards(0), 0, 5)
	var card := _make_card(3, 2, 2)
	_deck._hand.append(card)
	_deck.gain_mana(5)
	var inst := _deck.play_creature(card)
	assert_not_null(inst)
	assert_eq(_deck.mana, 2, "5 - 3 de coste")
	assert_eq(_deck.board_size, 1, "la criatura va al tablero")
	assert_eq(_deck.hand_size, 0, "sale de la mano")


func test_play_creature_siembra_tope_de_mejoras() -> void:
	_deck.setup(_cards(0), 0, 5, Callable(), 3)  # cap de mejoras = 3
	var card := _make_card(1, 1, 1)
	_deck._hand.append(card)
	_deck.gain_mana(5)
	var inst := _deck.play_creature(card)
	assert_eq(inst.max_permanent_buffs, 3, "el tope de CombatConfig se siembra en la instancia")


func test_play_creature_sin_mana_falla() -> void:
	_deck.setup(_cards(0), 0, 1)
	var card := _make_card(5, 2, 2)
	_deck._hand.append(card)
	_deck.gain_mana(1)
	assert_null(_deck.play_creature(card), "sin maná no se juega")
	assert_eq(_deck.board_size, 0)


# --- play_spell ---

func test_play_spell_va_al_cementerio() -> void:
	_deck.setup(_cards(0), 0, 5)
	var spell := _make_card(2, 0, 0, CardData.CardType.HECHIZO)
	_deck._hand.append(spell)
	_deck.gain_mana(5)
	var played := _deck.play_spell(spell)
	assert_eq(played, spell)
	assert_eq(_deck.get_graveyard().size(), 1, "el hechizo va al cementerio")
	assert_eq(_deck.mana, 3, "descuenta el coste")


# --- remove_dead_creatures / refresh ---

func test_remove_dead_creatures() -> void:
	_deck.setup(_cards(0), 0, 5)
	var c1 := _make_card(1, 1, 1)
	var c2 := _make_card(1, 1, 1)
	_deck._hand.append(c1)
	_deck._hand.append(c2)
	_deck.gain_mana(5)
	var i1 := _deck.play_creature(c1)
	_deck.play_creature(c2)
	i1.take_damage(10)  # muere
	var dead := _deck.remove_dead_creatures()
	assert_eq(dead.size(), 1, "uno muerto removido")
	assert_eq(_deck.board_size, 1, "queda el vivo")


func test_refresh_creatures_habilita_ataque() -> void:
	_deck.setup(_cards(0), 0, 5)
	var card := _make_card(1, 1, 1)
	_deck._hand.append(card)
	_deck.gain_mana(5)
	var inst := _deck.play_creature(card)
	inst.can_attack_this_turn = false
	_deck.refresh_creatures_for_turn()
	assert_true(inst.can_attack_this_turn, "tras refresh puede atacar")
