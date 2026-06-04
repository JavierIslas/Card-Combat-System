extends GutTest
## CombatSession trigger_mode integration: INLINE (default) fires triggers
## depth-first as before; QUEUED defers them into a FIFO queue drained at safe
## points, so a chained reaction resolves breadth-first. Both stay deterministic.


func _hero(hp: int = 30) -> Combatant:
	var c := Combatant.new()
	c.max_health = hp
	c.current_health = hp
	return c


func _creature(id: String, health: int) -> CardData:
	var d := CardData.new()
	d.card_id = id
	d.cost = 0
	d.attack = 1
	d.health = health
	d.play_kind = CardData.PlayKind.UNIT
	return d


func _aoe_on_allies(value: int) -> CardData:
	var d := CardData.new()
	d.card_id = "aoe"
	d.cost = 0
	d.play_kind = CardData.PlayKind.EFFECT
	var e := SpellEffect.new()
	e.effect_type = SpellEffect.EffectType.AOE_DAMAGE
	e.value = value
	e.target_type = SpellEffect.TargetType.PLAYER_CREATURES
	var effects: Array[SpellEffect] = [e]
	d.spell_effects = effects
	return d


func _empty() -> Array[CardData]:
	var a: Array[CardData] = []
	return a


## A self-damage chain handler: the first time a creature takes damage it retaliates
## by hitting the OTHER living creature on its board for 1. The `order` list records
## the ON_DAMAGE_TAKEN order; `reacted` caps each creature to one retaliation so the
## chain terminates (and never recurses forever in INLINE mode).
func _chain_handler(session: CombatSession, order: Array, reacted: Dictionary) -> Callable:
	return func(inst: Variant, trigger: int, _ctx: Dictionary) -> void:
		if trigger != CardInstance.Trigger.ON_DAMAGE_TAKEN or inst == null:
			return
		var id: String = inst.card_data.card_id
		order.append(id)
		if reacted.has(id):
			return
		reacted[id] = true
		for other in session.decks[inst.owner_id].get_board():
			if other != inst and not other.is_dead:
				other.take_damage(1)
				break


func _run_chain(mode: CombatSession.TriggerMode) -> Array:
	var session := CombatSession.new()
	session.config.starting_max_mana = 10
	session.config.initial_hand_size = 3
	var order: Array = []
	var reacted: Dictionary = {}
	session.trigger_mode = mode
	session.ability_fn = _chain_handler(session, order, reacted)
	var deck0: Array[CardData] = [_creature("A", 10), _creature("B", 10), _aoe_on_allies(1)]
	session.setup(_hero(), deck0, _hero(), _empty(), 1)
	session.start()
	# Play both creatures, then the AOE that hits them both and kicks off the chain.
	session.play_card(deck0[0])
	session.play_card(deck0[1])
	session.play_card(deck0[2])
	return order


func test_inline_chain_resolves_depth_first() -> void:
	# A is hit, retaliates into B immediately, B retaliates back into A immediately,
	# then the AOE's second hit lands on B: A, B, A, B.
	var order := _run_chain(CombatSession.TriggerMode.INLINE)
	assert_eq(order, ["A", "B", "A", "B"], "INLINE fires the reaction mid-sweep")


func test_queued_chain_resolves_breadth_first() -> void:
	# Both AOE hits are queued first (A, B); each reaction is appended behind them,
	# so the retaliations fire after the direct hits: A, B, B, A.
	var order := _run_chain(CombatSession.TriggerMode.QUEUED)
	assert_eq(order, ["A", "B", "B", "A"], "QUEUED defers reactions behind queued hits")


func test_queued_matches_inline_result_without_handler() -> void:
	# With no ability_fn there are no deferred triggers, so QUEUED must reproduce the
	# INLINE auto_resolve bit-for-bit (same seed, same starting cards).
	var inline := CombatSession.new()
	inline.setup(_hero(), _starter(), _hero(), _starter(), 7)
	inline.auto_resolve()
	var queued := CombatSession.new()
	queued.trigger_mode = CombatSession.TriggerMode.QUEUED
	queued.setup(_hero(), _starter(), _hero(), _starter(), 7)
	queued.auto_resolve()
	assert_eq(queued.get_result(), inline.get_result(), "QUEUED == INLINE with no handler")


func test_trigger_mode_round_trips_through_serialization() -> void:
	var session := CombatSession.new()
	session.trigger_mode = CombatSession.TriggerMode.QUEUED
	session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	var resumed := CombatSession.deserialize(session.serialize())
	assert_eq(resumed.trigger_mode, CombatSession.TriggerMode.QUEUED, "QUEUED survives resume")


func test_legacy_save_without_trigger_mode_defaults_inline() -> void:
	var session := CombatSession.new()
	session.setup(_hero(), _empty(), _hero(), _empty(), 1)
	var data: Dictionary = session.serialize()
	data.erase("trigger_mode")  # simulate a pre-feature save
	var resumed := CombatSession.deserialize(data)
	assert_eq(resumed.trigger_mode, CombatSession.TriggerMode.INLINE, "legacy save defaults to INLINE")


func _starter() -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.append(_creature("c1", 1))
	cards.append(_creature("c2", 3))
	cards.append(_creature("c3", 4))
	cards.append(_creature("c4", 6))
	cards.append(_creature("c5", 2))
	return cards
