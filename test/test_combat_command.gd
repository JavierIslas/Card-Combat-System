extends GutTest
## CombatCommand + CombatSession.apply_command: routing, validación (no muta en
## comando ilegal), y command_log que crece solo en éxito.


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


func _empty() -> Array[CardData]:
	var a: Array[CardData] = []
	return a


func test_command_round_trip() -> void:
	var cmd := CombatCommand.new(CombatCommand.CommandType.DECLARE_ATTACKER, 1, {
		"attacker_index": 2, "target_side": 0, "target_index": 1,
	})
	var restored := CombatCommand.deserialize(cmd.serialize())
	assert_eq(restored.type, CombatCommand.CommandType.DECLARE_ATTACKER, "preserva el tipo")
	assert_eq(restored.side, 1, "preserva el lado")
	assert_eq(int(restored.payload["attacker_index"]), 2, "preserva el payload")
	assert_eq(int(restored.payload["target_index"]), 1, "preserva el target")


func test_play_card_via_command_juega_y_loguea() -> void:
	_session.setup(_hero(), [_creature(1, 2, 1)], _hero(), _empty(), 1)
	_session.start()  # MAIN, lado 0
	var ok := _session.apply_command(CombatCommand.new(CombatCommand.CommandType.PLAY_CARD, 0, {"hand_index": 0}))
	assert_true(ok, "el comando PLAY_CARD válido se aplica")
	assert_eq(_session.decks[0].get_board().size(), 1, "la criatura entra al tablero")
	assert_eq(_session.command_log.size(), 1, "el comando aceptado entra al command_log")


func test_comando_de_lado_pasivo_es_rechazado_sin_mutar() -> void:
	_session.setup(_hero(), [_creature(1, 2, 1)], _hero(), [_creature(1, 2, 1)], 1)
	_session.start()  # MAIN, lado 0 activo
	var ok := _session.apply_command(CombatCommand.new(CombatCommand.CommandType.PLAY_CARD, 1, {"hand_index": 0}))
	assert_false(ok, "el lado pasivo no puede jugar carta en el turno del activo")
	assert_eq(_session.decks[1].get_board().size(), 0, "no muta el tablero del pasivo")
	assert_eq(_session.command_log.size(), 0, "un comando rechazado no entra al command_log")


func test_play_card_hand_index_invalido_rechazado() -> void:
	_session.setup(_hero(), [_creature(1, 2, 1)], _hero(), _empty(), 1)
	_session.start()
	var ok := _session.apply_command(CombatCommand.new(CombatCommand.CommandType.PLAY_CARD, 0, {"hand_index": 99}))
	assert_false(ok, "índice de mano fuera de rango se rechaza")
	assert_eq(_session.command_log.size(), 0, "sin append en rechazo")


func test_declare_attacker_y_blocker_via_command() -> void:
	_session.setup(_hero(30), _empty(), _hero(30), _empty(), 1)
	_session.start()
	var atk := CardInstance.new()
	atk.setup(_creature(0, 3, 3), 0)
	atk.can_attack_this_turn = true
	_session.decks[0].add_to_board(atk)
	var blk := CardInstance.new()
	blk.setup(_creature(0, 1, 4), 1)
	_session.decks[1].add_to_board(blk)
	# Lado 0 (activo) declara atacante por índice; null target = héroe.
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.DECLARE_ATTACKER, 0, {"attacker_index": 0})), "declara atacante")
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.END_MAIN, 0, {})), "END_MAIN transiciona")
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.END_ATTACK, 0, {})), "END_ATTACK transiciona")
	# Lado 1 (pasivo) declara bloqueador en DEFENSE.
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.DECLARE_BLOCKER, 1, {"attacker_index": 0, "blocker_index": 0})), "el pasivo declara bloqueo")
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.END_DEFENSE, 1, {})), "END_DEFENSE transiciona")
	assert_eq(_session.heroes[1].current_health, 30, "el daño fue bloqueado, el héroe pasivo no recibe daño")
	assert_eq(_session.command_log.size(), 5, "los 5 comandos aceptados quedan logueados")


func test_declare_blocker_via_command_desde_lado_aliado_del_objetivo_2v2() -> void:
	_session.setup_sides([
		{"hero": _hero(30), "cards": _empty()},
		{"hero": _hero(30), "cards": _empty()},
		{"hero": _hero(30), "cards": _empty()},
		{"hero": _hero(30), "cards": _empty()},
	], [0, 0, 1, 1], 1)
	_session.start()  # MAIN, lado 0
	var atk := CardInstance.new()
	atk.setup(_creature(0, 3, 3), 0)
	atk.can_attack_this_turn = true
	_session.decks[0].add_to_board(atk)
	var blk := CardInstance.new()
	blk.setup(_creature(0, 1, 5), 3)  # lado 3, compañero del lado atacado (lado 2)
	_session.decks[3].add_to_board(blk)
	# Lado 0 ataca al héroe del lado 2 (hero_side), avanza a DEFENSE.
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.DECLARE_ATTACKER, 0, {"attacker_index": 0, "hero_side": 2})), "declara ataque dirigido al lado 2")
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.END_MAIN, 0, {})), "END_MAIN")
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.END_ATTACK, 0, {})), "END_ATTACK")
	# El lado 3 (enemigo del activo) bloquea aunque no sea el lado atacado.
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.DECLARE_BLOCKER, 3, {"attacker_index": 0, "blocker_index": 0})), "el lado 3 bloquea")
	assert_true(_session.apply_command(CombatCommand.new(CombatCommand.CommandType.END_DEFENSE, 3, {})), "el lado 3 cierra la defensa")
	assert_eq(_session.heroes[2].current_health, 30, "el ataque fue bloqueado, el héroe del lado 2 no recibe daño")
	assert_eq(blk.current_health, 2, "el bloqueador del lado 3 recibe el daño (5-3)")


func test_advance_via_command_desde_begin() -> void:
	_session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	assert_eq(_session.phase, CombatState.Phase.BEGIN, "arranca en BEGIN")
	var ok := _session.apply_command(CombatCommand.new(CombatCommand.CommandType.ADVANCE, 0, {}))
	assert_true(ok, "ADVANCE desde BEGIN cambia de fase")
	assert_eq(_session.phase, CombatState.Phase.MAIN, "BEGIN -> (PREPARATION auto) -> MAIN")
