# Card Combat Engine
# Copyright (C) 2026 Javier Islas
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. This program is distributed WITHOUT ANY WARRANTY; see the GNU
# AGPL for details: <https://www.gnu.org/licenses/>.
#
# A commercial license that exempts you from the AGPL is available: see
# LICENSE_COMMERCIAL.md or contact islasjavieralf@gmail.com.

class_name CombatTriggerQueue
extends RefCounted
## Ordered, reentrancy-safe queue of pending ability triggers. Owns the pending
## list; the handler is passed to drain() as an explicit dependency (never the
## session). It exists so a game using QUEUED trigger mode resolves chained
## triggers (a trigger that causes a death that fires another trigger) in a single
## deterministic FIFO order, instead of the reentrant inline firing where the
## chain resolves mid-sweep. Empty by default: INLINE mode never enqueues.

## Each entry: {"inst": CardInstance|null, "trigger": int, "context": Dictionary}.
## inst is null for side-level triggers (e.g. ON_DRAW), mirroring ability_fn.
var _queue: Array = []
## Guards against a reentrant drain() started from within a handler: the outer
## loop owns the iteration, so a nested drain is a no-op and the chained triggers
## it enqueued are picked up by the loop already running.
var _draining: bool = false


func enqueue(inst: Variant, trigger: int, context: Dictionary) -> void:
	_queue.append({"inst": inst, "trigger": trigger, "context": context})


func is_empty() -> bool:
	return _queue.is_empty()


func size() -> int:
	return _queue.size()


func drain(handler: Callable) -> void:
	## Fire every pending trigger in FIFO order, including triggers enqueued by a
	## handler mid-drain (chained). Reentrant calls return immediately so the order
	## stays a single flat FIFO. The handler takes (inst, trigger, context).
	if _draining:
		return
	_draining = true
	while not _queue.is_empty():
		var entry: Dictionary = _queue.pop_front()
		handler.call(entry["inst"], entry["trigger"], entry["context"])
	_draining = false
