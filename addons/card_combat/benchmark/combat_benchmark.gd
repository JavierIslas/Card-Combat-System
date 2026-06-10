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

extends SceneTree
## Headless, deterministic benchmark + memory-leak gate for the combat engine.
##
## Purpose: give a refactor of CombatSession a safety net. `auto_resolve` is
## seed-deterministic, so a fixed set of seeds is a reproducible microbenchmark.
## Two signals are produced per scenario:
##   - TIME: µs per combat (machine-dependent; compare runs on the SAME machine,
##     before/after a change). Informational, never a CI gate.
##   - LEAK: the change in `Performance.OBJECT_COUNT` across N freshly created +
##     dropped sessions, measured AFTER a warm-up so one-time caches don't count.
##     RefCounted frees eagerly at refcount 0, so a non-zero delta means engine
##     objects survived = a reference cycle. This IS a gate (exit code 1).
##
## The leak detector self-tests first: it builds a known reference cycle and
## asserts the detector sees it. If the self-test fails the detector is broken and
## the run aborts, so a green leak result can never be a false negative.
##
## Run:  godot --headless --path . --script addons/card_combat/benchmark/combat_benchmark.gd -- [runs]
## `runs` (optional, default 300) is the number of combats measured per scenario.

const DEFAULT_RUNS := 300

# Tolerance for the leak delta. 0 = strict: a single surviving engine object
# fails the gate. Kept at 0 because the warm-up absorbs one-time allocations.
const LEAK_TOLERANCE := 0


# A pair of these forms a reference cycle (a.ref -> b, b.ref -> a). Used only by
# the detector self-test, to prove OBJECT_COUNT catches a known leak.
class _CycleNode extends RefCounted:
	var ref: RefCounted = null


func _initialize() -> void:
	var runs: int = _parse_runs()
	print("=== Combat engine benchmark (runs/scenario=%d) ===" % runs)

	if not _selftest_leak_detector():
		push_error("benchmark: leak detector self-test FAILED — aborting")
		quit(2)
		return

	var any_leak: bool = false
	for scenario in _scenarios():
		var result: Dictionary = _bench(scenario["name"], scenario["build"], runs)
		_print_result(result)
		if result["leak_delta"] > LEAK_TOLERANCE:
			any_leak = true

	print("=== %s ===" % ("LEAK DETECTED — see scenarios above" if any_leak else "OK: no leaks"))
	quit(1 if any_leak else 0)


func _parse_runs() -> int:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() > 0 and args[0].is_valid_int():
		return maxi(1, args[0].to_int())
	return DEFAULT_RUNS


func _scenarios() -> Array:
	## Each scenario builds and fully resolves one combat for a given run index.
	## The seed is derived from the index so every run is reproducible and distinct.
	return [
		{"name": "1v1 DummyAI", "build": _run_1v1_dummy},
		{"name": "1v1 HeuristicAI", "build": _run_1v1_heuristic},
		{"name": "2v2 teams", "build": _run_2v2},
		{"name": "FFA 3 sides", "build": _run_ffa3},
		{"name": "1v1 abilities", "build": _run_1v1_abilities},
		{"name": "1v1 abilities QUEUED", "build": _run_1v1_abilities_queued},
		{"name": "1v1 DummyAI no-log", "build": _run_1v1_no_log},
	]


# --- Measurement -------------------------------------------------------------

func _bench(name: String, build: Callable, runs: int) -> Dictionary:
	## Warm up once (loads scripts, fills one-time caches), then measure time and
	## the object-count delta over `runs` fresh combats. The session built inside
	## `build` is local and dropped on return, so a clean engine nets delta 0.
	build.call(0)

	var leak_before: int = Performance.get_monitor(Performance.OBJECT_COUNT)
	var t0: int = Time.get_ticks_usec()
	for i in runs:
		build.call(i + 1)
	var elapsed: int = Time.get_ticks_usec() - t0
	var leak_after: int = Performance.get_monitor(Performance.OBJECT_COUNT)

	return {
		"name": name,
		"runs": runs,
		"total_usec": elapsed,
		"per_combat_usec": float(elapsed) / float(runs),
		"leak_delta": leak_after - leak_before,
	}


func _print_result(r: Dictionary) -> void:
	var leak_mark: String = "OK" if r["leak_delta"] <= LEAK_TOLERANCE else "LEAK(+%d)" % r["leak_delta"]
	print("  %-20s  %8.1f µs/combat  %7d µs total  leak=%s" % [
		r["name"], r["per_combat_usec"], r["total_usec"], leak_mark,
	])


