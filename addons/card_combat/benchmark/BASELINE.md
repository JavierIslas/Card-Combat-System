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
| OS | Linux 6.8.0-117-generic |
| Godot | 4.6.stable.official (89cea1439) |
| Date | 2026-06-04 |
| Commit | c6a541a |
| Command | `godot --headless --path . --script addons/card_combat/benchmark/combat_benchmark.gd -- 300` |

## Results (median of 3 runs, 300 combats/scenario)

| Scenario | µs/combat (median) | Observed spread |
|---|---|---|
| 1v1 DummyAI | 6258 | 6221–6265 (~0.7%) |
| 1v1 HeuristicAI | 6472 | 6387–6555 (~2.6%) |
| 2v2 teams | 12098 | 12022–12274 (~2.1%) |
| FFA 3 sides | 10136 | 9991–10181 (~1.9%) |

Inter-run variance stayed under ~3%, so a real regression should stand clearly
above the noise. Leak delta was 0 in every run; the detector self-test passed
(+100 objects for the artificial cycle).

## Regenerate

Re-run on the target machine and replace the Environment + Results tables:

```
godot --headless --path . --script addons/card_combat/benchmark/combat_benchmark.gd -- 300
```

Take the median of ~3 runs. Bump the Date/Commit so a future reader knows which
engine state the numbers describe.
