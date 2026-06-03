# Card Combat Engine — domain-agnostic card combat engine

Turn-based combat engine for a card game (creatures + spells, mana, draw,
attack/defense/block, damage resolution and AI). **It does not depend on the
concrete game**: it knows nothing about the GDD, rarities, specific abilities, or
`CardLoader`/`GameManager`. Everything game-specific is injected from the game
layer.

Same pattern and lifecycle as the `hex_strategy_map` addon: it lives in-repo
under `addons/`, registers itself via `class_name` (the `plugin.cfg` is for
packaging / future export) and can be mirrored to a standalone repo.

## Classes

| Class | Role |
|-------|------|
| `Combatant` | Generic participant: `current_health/max_health`, `take_damage`, `heal`, signals. Each side's hero is one of these (`heroes[side]`) |
| `CardData` | Card core (id/cost/stats/type) + opaque `metadata: Dictionary` for game-specific fields |
| `CardInstance` | Card in play (turn state, health, flags). Fires ability triggers via `ability_fn` |
| `CombatCommand` | Serializable driver intention (input); fed to `CombatSession.apply_command` and accumulated in `command_log` |
| `HiddenCardStats` | Declared vs. hidden stats for bluffing |
| `CombatDeck` | Hand, deck, board, graveyard and mana for one side, plus game-defined extra zones |
| `CombatSession` | Combat FSM over N sides grouped by `teams`: orchestrates turns, decks, AI and resolution |
| `CombatState` | Phase enum |
| `CombatPair` | Declared attacker/defender pair |
| `CombatDamageResolver` | Resolves damage for the combat pairs |
| `SpellEffect` | Spell effect (damage/heal/summon) |
| `CombatConfig` | Balance parameters (mana, cap, starting hand, board/hand limits, permanent-buff cap) |
| `CombatAI` | Base AI contract: defines the 5 signatures; subclass for a custom AI |
| `DummyAI` | Reference/default AI (random, optional seed); `extends CombatAI` |
| `HeuristicAI` | Optional stronger AI (greedy, deterministic): curve-filling plays, value trades, threat blocking; `extends CombatAI`. Inject via `ais[side]`; DummyAI stays the default |

## Injection points (how the game layer specializes it)

1. **`CombatSession.ability_fn: Callable`** — ability semantics. Empty = pure
   engine. The game injects its `AbilityHandler`. It is propagated to the
   `CardInstance`s via `CombatDeck.setup(..., ability_fn)`. **Signature (v2):**
   `(inst: CardInstance, trigger: int, context: Dictionary)`. The handler reacts to
   the lifecycle triggers in `CardInstance.Trigger`:
   `ON_SETUP, ON_TURN_REFRESH, ON_DEATH, ON_REVEAL, ON_ATTACK, ON_BLOCK,
   ON_DAMAGE_TAKEN, ON_DAMAGE_DEALT, ON_HEAL, ON_TURN_START, ON_TURN_END, ON_DRAW`.
   `context` carries trigger-specific primitives (e.g. `{"amount": n}` for
   `ON_DAMAGE_TAKEN`, `{"target": inst}` for `ON_ATTACK`), `{}` when there is none.
   `inst` is `null` for the side-level `ON_DRAW` (the drawn card travels in
   `context["card"]`), so a handler must tolerate `inst == null`.
   > **Breaking change since 1.x:** the handler took `(inst, trigger)`; it now takes
   > a third `context` argument. Update existing handlers accordingly.
2. **`SpellEffect.id_fn: Callable`** — resolves the id of a summoned creature
   (`id_fn.call(summon_name, index, summon_count)`). Empty = no summoning that
   depends on the game catalog.
3. **`CombatSession.config: CombatConfig`** — reassign before `setup()` to
   change balance without touching the engine. Includes
   `max_permanent_buffs_per_card` (cap of permanent buffs per card;
   `-1` = unlimited), `max_board_size` (creatures allowed on a side's board;
   `-1` = unlimited; a full board rejects `play_creature` and drops extra summons)
   and `max_hand_size` (cards held in hand; `-1` = unlimited; an overdraw burns the
   drawn card to the graveyard, see `discard_fn`). The engine knows no rules like
   "+1/+1 cap 3": the game sets the caps here and applies whatever delta it wants
   with `apply_permanent_buff`.