func _selftest_leak_detector() -> bool:
	## Build a known reference cycle a fixed number of times and assert the
	## OBJECT_COUNT delta reflects it. Guards against a placebo detector (e.g. if a
	## future engine/runtime change made OBJECT_COUNT stop counting RefCounted).
	## The nodes are kept in `nodes` so the delta is measured while they are alive,
	## then the cycles are broken so the self-test itself leaves nothing behind.
	const PAIRS := 50
	var nodes: Array[RefCounted] = []
	var before: int = Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in PAIRS:
		var a := _CycleNode.new()
		var b := _CycleNode.new()
		a.ref = b
		b.ref = a
		nodes.append(a)
		nodes.append(b)
	var delta: int = Performance.get_monitor(Performance.OBJECT_COUNT) - before
	# Each pair adds 2 RefCounted; require most to be observed (exact in practice,
	# but stay robust to minor runtime bookkeeping).
	var ok: bool = delta >= PAIRS
	# Break every cycle so these nodes free now and the self-test leaks nothing.
	for n in nodes:
		(n as _CycleNode).ref = null
	nodes.clear()
	print("  [self-test] artificial cycle leak detected: +%d objects (%s)" % [delta, "ok" if ok else "FAIL"])
	return ok


# --- Scenarios (each runs one full combat for a seed derived from `i`) --------

func _run_1v1_dummy(i: int) -> void:
	var s := CombatSession.new()
	s.setup(_hero(), _deck(), _hero(), _deck(), i)
	s.auto_resolve()


func _run_1v1_heuristic(i: int) -> void:
	var s := CombatSession.new()
	# Inject a HeuristicAI on both sides before setup (setup only seeds empty slots).
	s.ais[0] = HeuristicAI.new()
	s.ais[1] = HeuristicAI.new()
	s.setup(_hero(), _deck(), _hero(), _deck(), i)
	s.auto_resolve()


func _run_2v2(i: int) -> void:
	var s := CombatSession.new()
	s.setup_sides(_sides(4), [0, 0, 1, 1], i)
	s.auto_resolve()


func _run_ffa3(i: int) -> void:
	var s := CombatSession.new()
	s.setup_sides(_sides(3), [], i)
	s.auto_resolve()


func _run_1v1_abilities(i: int) -> void:
	## Trigger-path coverage: every AbilityLibrary hook wired (ability_fn, taunt
	## restriction, armor, spell power, auras) over a deck carrying all 14 keywords,
	## so the per-trigger dispatch and the library<->session weakref graph are both
	## timed and leak-gated. INLINE dispatch (the default).
	var s := CombatSession.new()
	var lib := AbilityLibrary.new(s)
	lib.wire_all()
	s.setup(_hero(), _deck_abilities(), _hero(), _deck_abilities(), i)
	s.auto_resolve()


func _run_1v1_abilities_queued(i: int) -> void:
	## Same combat as "1v1 abilities" but with the deferred trigger queue, so the
	## QUEUED overhead (enqueue + drain at safe points) is measured against the
	## INLINE scenario directly. Set before setup(): the effective sink is computed there.
	var s := CombatSession.new()
	var lib := AbilityLibrary.new(s)
	lib.wire_all()
	s.trigger_mode = CombatSession.TriggerMode.QUEUED
	s.setup(_hero(), _deck_abilities(), _hero(), _deck_abilities(), i)
	s.auto_resolve()


func _run_1v1_no_log(i: int) -> void:
	## The balancing configuration: same combat as "1v1 DummyAI" with event_log
	## recording off, quantifying what config.record_events = false saves.
	var s := CombatSession.new()
	s.config.record_events = false
	s.setup(_hero(), _deck(), _hero(), _deck(), i)
	s.auto_resolve()


# --- Fixtures ----------------------------------------------------------------

func _sides(n: int) -> Array:
	var out: Array = []
	for _s in n:
		out.append({"hero": _hero(), "cards": _deck()})
	return out


func _hero(hp: int = 30) -> Combatant:
	var c := Combatant.new()
	c.display_name = "Hero"
	c.max_health = hp
	c.current_health = hp
	return c


