extends GutTest
## Fuzz tests for CombatSession.apply_command: sends random/invalid commands and
## verifies the session never crashes and state stays consistent.


var _rng: RandomNumberGenerator


func before_each() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = 12345


func _make_session() -> CombatSession:
	var session := CombatSession.new()
	var h0 := Combatant.new()
	h0.max_health = 30
	h0.current_health = 30
	var h1 := Combatant.new()
	h1.max_health = 30
	h1.current_health = 30
	session.setup(h0, _small_deck(), h1, _small_deck(), 42)
	session.start()
	return session


func _small_deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	for i in 5:
		var c := CardData.new()
		c.card_id = "card_%d" % i
		c.name = c.card_id
		c.cost = i
		c.attack = i + 1
		c.health = i + 2
		c.play_kind = CardData.PlayKind.UNIT
		cards.append(c)
	return cards


func _assert_consistent(session: CombatSession, sent: int) -> void:
	## Invariants that must hold no matter what garbage was thrown at the session.
	assert_true(CombatState.Phase.values().has(session.phase), "phase stays a valid enum value")
	assert_lte(session.command_log.size(), sent, "command_log never exceeds the commands sent")
	for side in session.side_count():
		var hero: Combatant = session.heroes[side]
		assert_between(hero.current_health, 0, hero.max_health, "hero %d hp stays in [0, max]" % side)


func _random_cmd() -> CombatCommand:
	## Generate a random command with random payload values.
	var types: Array = CombatCommand.CommandType.values()
	var t: int = types[_rng.randi() % types.size()]
	var side: int = _rng.randi() % 3 - 1  # -1, 0, 1
	var payload: Dictionary = {}
	# Random payload keys
	for _j in 3:
		var key: String = ["hand_index", "attacker_index", "blocker_index", "hero_side",
			"target_side", "target_index", "foo", "bar", "as_hidden"][_rng.randi() % 9]
		if key == "as_hidden":
			payload[key] = _rng.randi() % 2 == 0
		else:
			payload[key] = _rng.randi() % 20 - 5  # includes negative indices
	return CombatCommand.new(t, side, payload)


func test_fuzz_random_commands_no_crash() -> void:
	## Send 200 random commands to a session; state must stay consistent throughout.
	var session := _make_session()
	for i in 200:
		session.apply_command(_random_cmd())
	_assert_consistent(session, 200)


func test_fuzz_null_command() -> void:
	var session := _make_session()
	var result: bool = session.apply_command(null)
	assert_false(result, "null command is rejected")
	assert_eq(session.command_log.size(), 0, "nothing logged")


func test_fuzz_negative_side() -> void:
	var session := _make_session()
	var cmd := CombatCommand.new(CombatCommand.CommandType.PLAY_CARD, -1, {"hand_index": 0})
	var result: bool = session.apply_command(cmd)
	assert_false(result, "negative side is rejected")
	assert_eq(session.command_log.size(), 0, "rejected command is not logged")


func test_fuzz_out_of_range_hand_index() -> void:
	## An out-of-range hand index must always be rejected, regardless of the phase
	## the session happens to be in after start().
	var session := _make_session()
	var cmd := CombatCommand.new(CombatCommand.CommandType.PLAY_CARD, 0, {"hand_index": 999})
	var result: bool = session.apply_command(cmd)
	assert_false(result, "out-of-range hand index is rejected")
	assert_eq(session.command_log.size(), 0, "rejected command is not logged")


func test_fuzz_state_consistency_after_abuse() -> void:
	## After 100 random commands, a serialize/deserialize round-trip preserves the
	## phase and the command log size.
	var session := _make_session()
	for i in 100:
		session.apply_command(_random_cmd())
	var data: Dictionary = session.serialize()
	assert_gt(data.size(), 0, "serialize produces data after fuzz abuse")
	var h0 := Combatant.new()
	h0.max_health = 30
	h0.current_health = 30
	var h1 := Combatant.new()
	h1.max_health = 30
	h1.current_health = 30
	# deserialize is static and returns a fresh session — use its return value.
	var restored: CombatSession = CombatSession.deserialize(data, {"heroes": [h0, h1]})
	assert_eq(restored.phase, session.phase, "round-trip preserves phase")
	assert_eq(restored.command_log.size(), session.command_log.size(), "round-trip preserves command log")


func test_fuzz_many_null_commands() -> void:
	var session := _make_session()
	for i in 50:
		session.apply_command(null)
	assert_eq(session.command_log.size(), 0, "null commands never log")
	assert_false(session._combat_over, "null commands don't end combat")


func test_fuzz_invalid_command_type_value() -> void:
	## A command built from an unknown type via deserialize must be rejected, not
	## logged, and must not advance the phase.
	var session := _make_session()
	var before: CombatState.Phase = session.phase
	var cmd := CombatCommand.deserialize({"type": "INVALID_TYPE", "side": 0, "payload": {}})
	var result: bool = session.apply_command(cmd)
	assert_false(result, "unknown command type is rejected")
	assert_eq(session.command_log.size(), 0, "unknown command type is not logged")
	assert_eq(session.phase, before, "unknown command type does not change phase")


func test_fuzz_same_command_repeated() -> void:
	## Sending the same ADVANCE 50 times keeps state consistent and never logs more
	## than the commands that actually took effect.
	var session := _make_session()
	var cmd := CombatCommand.new(CombatCommand.CommandType.ADVANCE, 0, {})
	for i in 50:
		session.apply_command(cmd)
	_assert_consistent(session, 50)