4. **`Combatant`** — the game passes its hero (subclass) and builds the enemy
   `Combatant` from its own templates.
5. **`CombatSession.damage_fn: Callable`** — damage formula, seeded into the
   resolver on `setup()`. Signature: `(attacker, defender) -> int`. Empty = engine
   default (attacker's attack, floored at 1; ignores the defender). Inject it to
   factor in the defender, e.g. armor:
   ```gdscript
   session.damage_fn = func(attacker, defender):
       return maxi(attacker.current_attack - defender.card_data.metadata.get("armor", 0), 0)
   ```
6. **`CombatSession.exhaust_fn: Callable`** — fatigue hook, seeded into both decks
   on `setup()`. Signature: `(owner_id: int)`. Called when a draw fails on an empty
   deck. Empty = the deck only emits `deck_exhausted` (default). Inject it to burn
   the hero on fatigue:
   ```gdscript
   session.exhaust_fn = func(owner_id):
       session.heroes[owner_id].take_damage(1)
   ```
7. **`SpellEffect.effect_fn: Callable`** — full override of effect resolution, for
   effect types outside the engine's `EffectType` catalog. Signature:
   `(effect: SpellEffect, target, context) -> Dictionary`. When set, it replaces
   the built-in `match`; empty = engine default. Lets the game add custom spells
   without editing the engine:
   ```gdscript
   var drain := SpellEffect.new()
   drain.effect_fn = func(effect, target, context):
       # game-defined semantics, reading effect.value / context as needed
       return {"success": true, "drained": effect.value}
   ```
8. **`CombatSession.discard_fn: Callable`** — overdraw hook, seeded into both decks
   on `setup()`. Signature: `(card: CardData, owner_id: int)`. Called when a card is
   drawn with a full hand (`config.max_hand_size`) and burned to the graveyard.
   Empty = the card is burned silently.

### Permanent buffs (generic)

`CardInstance.apply_permanent_buff(attack_delta, health_delta, max_buffs := -1)`
applies a permanent stat buff. The delta is decided by the game layer; the cap
comes from `max_buffs` (one-off override) or from `max_permanent_buffs` (seeded
from `CombatConfig`). It also raises `current_max_health`, which is the cap
respected by `heal()`. For "+1/+1 with cap 3", the game sets
`config.max_permanent_buffs_per_card = 3` and calls `inst.apply_permanent_buff(1, 1)`.

### Extra card zones (generic)

Beyond the four core zones (draw pile, hand, board, graveyard), the game can
keep any number of its own zones — an *exile* pile, an *extra deck*, a *banished*
stack — without touching the engine. Zones are keyed by an opaque string the
engine never interprets, mirroring `CardData.metadata`:

```gdscript
deck.add_to_zone("exile", card)        # creates the zone on first use
deck.get_zone("exile")                 # live Array[CardData]; [] if absent
deck.remove_from_zone("exile", card)   # false if the zone or card is absent
deck.zone_names()                      # names of the zones in use
```

Extra zones are part of `serialize()`/`deserialize()`, so they survive
save/resume. Moving a card across zones is the game's job (the engine has no
rules about what exile or an extra deck *mean*).

## Turn model (N sides + teams, symmetric, PvP-ready)

The combat is **symmetric per side** and supports any number of sides: there is
no built-in "player vs enemy". Each turn one side is **active** (takes its turn
and attacks) and every other side is **passive** (can declare blockers). The
engine is agnostic to who drives each side — human UI, AI, or a network peer —
which is what makes it PvP-ready. `turn_number` counts side turns.

Sides are grouped by `teams: Array[int]` indexed by side (same id = allies):

- 1v1 (default) → `[0, 1]`, behaves exactly like the classic two-side model.
- FFA → `[0, 1, 2, 3]` (each side its own team).
- 2v2 → `[0, 0, 1, 1]`.

