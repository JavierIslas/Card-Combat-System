extends GutTest
## CombatTriggerQueue: deterministic FIFO trigger ordering with reentrancy-safe
## draining. Owns the pending-trigger list; the handler is passed in (explicit
## dependency, never the session itself).


var _queue: CombatTriggerQueue


func before_each() -> void:
	_queue = CombatTriggerQueue.new()


func test_new_queue_is_empty() -> void:
	assert_true(_queue.is_empty(), "a fresh queue holds nothing")
	assert_eq(_queue.size(), 0, "size starts at zero")


func test_enqueue_grows_the_queue() -> void:
	_queue.enqueue(null, 1, {})
	_queue.enqueue(null, 2, {})
	assert_false(_queue.is_empty(), "enqueue makes it non-empty")
	assert_eq(_queue.size(), 2, "two pending triggers")


func test_drain_processes_in_fifo_order() -> void:
	_queue.enqueue(null, 1, {})
	_queue.enqueue(null, 2, {})
	_queue.enqueue(null, 3, {})
	var seen: Array = []
	_queue.drain(func(_inst: Variant, trigger: int, _ctx: Dictionary) -> void:
		seen.append(trigger))
	assert_eq(seen, [1, 2, 3], "triggers fire in enqueue order")
	assert_true(_queue.is_empty(), "drain empties the queue")


func test_drain_passes_inst_and_context_through() -> void:
	_queue.enqueue(null, 7, {"amount": 5})
	# Mutate the dict in place: a GDScript lambda captures locals by copy, so
	# reassigning `captured` inside it would not reach this scope; Dictionary is a
	# reference type, so writing keys does.
	var captured: Dictionary = {}
	_queue.drain(func(inst: Variant, trigger: int, ctx: Dictionary) -> void:
		captured["inst"] = inst
		captured["trigger"] = trigger
		captured["ctx"] = ctx)
	assert_eq(captured["trigger"], 7, "trigger passes through")
	assert_null(captured["inst"], "null inst (side-level trigger) passes through")
	assert_eq(captured["ctx"], {"amount": 5}, "context passes through")


func test_trigger_enqueued_during_drain_is_processed_after() -> void:
	# A handler that, reacting to a trigger, enqueues another (e.g. a death that
	# triggers another death). The chained trigger fires in the same drain, after
	# the ones already queued — global FIFO order, not nested recursion.
	_queue.enqueue(null, 1, {})
	_queue.enqueue(null, 2, {})
	var seen: Array = []
	var handler := func(_inst: Variant, trigger: int, _ctx: Dictionary) -> void:
		seen.append(trigger)
		if trigger == 1:
			_queue.enqueue(null, 99, {})
	_queue.drain(handler)
	assert_eq(seen, [1, 2, 99], "chained trigger fires after the already-queued ones")
	assert_true(_queue.is_empty(), "queue drains fully including chained triggers")


func test_reentrant_drain_does_not_start_a_second_loop() -> void:
	# A handler that calls drain() again while a drain is in progress must be a
	# no-op: the outer loop owns the iteration. Without the guard, the nested
	# drain would process the tail out of order or twice.
	_queue.enqueue(null, 1, {})
	_queue.enqueue(null, 2, {})
	var seen: Array = []
	var handler := func(_inst: Variant, trigger: int, _ctx: Dictionary) -> void:
		seen.append(trigger)
		if trigger == 1:
			_queue.enqueue(null, 50, {})
			_queue.drain(func(_i: Variant, _t: int, _c: Dictionary) -> void:
				seen.append(-1))  # must never run: outer loop is draining
	_queue.drain(handler)
	assert_eq(seen, [1, 2, 50], "nested drain is a no-op; outer loop keeps FIFO order")
	assert_true(_queue.is_empty(), "queue still drains fully")
