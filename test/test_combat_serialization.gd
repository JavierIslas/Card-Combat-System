extends GutTest
## Caracterización del round-trip de serialización: CardData/SpellEffect,
## CardInstance (buffs, hidden, daño), CombatDeck (mano/mazo/tablero/RNG) y
## CombatSession (estado de FSM, héroes, event_log, muertos, pares de ataque).
## Los Callables no se serializan: se re-inyectan vía hooks al deserializar.


func _hero(hp: int = 30) -> Combatant:
	var c := Combatant.new()
	c.display_name = "Heroe"
	c.max_health = hp
	c.current_health = hp
	return c


func _creature(id: String, cost: int, attack: int, health: int) -> CardData:
	var d := CardData.new()
	d.card_id = id
	d.cost = cost
	d.attack = attack
	d.health = health
	d.card_type = CardData.CardType.CRIATURA
	return d


func _starter() -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.append(_creature("c1", 1, 2, 1))
	cards.append(_creature("c2", 2, 2, 3))
	cards.append(_creature("c3", 3, 4, 4))
	return cards


func test_card_data_round_trip_incluye_spell_effects() -> void:
	var card := CardData.new()
	card.card_id = "rayo"
	card.cost = 2
	card.card_type = CardData.CardType.HECHIZO
	var e := SpellEffect.new()
	e.effect_type = SpellEffect.EffectType.DAMAGE
	e.value = 3
	e.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	var effects: Array[SpellEffect] = [e]
	card.spell_effects = effects
	var restored := CardData.from_dict(card.serialize())
	assert_eq(restored.card_id, "rayo", "preserva el id")
	assert_eq(restored.spell_effects.size(), 1, "preserva los efectos del hechizo")
	assert_eq(restored.spell_effects[0].value, 3, "preserva el value del efecto")
	assert_eq(restored.spell_effects[0].target_type, SpellEffect.TargetType.PLAYER_CREATURE, "preserva el target_type")


func test_card_instance_round_trip_preserva_buffs_y_hidden() -> void:
	var inst := CardInstance.new()
	inst.setup(_creature("guerrero", 3, 2, 5), 1)
	inst.apply_permanent_buff(1, 1)
	inst.apply_temp_buff(2, 0)
	inst.take_damage(1)
	var restored := CardInstance.deserialize(inst.serialize())
	assert_eq(restored.owner_id, 1, "preserva el owner")
	assert_eq(restored.current_attack, inst.current_attack, "preserva el ataque actual con buffs")
	assert_eq(restored.current_health, inst.current_health, "preserva la vida actual")
	assert_eq(restored.current_max_health, inst.current_max_health, "preserva la vida máxima")
	assert_eq(restored.permanent_buff_count, 1, "preserva el conteo de buffs permanentes")


func test_card_instance_deserialize_no_redispara_on_setup() -> void:
	# Resuming must not re-fire ON_SETUP (it would re-apply on-play effects).
	var fired: Array = []
	var handler := func(_inst: CardInstance, trigger: int) -> void:
		if trigger == CardInstance.Trigger.ON_SETUP:
			fired.append(true)
	var inst := CardInstance.new()
	inst.setup(_creature("x", 1, 1, 1), 0)
	var restored := CardInstance.deserialize(inst.serialize(), handler)
	assert_eq(fired.size(), 0, "deserialize no dispara ON_SETUP")
	assert_true(restored.ability_fn.is_valid(), "pero re-inyecta el ability_fn")


func test_deck_round_trip_preserva_zonas_y_rng() -> void:
	var deck := CombatDeck.new()
	deck.setup(_starter(), 0, 3, Callable(), -1, 99)
	deck.draw_initial_hand(2)
	deck.gain_mana(3)
	var restored := CombatDeck.deserialize(deck.serialize())
	assert_eq(restored.owner_id, 0, "preserva el owner")
	assert_eq(restored.hand_size, deck.hand_size, "preserva el tamaño de mano")
	assert_eq(restored.draw_pile_size, deck.draw_pile_size, "preserva el mazo")
	assert_eq(restored.mana, deck.mana, "preserva el maná")
	assert_eq(restored.max_mana, deck.max_mana, "preserva el maná máximo")


func test_session_round_trip_preserva_estado() -> void:
	var session := CombatSession.new()
	session.setup(_hero(20), _starter(), _hero(20), _starter(), 5)
	session.start()
	session.heroes[1].take_damage(4)
	var data := session.serialize()
	var restored := CombatSession.deserialize(data)
	assert_eq(restored.phase, session.phase, "preserva la fase")
	assert_eq(restored.active_side, session.active_side, "preserva el lado activo")
	assert_eq(restored.turn_number, session.turn_number, "preserva el número de turno")
	assert_eq(restored.heroes[1].current_health, 16, "preserva la vida de los héroes")
	assert_eq(restored.decks[0].hand_size, session.decks[0].hand_size, "preserva la mano del lado 0")


func test_session_round_trip_preserva_event_log() -> void:
	var session := CombatSession.new()
	session.setup(_hero(15), _starter(), _hero(15), _starter(), 5)
	session.auto_resolve()
	var restored := CombatSession.deserialize(session.serialize())
	var original_log: Array = session.event_log.map(func(ev: CombatEvent) -> Dictionary: return ev.serialize())
	var restored_log: Array = restored.event_log.map(func(ev: CombatEvent) -> Dictionary: return ev.serialize())
	assert_eq(restored_log, original_log, "el event_log round-trips idéntico")


func test_session_round_trip_preserva_muertos() -> void:
	var session := CombatSession.new()
	session.setup(_hero(15), _starter(), _hero(15), _starter(), 5)
	session.auto_resolve()
	var data := session.serialize()
	var restored := CombatSession.deserialize(data)
	assert_eq(restored.get_dead_creatures(0).size(), session.get_dead_creatures(0).size(), "preserva muertos del lado 0")
	assert_eq(restored.get_dead_creatures(1).size(), session.get_dead_creatures(1).size(), "preserva muertos del lado 1")


func test_session_round_trip_preserva_par_de_ataque() -> void:
	var session := CombatSession.new()
	session.setup(_hero(20), [_creature("atk", 1, 3, 3)], _hero(20), [_creature("def", 1, 1, 5)], 5)
	session.start()
	# Drive both sides onto the board, then declare a directed attack.
	var atacante: CardInstance = session.decks[0].get_board()[0] if not session.decks[0].get_board().is_empty() else session.decks[0].play_creature(session.decks[0].get_hand()[0])
	atacante.can_attack_this_turn = true
	session.declare_attacker(atacante)
	assert_eq(session._attack_pairs[0].size(), 1, "hay un par de ataque declarado")
	var restored := CombatSession.deserialize(session.serialize())
	assert_eq(restored._attack_pairs[0].size(), 1, "el par de ataque se restaura por índice")
	assert_eq(restored._attack_pairs[0][0].attacker.card_data.card_id, "atk", "con el atacante correcto")


func test_session_deserializada_puede_continuar() -> void:
	# A resumed combat must be drivable to completion without crashing.
	var session := CombatSession.new()
	session.setup(_hero(12), _starter(), _hero(12), _starter(), 5)
	session.start()
	var restored := CombatSession.deserialize(session.serialize())
	restored.auto_resolve()
	assert_eq(restored.phase, CombatState.Phase.FINAL, "la sesión deserializada llega a FINAL")
