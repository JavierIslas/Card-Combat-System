# Benchmark baseline — Combat engine

Reference numbers for `combat_benchmark.gd`, to compare a refactor of
`CombatSession` against. Run the manifest `benchmark` command (or the command
below) before and after a change.

## How to read this

- **LEAK is the portable gate.** Every scenario must report `leak=OK` (engine
  `OBJECT_COUNT` delta 0). This is machine-independent: a non-zero delta is a
  reference cycle and fails the run (exit 1), on any hardware. The numbers below
  are not needed to use the leak gate.
- **TIME is hardware-specific and only comparable on the SAME machine.** The
  µs/combat figures below were taken on the machine in "Environment". Do **not**
  compare against them from a different CPU — regenerate the baseline instead
  (see "Regenerate"). On the same machine, treat a sustained **> ~10%** rise over
  the median as a regression worth investigating.

## Environment

| | |
|---|---|
| CPU | 11th Gen Intel Core i5-1135G7 @ 2.40GHz (8 threads) |
| OS | Linux 6.8.0-124-generic |
| Godot | 4.6.stable.official (89cea1439) |
| Date | 2026-06-10 |
| Commit | a88e445 |
| Command | `godot --headless --path . --script addons/card_combat/benchmark/combat_benchmark.gd -- 300` |

## Results (median of 3 runs, 300 combats/scenario)

| Scenario | µs/combat (median) | Observed spread |
|---|---|---|
| 1v1 DummyAI | 2257 | 2254–2259 (~0.2%) |
| 1v1 HeuristicAI | 2359 | 2346–2368 (~1.0%) |
| 2v2 teams | 4291 | 4285–4328 (~1.0%) |
| FFA 3 sides | 3616 | 3609–3618 (~0.2%) |
| 1v1 abilities | 4328 | 4326–4475 (~3.4%) |
| 1v1 abilities QUEUED | 4959 | 4794–5042 (~5.0%) |
| 1v1 DummyAI no-log | 1617 | 1611–1777 (~10.2%) |

Leak delta was 0 in every scenario of every run; the detector self-test passed
(+100 objects for the artificial cycle). Zero engine errors (the previous
"Stack underflow" storm in the abilities scenario was a real engine-code bug —
an infinite mutual-THORNS reflect chain — fixed in commit a88e445 and guarded
by `test_thorns_mutuo_entre_moribundas_no_recursiona`).

### What each group covers

- **The four historical scenarios** (DummyAI / HeuristicAI / 2v2 / FFA-3) run the
  agnostic engine with no hooks: FSM, mana, draw, combat resolution, built-in
  spells, multi-side topology. Note: they are ~2.7x faster than the 2026-06-04
  baseline (commit c6a541a) because the engine optimization batch merged after
  that baseline (8473fb4) landed in between — the old numbers were stale, not
  the machine different.
- **1v1 abilities** wires the full `AbilityLibrary` (`wire_all()`: ability_fn +
  taunt restriction + armor + spell power + auras) over decks carrying all 14
  keywords, so the per-trigger dispatch path, the auto-play TAUNT redirect and
  the library↔session weakref graph are timed and leak-gated. INLINE dispatch.
- **1v1 abilities QUEUED** is the same build with `trigger_mode = QUEUED`,
  covering the deferred-trigger queue (enqueue + drain). Caveat: INLINE and
  QUEUED resolve chained reactions in a different order, so the two scenarios
  play *different matches* from the same seeds — the ~15% delta is indicative of
  queue overhead, not a same-match A/B.
- **1v1 DummyAI no-log** is the historical DummyAI scenario with
  `config.record_events = false`: the measured ~28% saving quantifies the
  event-log recording cost for mass balancing runs.

## Regenerate

Re-run on the target machine and replace the Environment + Results tables:

```
godot --headless --path . --script addons/card_combat/benchmark/combat_benchmark.gd -- 300
```

Take the median of ~3 runs. Bump the Date/Commit so a future reader knows which
engine state the numbers describe.