"Enemy" / "ally" are resolved by team (`enemies_of(side)` / `allies_of(side)` —
allies **include** the side itself), so an `ENEMY_CREATURES` AoE hits every enemy
team's board and `PLAYER_CREATURES` covers the caster and its teammates. Turn
order is **interleaved by team** (round-robin), so teammates don't act back to
back; dead sides are skipped. The combat ends when one team is left standing:
`winner_team` names it, and `winner_side` reports a representative living side of
that team (so 1v1 keeps returning `0`/`1`). Both are `-1` for no winner.

FSM per side turn:
`PREPARATION → MAIN → ATTACK → DEFENSE → RESOLVE → (next living side) → …`

| Phase | Driven by | What |
|-------|-----------|------|
| `PREPARATION` | active | only the active side ramps mana, draws and refreshes |
| `MAIN` | active | `play_card` |
| `ATTACK` | active | `declare_attacker(attacker, target?, target_side?)` (target = an enemy creature; null swings at a hero, `target_side` picks which enemy hero) |
| `DEFENSE` | **passive** | `declare_blocker(attacker, blocker)` — any enemy side's defender redirects that attack to itself |
| `RESOLVE` | engine | resolves the active side's attacks, then hands the turn to the next living side |

State is indexed by side: `heroes[]`, `decks[]`, `ais[]`, `teams[]`,
`active_side`, `winner_side` / `winner_team` (`-1` = no winner). Assign
`ais[side]` before setup to inject a controller for a side; otherwise setup seeds
a reference `DummyAI`.

`setup(side0_hero, side0_cards, side1_hero, side1_cards, seed)` is the 1v1
convenience wrapper. For N sides use
`setup_sides(sides, teams, seed)` where each entry of `sides` is
`{"hero": Combatant, "cards": Array[CardData]}` (empty `teams` = free-for-all).

## Minimal wiring

```gdscript
var session := CombatSession.new()
session.ability_fn = my_ability_handler   # optional
session.config.starting_max_mana = 2      # optional
session.ais[0] = my_player_ai             # optional; else a seeded DummyAI
session.setup(side0_hero, side0_cards, side1_hero, side1_cards, seed)
session.start()                           # or session.auto_resolve() to run headless
```

### Casting single-target spells

A spell with a `PLAYER_CREATURE` effect needs an explicit, living target. Pass it
as the last argument of `play_card`:

```gdscript
var ok := session.play_card(spell, false, 0, 0, chosen_creature)
```

If no valid target is given, the spell **fizzles**: it is not consumed (mana and
card stay in hand), `play_card` returns `false`, and the session emits
`spell_fizzled(card)`. GDScript has no exceptions, so the contract is expressed
through the return value plus the signal — the caller (UI or AI) reacts by
prompting for a target and retrying, instead of wasting the card.

For an `ENEMY_HERO` spell in FFA / team games, pass `target_side` (the last
argument of `play_card`) to pick which enemy hero is hit; `-1` (default) resolves
to the first living enemy side. A `target_side` pointing at an ally is rejected and
falls back to that default, so a hero spell can never hit a teammate. In 1v1 the
default keeps hitting the lone opponent, unchanged.

### Targeting limits (non-goals)

Spell targeting is intentionally minimal and caster-relative. `TargetType`
resolves everything from the caster's point of view (`ENEMY_HERO`, `PLAYER_HERO`,
`PLAYER_CREATURE`, `ENEMY_CREATURES`, `PLAYER_CREATURES`, `SUMMON_BOARD`) — now
team-aware, so the "enemy"/"ally" sets span every enemy/allied side — and a
spell has a **single** explicit single-target slot (`PLAYER_CREATURE`). The engine
does **not** provide multi-target "choose N" or split targets — those are game
rules, not engine primitives. A game that needs
richer targeting expresses it through an injected `effect_fn` (full control over
resolution) rather than by extending the built-in `TargetType` catalog.

## AI

The AI contract lives in the base class `CombatAI`, which defines five
signatures: `choose_card_to_play`, `choose_attackers`, `choose_attack_target`,
`choose_spell_target`, `choose_blockers`. Its stubs return empty and emit
`push_error`, so an incomplete subclass fails loudly. `DummyAI extends CombatAI`
is the default AI and the reference example. For a stronger AI, subclass
`CombatAI` and override those methods. It operates only on `CardData` and
`CardInstance`. Both the attacking (`choose_attackers`/`choose_attack_target`)
and defending (`choose_blockers`) sides go through this same contract — an AI is
just a driver for whichever side(s) you assign it to via `ais[side]`.

