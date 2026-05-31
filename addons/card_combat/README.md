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
| `Combatant` | Generic participant: `current_health/max_health`, `take_damage`, `heal`, signals. The player hero extends it; the enemy is instantiated directly |
| `CardData` | Card core (id/cost/stats/type) + opaque `metadata: Dictionary` for game-specific fields |
| `CardInstance` | Card in play (turn state, health, flags). Fires ability triggers via `ability_fn` |
| `HiddenCardStats` | Declared vs. hidden stats for bluffing |
| `CombatDeck` | Hand, deck, board and mana for one side |
| `CombatSession` | Combat FSM: orchestrates turns, decks, AI and resolution |
| `CombatState` | Phase enum |
| `CombatPair` | Declared attacker/defender pair |
| `CombatDamageResolver` | Resolves damage for the combat pairs |
| `SpellEffect` | Spell effect (damage/heal/summon) |
| `CombatConfig` | Balance parameters (mana, cap, starting hand, board limit) |
| `CombatAI` | Base AI contract: defines the 4 signatures; subclass for a custom AI |
| `DummyAI` | Reference/default AI (random, optional seed); `extends CombatAI` |

## Injection points (how the game layer specializes it)

1. **`CombatSession.ability_fn: Callable`** — ability semantics. Empty = pure
   engine. The game injects its `AbilityHandler`. It is propagated to the
   `CardInstance`s via `CombatDeck.setup(..., ability_fn)`.
2. **`SpellEffect.id_fn: Callable`** — resolves the id of a summoned creature
   (`id_fn.call(summon_name, index, summon_count)`). Empty = no summoning that
   depends on the game catalog.
3. **`CombatSession.config: CombatConfig`** — reassign before `setup()` to
   change balance without touching the engine. Includes
   `max_permanent_buffs_per_card` (cap of permanent buffs per card;
   `-1` = unlimited). The engine knows no rules like "+1/+1 cap 3": the game
   sets the cap here and applies whatever delta it wants with
   `apply_permanent_buff`.
4. **`Combatant`** — the game passes its hero (subclass) and builds the enemy
   `Combatant` from its own templates.

### Permanent buffs (generic)

`CardInstance.apply_permanent_buff(attack_delta, health_delta, max_buffs := -1)`
applies a permanent stat buff. The delta is decided by the game layer; the cap
comes from `max_buffs` (one-off override) or from `max_permanent_buffs` (seeded
from `CombatConfig`). It also raises `current_max_health`, which is the cap
respected by `heal()`. For "+1/+1 with cap 3", the game sets
`config.max_permanent_buffs_per_card = 3` and calls `inst.apply_permanent_buff(1, 1)`.

## Minimal wiring

```gdscript
var session := CombatSession.new()
session.ability_fn = my_ability_handler   # optional
session.config.starting_max_mana = 2      # optional
session.setup(hero, hero_cards, enemy, enemy_cards)
session.start()
```

## AI

The AI contract lives in the base class `CombatAI`, which defines the four
signatures: `choose_card_to_play`, `choose_attackers`, `choose_attack_target`,
`choose_blockers`. Its stubs return empty and emit `push_error`, so an
incomplete subclass fails loudly. `DummyAI extends CombatAI` is the default AI
and the reference example. For a stronger AI, subclass `CombatAI` and override
those methods. It operates only on `CardData` and `CardInstance`.

## Observability (signals)

The engine keeps no log of its own: it exposes its state via signals and the
game layer decides what to record. Catalog per class:

| Class | Signal | When |
|-------|--------|------|
| `CombatSession` | `phase_changed(old, new)` | every FSM transition |
| `CombatSession` | `combat_ended(player_won)` | on entering `FINAL` |
| `CombatSession` | `creature_died(card, owner)` | a creature dies resolving combat |
| `CombatSession` | `hero_damaged(amount)` | the player hero takes damage |
| `CombatSession` | `enemy_damaged(amount)` | the enemy hero takes damage |
| `CombatDeck` | `card_drawn(card)` | a card is drawn from the deck |
| `CombatDeck` | `deck_exhausted` | failed draw on empty deck (see `exhaust_fn` hook) |
| `CombatDeck` | `card_played(instance)` | a creature enters the board |
| `CombatDeck` | `mana_changed(new_mana)` | available mana changes |
| `CardInstance` | `card_died(card)` | the instance dies |
| `CardInstance` | `card_damaged(card, amount)` | the instance takes damage |
| `CardInstance` | `card_revealed(card)` | a hidden card is revealed |
| `Combatant` | `health_changed(new_health)` | the participant's health changes |
| `Combatant` | `died` | health reaches 0 |

### History / replay

The engine is deterministic for a fixed seed. `CombatSession.setup(..., ai_seed)`
seeds both deck shuffles and the enemy `DummyAI`; the player AI is seeded by you
(`DummyAI.setup(seed)`, or `auto_resolve(player_ai, player_ai_seed)`). With those
seeds and the starting cards fixed, the same inputs reproduce the same match
bit-for-bit. Recommended pattern for the game layer: connect the signals above
to your own recorder that builds the history or a replay log. Persisting just
the seeds (and the starting cards) is enough to replay the whole combat from the
signals, without the engine having to store any extra state.

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
