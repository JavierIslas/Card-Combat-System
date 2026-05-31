# Card Combat Engine

A turn-based **card combat engine** for Godot 4.6 / GDScript. It handles the
*logic* of a card battle — turn FSM, mana, draw, attack/defense/block, damage
resolution and pluggable AI — and stays **completely domain-agnostic**: it knows
nothing about your GDD, rarities, abilities or loaders. Everything
game-specific is injected from your own layer via `Callable`s.

Headless-friendly and **deterministic for a fixed seed**, so combats are
reproducible bit-for-bit — ideal for replays and server-authoritative netcode.

> Not a UI toolkit. It is the combat *brain* meant to sit underneath a card UI
> framework (e.g. drag-and-drop hand/board addons), not replace one.

## Why this exists

The popular Godot card frameworks solve the **presentation** layer (dragging,
animating, laying out hands and piles) but leave the **rules** to you: turns,
mana ramp, attack/block declaration, damage resolution and AI. This engine is
exactly that missing piece, with no rendering and no game assumptions baked in.

## Features

- Turn FSM: `INICIO → PREPARACION → PRINCIPAL → ATAQUE → DEFENSA → RESOLVER → FINAL`.
- Decks: hand / draw pile / board / graveyard and a mana pool per side.
- Creatures **and** spells (damage / heal / buff / AOE / summon).
- Attack / defense / block declaration with simultaneous damage resolution.
- Injectable AI contract (`CombatAI`) with a reference `DummyAI`.
- Seeded, reproducible shuffles and AI for deterministic replay.
- Opaque containers (`CardData.metadata`, `HiddenCardStats.declared_abilities`)
  and `Callable` injection points — extend without touching the engine.
- No editor tooling required; classes register via `class_name`.

## Install

**Godot Asset Library** — search for *Card Combat Engine* and install. The files
land under `addons/card_combat/`.

**Manual / git** — copy the `addons/card_combat/` folder into your project's
`addons/` directory. No autoloads or project settings are required; the classes
are available everywhere through their `class_name`.

## Quick start

```gdscript
var session := CombatSession.new()
session.ability_fn = my_ability_handler   # optional, your ability semantics
session.config.starting_max_mana = 2      # optional balance tweak
session.setup(hero, hero_cards, enemy, enemy_cards)
session.start()
```

A runnable example lives in `addons/card_combat/examples/demo.tscn`: it wires a
full `CombatSession` with `DummyAI` on both sides and prints the combat log.
Open it in the editor and press **Run combat**, or run it headless as a smoke
check:

```bash
godot --headless res://addons/card_combat/examples/demo.tscn
```

## Determinism & replay

`CombatSession.setup(..., ai_seed)` seeds both deck shuffles and the enemy AI;
seed your own player AI to match. With the seeds and the starting cards fixed,
the same inputs reproduce the same match exactly. Persisting just the seeds (and
the starting decks) is enough to replay a whole combat from the engine's
signals — the engine itself stores no extra history.

## Documentation

Full class reference, injection points, the signal catalog and the replay
pattern live in the addon README:
[`addons/card_combat/README.md`](addons/card_combat/README.md).

## Testing

Tests run under [GUT](https://github.com/bitwes/Gut) 9.6 in `test/`:

```bash
godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://test -ginclude_subdirs -gexit
```

## License

Card Combat Engine is **dual-licensed**:

- **GNU AGPL v3.0** (default, see [`LICENSE`](LICENSE)) — free for open-source
  use. The AGPL is copyleft over a network: if you run the engine server-side as
  part of a product, that product's source must be released under the AGPL too.
- **Commercial license** (see [`LICENSE_COMMERCIAL.md`](LICENSE_COMMERCIAL.md)) —
  exempts you from the AGPL obligations for closed-source projects, including
  server-side play.

For a commercial license: **islasjavieralf@gmail.com**.