The attack-step methods receive the **enemy heroes as an array** (one per living
enemy side) so an AI can reason about lethal across sides:
`choose_attackers(board, enemy_heroes)` and `choose_attack_target(attacker,
enemy_board, enemy_heroes)`, where `enemy_board` is the combined enemy creatures
(each carries its `owner_id`). `enemy_heroes` may be empty in board-only
scenarios. `choose_attack_target` returns an enemy creature, or `null` to swing at
a hero — the engine routes a null hit to the first living enemy side.
`HeuristicAI` measures lethal against the first living enemy hero. A custom AI
subclassing `CombatAI` must use the `enemy_heroes: Array[Combatant]` parameter in
these two overrides (breaking change from the old single `enemy_hero`).

`choose_spell_target(spell, own_board, enemy_board)` is consulted by `auto_resolve`
when the AI plays a single-target spell (`PLAYER_CREATURE`): both boards are
passed because the engine is agnostic about which side a spell hits — inspect
`spell.spell_effects` to decide (a DAMAGE wants an enemy, a BUFF an ally). If it
returns no living target, the spell is skipped (not consumed) for that turn.

## Observability (signals + event_log)

The engine exposes its state two ways: live **signals** (below), and a structured
**`CombatSession.event_log: Array[CombatEvent]`** that mirrors the signals as a
replay-friendly stream. Each `CombatEvent` has a `type` (`PHASE_CHANGED`,
`COMBATANT_DAMAGED`, `COMBATANT_HEALED`, `CREATURE_DIED`, `CREATURE_SUMMONED`,
`COMBAT_ENDED`, `SPELL_FIZZLED`, plus the card-level `CARD_DRAWN`, `CARD_PLAYED`,
`MANA_CHANGED`, `MAX_MANA_CHANGED`, `DECK_EXHAUSTED`) and a
serializable `payload`; `event.serialize()` round-trips it (e.g. `creature_died`
logs `{owner, card_id}`, not the live instance). The log is cleared on `setup()`
(initial-hand draws are logged). The session mirrors the per-side deck signals
into the log, so the log **alone** is a full replay/spectator stream; the deck
signals stay intact for live listeners. Consume the log when you want the whole
run as data; use the signals when you want live object references.

Signal catalog per class:

| Class | Signal | When |
|-------|--------|------|
| `CombatSession` | `phase_changed(old, new)` | every FSM transition |
| `CombatSession` | `combat_ended(winner_side)` | on entering `END` (`-1` = no winner) |
| `CombatSession` | `creature_died(card, owner)` | a creature dies, whether in combat or by a spell (AOE/single-target) |
| `CombatSession` | `creature_summoned(card, owner)` | a creature enters the board via a SUMMON spell (not a hand play) |
| `CombatSession` | `combatant_damaged(side, amount)` | the hero of `side` takes damage |
| `CombatSession` | `combatant_healed(side, amount)` | the hero of `side` is healed (actual amount restored) |
| `CombatSession` | `spell_fizzled(card)` | a single-target spell was cast with no valid target (not consumed) |
| `CombatDeck` | `card_drawn(card)` | a card is drawn from the deck |
| `CombatDeck` | `deck_exhausted` | failed draw on empty deck (see `exhaust_fn` hook) |
| `CombatDeck` | `card_played(instance)` | a creature enters the board |
| `CombatDeck` | `mana_changed(new_mana)` | available mana changes |
| `CombatDeck` | `max_mana_changed(new_max)` | the maximum mana ramps up (new crystal) |
| `CardInstance` | `card_died(card)` | the instance dies |
| `CardInstance` | `card_damaged(card, amount)` | the instance takes damage |
| `CardInstance` | `card_revealed(card)` | a hidden card is revealed |
| `Combatant` | `health_changed(new_health)` | the participant's health changes |
| `Combatant` | `died` | health reaches 0 |

### Serialization / save-resume

