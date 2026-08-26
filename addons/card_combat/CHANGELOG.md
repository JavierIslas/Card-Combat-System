# Changelog

## 1.1.0 — 2026-08-26

### Added

- **`TickCombatSession`** (`tick_combat_session.gd`, `extends CombatSession`): the
  opt-in **tick paradigm** for automated combat — no alternating turns, no player
  phase. Each tick every *ready* side independently selects one card/action
  (a `null` choice from the AI means "swing with creatures"), card plays resolve
  in side order, and **every declared attack from every side resolves in one
  simultaneous damage batch** (mutual trades across sides, overkill and reflects
  compute before anything applies; both heroes falling in the same tick is a
  draw). Non-AI drivers override a side's next selection via
  `declare_tick_intent(side, card?, target?, target_side?)`.
  - `run_tick()` / `run_until_end(max_ticks)` drive the loop; `ready_sides()` /
    `recovery_remaining(side)` expose readiness.
  - `recovery_fn: Callable` — `(card, owner_id) -> int` ticks a side waits after
    playing a card. Recovery gates the side's **actions**, not its economy, and
    skips exactly N ticks. Empty = none (opt-in, like `cost_fn`); the engine
    never reads what "recovery" means in the game's rules.
  - Per-tick economy knobs: `mana_refill_per_tick`, `mana_ramp_per_tick`,
    `cards_drawn_per_tick` (defaults mirror the per-turn economy).
  - Save/resume: `serialize()` adds `"mode": "tick"` + a `tick` sub-dict on top
    of the base snapshot (`schema_version` unchanged). Saves/resume is
    deterministic (a resumed run continues identically). Re-inject `recovery_fn`
    through the `deserialize` hooks.
- **`CombatEvent.EventType.TICK`** (appended last; payload `{"tick": n}`) plus the
  `tick_ended(tick_number)` signal — the `event_log` alone delimits ticks for
  replay/UI.
- `CombatSession.deserialize` now delegates to an instance-level
  `_restore_from(data, hooks)` (behavior identical) — subclass factories reuse the
  whole restore orchestration.
- Benchmark scenario "1v1 tick DummyAI" (time + leak coverage of the tick loop).

### Compatibility

**Backward compatible** for code and saves written against 1.0: no public
signature changed, the sequential path is byte-identical (418 pre-existing tests
green, benchmark unchanged), old saves load unchanged, and `TICK` was appended to
the end of the event enum (events serialize by name; existing values unshifted).
`TickCombatSession.deserialize` refuses non-tick saves (warning + `null`); the
base `CombatSession.deserialize` loads a tick save by ignoring the tick keys;
`TickCombatSession.deserialize_any(data, hooks)` dispatches by `mode`.

One theoretical edge: if your own code serialized a `CombatEvent.type` as a **raw
int** (the engine never does — it serializes by name), a pre-1.1 binary would not
recognize `TICK` in such a hand-rolled save.

### Also in this version

Includes the additive engine APIs merged to main after the initial public
release under an un-bumped 1.0.0 — the Category B hooks (`incoming_damage_fn`,
`cost_fn`, `spell_power_fn`, `aura_fn`, `draw_for`, `add_mana`,
`choose_play_target`), `ON_PLAY`/`ON_CAST` triggers, `attacks_per_turn` /
`frozen_turns`, `config.record_events`, the `action_rejected` signal,
`CombatDeck.discard_card`, the expanded `AbilityLibrary` (14 keywords) and the
integration guide / tutorial / llms.txt docs.

## 1.0.0 — 2026-06-10

Initial public release: turn-based combat FSM over N sides + teams, decks/hand/
graveyard + extra zones, mana, spell effects and targeting, simultaneous combat
damage resolution, triggers (INLINE/QUEUED), pluggable AI contract, event log +
command log, save/resume, benchmark with leak gate.
