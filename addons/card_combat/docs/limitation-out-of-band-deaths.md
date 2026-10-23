# Known limitation: out-of-band mutations are not settled

*Reported from the integrating game (Espíritus Ancestrales) during a playtest,
Oct 2026. Anchored against `card_combat` @ `f3bff27`; line numbers below are
approximate and may drift — function names are the stable reference.*

## Summary

The engine settles creature deaths and combat victory only inside its own
resolution cycles: a resolved attack batch, an applied spell effect, a
reactive-trigger settle, or a phase transition. A game layer that mutates
state through public entry points **outside** those cycles — for example a
bluff/challenge reveal that applies a `-2/-2` penalty via
`CardInstance.apply_permanent_buff()` — observes two artifacts:

1. **Zombie creature.** The instance flips `is_dead` (its own `ON_DEATH`
   trigger and instance-level `card_died` signal fire from
   `CardInstance._die()`), but it stays in `CombatDeck.get_board()` until
   the next engine-owned sweep removes it — potentially several phases later.
   Session-level bookkeeping misses the death entirely:
   - no `CombatSession.creature_died` emission,
   - no `CREATURE_DIED` entry in the event log (replay gap),
   - `CombatSession.get_dead_creatures(side)` does not include it, which
     breaks game-layer consumers that derive consequences from it (e.g. a
     permadeath rule that destroys the player's creatures that died in
     combat lets this one survive).

2. **Deferred victory.** `CombatSession.deal_damage_to_hero()` is public and
   event-logged, but it does not check victory. A hero reduced to 0 outside
   the engine's cycles keeps the combat running until the next phase
   boundary calls `_check_victory()` (`end_attack_phase()` /
   `_enter_resolve()`). In a supervised demo this reads as a bug: the enemy
   hero sits at 0 HP while the turn keeps going.

Both behaviors are consistent with the engine's determinism contract
(victory settles at phase boundaries; every observable mutation travels
through the event log). This document describes the integration gap, not a
defect in the sweep paths themselves.

## Root cause

- Deaths are recorded and removed only by the private `_record_death()` /
  `_sweep_all_boards()` pair, which is called from exactly three places:
  - `_process_death_results()` — after a resolved attack batch,
  - `_apply_effect_and_sweep()` — after spell effects apply,
  - `_settle_reactive_triggers()` — after reactive triggers drain.
- There is **no public settle entry point**: a game layer holding a live
  `CombatSession` cannot ask the engine to sweep outstanding deaths.
- `_check_victory()` runs only from `end_attack_phase()` and
  `_enter_resolve()`. This is deliberate — see the comment in
  `end_attack_phase()`: *"A spell in MAIN may have already killed a hero:
  settle victory first."* — and it is what keeps lockstep/replay
  deterministic.
- `CardInstance._die()` fires the instance-level `ON_DEATH` / `card_died`
  no matter who caused the death. That is why the instance *looks* dead to
  the game layer while the board still lists it: the per-instance half of
  the death contract runs, the session-level half does not.

Public mutation entry points that can produce an unsettled state today:

| Entry point | Effect | Settled by the engine? |
| --- | --- | --- |
| `CardInstance.apply_permanent_buff(-n, -m)` | can kill (`_check_death_from_stat_change`) | no — zombie until next sweep |
| `CardInstance.take_damage(n)` | can kill | no — zombie until next sweep |
| `CombatSession.deal_damage_to_hero(side, n)` | hero damage, event-logged | damage yes; victory only at next phase boundary |
| `CardInstance.reveal()` | stat restoration (cannot kill by itself) | n/a |

## Minimal reproduction

```gdscript
# 1v1 wired session, started, side 0 in MAIN.
# A hidden creature sits on side 1's board (declared 8/8, really 1/1).
var inst: CardInstance = session.decks[1].get_board()[0]

inst.reveal()                        # public — restores real stats
inst.apply_permanent_buff(-2, -2)    # public — health 1 - 2 <= 0 → _die()

assert(inst.is_dead)                                # passes
assert(session.decks[1].get_board().has(inst))      # passes — zombie on board
assert(not session.get_dead_creatures(1).has(inst)) # passes — unrecorded death

session.deal_damage_to_hero(1, 99)   # enemy hero → 0, event-logged
assert(not session.combat_ended ...) # combat still running until the next
                                     # end_attack_phase() / _enter_resolve()
```

## Options considered (not implemented — decision deferred)

- **A. Public `settle_deaths()` (recommended next time the engine is
  touched).** A public method that runs the existing private sweep
  (`_sweep_all_boards()` + `recompute_auras()` when anything died), so game
  layers that mutate out of band can restore the invariant in one call:
  record + remove + emit, exactly like a spell death. Optionally pair it
  with a public `settle_victory()` (= `_check_victory()`) for drivers that
  want an immediate, event-logged ending instead of waiting for the phase
  boundary. Both preserve determinism because the caller decides *when*,
  the engine still decides *how*.
- **B. Clamp at the game layer (no engine change).** Out-of-band stat
  penalties never reduce health below 1, so an out-of-band death cannot
  occur. Zero engine risk, at the cost of softening the game's intended
  consequence.
- **C. Hybrid patch (not recommended).** The game layer removes the instance
  with `CombatDeck.remove_from_board()` and appends it to the private
  `session._dead_creatures` itself. Works today, silently breaks if the
  internals move.

The integrating game chose to document the limitation and leave the runtime
behavior unchanged for now.