func _deck() -> Array[CardData]:
	## A mixed deck: creatures across the curve plus one of each built-in spell
	## EffectType, so the benchmark exercises the whole spell-resolution path
	## (damage, AOE, buff, heal, summon), not just creature trades.
	var cards: Array[CardData] = []
	cards.append(_creature("grunt", 1, 2, 1))
	cards.append(_creature("scout", 1, 1, 2))
	cards.append(_creature("knight", 2, 2, 3))
	cards.append(_creature("ogre", 3, 4, 4))
	cards.append(_creature("golem", 4, 4, 6))
	cards.append(_spell("bolt", 1, SpellEffect.EffectType.DAMAGE, 3, SpellEffect.TargetType.ENEMY_HERO))
	cards.append(_spell("blast", 3, SpellEffect.EffectType.AOE_DAMAGE, 2, SpellEffect.TargetType.ENEMY_CREATURES))
	cards.append(_spell("rally", 2, SpellEffect.EffectType.BUFF_ATTACK, 1, SpellEffect.TargetType.PLAYER_CREATURES))
	cards.append(_spell("mend", 2, SpellEffect.EffectType.HEAL, 5, SpellEffect.TargetType.PLAYER_HERO))
	cards.append(_summon("call", 3, "Wolf", 2, 2, 2))
	return cards


func _deck_abilities() -> Array[CardData]:
	## The keyword counterpart of _deck(): a similar curve whose creatures spread all
	## 14 AbilityLibrary keywords, so the abilities scenarios exercise every wired hook
	## (per-trigger dispatch, TAUNT restriction + auto-play redirect, ARMOR interception,
	## SPELLPOWER, LORD auras) while the spell set keeps ON_CAST / SPELLBURST busy.
	var cards: Array[CardData] = []
	cards.append(_keyword_creature("grunt", 1, 2, 1, ["CHARGE", "BATTLECRY"]))
	cards.append(_keyword_creature("scout", 1, 1, 2, ["STEALTH", "SPELLBURST"]))
	cards.append(_keyword_creature("mystic", 2, 1, 3, ["SPELLPOWER", "IMMUNITY"], {"spell_power": 1}))
	cards.append(_keyword_creature("knight", 2, 2, 3, ["TAUNT", "ARMOR"], {"armor": 1}))
	cards.append(_keyword_creature("berserker", 3, 3, 2, ["WINDFURY", "FREEZE"]))
	cards.append(_keyword_creature("ogre", 3, 4, 4, ["LIFESTEAL", "OVERKILL"]))
	cards.append(_keyword_creature("golem", 4, 4, 6, ["LORD", "THORNS"]))
	cards.append(_spell("bolt", 1, SpellEffect.EffectType.DAMAGE, 3, SpellEffect.TargetType.ENEMY_HERO))
	cards.append(_spell("blast", 3, SpellEffect.EffectType.AOE_DAMAGE, 2, SpellEffect.TargetType.ENEMY_CREATURES))
	cards.append(_spell("rally", 2, SpellEffect.EffectType.BUFF_ATTACK, 1, SpellEffect.TargetType.PLAYER_CREATURES))
	cards.append(_spell("mend", 2, SpellEffect.EffectType.HEAL, 5, SpellEffect.TargetType.PLAYER_HERO))
	cards.append(_summon("call", 3, "Wolf", 2, 2, 2))
	return cards


func _keyword_creature(id: String, cost: int, attack: int, health: int, keywords: Array, extra: Dictionary = {}) -> CardData:
	## A _creature carrying AbilityLibrary keywords (plus their tunable metadata keys,
	## e.g. {"armor": 1}) in the opaque CardData.metadata the library reads.
	var c := _creature(id, cost, attack, health)
	var meta: Dictionary = {"keywords": keywords}
	meta.merge(extra)
	c.metadata = meta
	return c


func _creature(id: String, cost: int, attack: int, health: int) -> CardData:
	var c := CardData.new()
	c.card_id = id
	c.name = id
	c.cost = cost
	c.attack = attack
	c.health = health
	c.play_kind = CardData.PlayKind.UNIT
	return c


func _spell(id: String, cost: int, type: SpellEffect.EffectType, value: int, target: SpellEffect.TargetType) -> CardData:
	var c := CardData.new()
	c.card_id = id
	c.name = id
	c.cost = cost
	c.play_kind = CardData.PlayKind.EFFECT
	var e := SpellEffect.new()
	e.effect_type = type
	e.value = value
	e.target_type = target
	var effects: Array[SpellEffect] = [e]
	c.spell_effects = effects
	return c


func _summon(id: String, cost: int, unit_name: String, count: int, attack: int, health: int) -> CardData:
	var c := CardData.new()
	c.card_id = id
	c.name = id
	c.cost = cost
	c.play_kind = CardData.PlayKind.EFFECT
	var e := SpellEffect.new()
	e.effect_type = SpellEffect.EffectType.SUMMON
	e.target_type = SpellEffect.TargetType.SUMMON_BOARD
	e.summon_name = unit_name
	e.summon_count = count
	e.summon_attack = attack
	e.summon_health = health
	var effects: Array[SpellEffect] = [e]
	c.spell_effects = effects
	return c