Beyond seed-based replay, the engine can snapshot live state for save/resume or
authoritative networking: `CombatSession.serialize() -> Dictionary` captures the
full graph (phase, sides, heroes, decks, board instances with buffs/hidden stats,
the `event_log`, dead creatures, and the in-flight attack pairs/blockers by board
index). `CombatSession.deserialize(data, hooks)` rebuilds it. The non-serializable
pieces are re-injected through `hooks`:

```gdscript
var data := session.serialize()           # persist this Dictionary
# ... later ...
var resumed := CombatSession.deserialize(data, {
    "config": my_config,                  # else a default CombatConfig
    "ability_fn": my_ability_handler,     # re-wired into every CardInstance
    "damage_fn": my_damage_fn,
    "exhaust_fn": my_exhaust_fn,
    "discard_fn": my_discard_fn,
    "heroes": [my_hero0, my_hero1],       # optional: a game's subclassed heroes
    "ais": [ai0, ai1],                    # optional: deterministic resume
})
```

`CardData`/`SpellEffect` round-trip the built-in `EffectType` data; spells that
rely on an injected `effect_fn`/`id_fn` must be re-hydrated by the game (by
`card_id`), same as the other Callables. Deserializing a `CardInstance` rebuilds
its state directly **without** firing `ON_SETUP`, so resuming never re-applies
on-play effects.

### History / replay

The engine is deterministic for a fixed seed. `CombatSession.setup(..., ai_seed)`
seeds both deck shuffles and, for any side without an injected AI, a reference
`DummyAI` (one per side, derived from `ai_seed`). With the seed and the starting
cards fixed, the same inputs reproduce the same match bit-for-bit — including a
byte-identical serialized `event_log`. Two ways to use this: persist just the seed
(and the starting cards) and re-run the combat to rebuild the history, or capture
`event_log` (via `serialize()`) as the recorded run directly. Either way the
engine stores no extra state of its own.

## Command layer (authoritative input / replay-from-input)

Where `event_log` records what the combat **did** (output), `command_log` records
what a driver **asked for** (input). `CombatSession.apply_command(cmd)` validates a
`CombatCommand` and routes it to the matching action method (`play_card`,
`declare_attacker`, `declare_blocker`, `end_*_phase`, `advance`); it returns `false`
without mutating when a precondition fails, and on success appends the command to
`command_log`. This gives an authoritative server a single validated entry point for
client input, and lets a match be replayed from input alone. `command_log`
round-trips with the session via `serialize()`/`deserialize()`.

```gdscript
var cmd := CombatCommand.new(CombatCommand.CommandType.PLAY_CARD, side, {
    "hand_index": 0,
    # single-target spells: encode the target creature by side + board index
    "target_side": 1, "target_index": 2,
    # ENEMY_HERO spells: which enemy hero to hit (-1 = first living enemy)
    "hero_target_side": 1,
})
if session.apply_command(cmd):
    ...  # accepted; mirrored into command_log
```

Cards and creatures are referenced by index (hand index, board index per side), the
same primitive encoding the session uses for attack pairs, so commands stay
serializable. `CommandType`: `PLAY_CARD, DECLARE_ATTACKER, DECLARE_BLOCKER,
END_MAIN, END_ATTACK, END_DEFENSE, ADVANCE`.

## What does NOT live here (game layer)

- `CardLoader` / JSON parsing, rarities (`CardRarity`), abilities.
- `AbilityHandler` (concrete semantics of CHARGE/IMMUNITY/…), `EnemyData`.
- `CombatSerializer` / `BoardState`: the **game's PvP serialization** (they
  depend on `PlayerData` and its specific state — mana, reputation, sacrifice).
  These are game scaffolding, not engine scaffolding; that is why they stay in
  the game layer.

## License

Card Combat Engine is **dual-licensed**:

- **GNU AGPL v3.0** (default, see `LICENSE`) — free for open-source use. Note the
  AGPL is copyleft over a network: if you run the engine server-side as part of a
  product, you must release that product's source under the AGPL too.
- **Commercial license** (see `LICENSE_COMMERCIAL.md`) — exempts you from the AGPL
  obligations for use in closed-source projects, including server-side play.

For a commercial license: **islasjavieralf@gmail.com**.
