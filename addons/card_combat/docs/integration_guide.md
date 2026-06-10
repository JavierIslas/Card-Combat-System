# Card Combat Engine — Integration Guide

A step-by-step guide to integrating the engine into your Godot 4.6 card game.

---

## 1. Minimum Setup (5 lines)

```gdscript
# Create heroes (Combatant is a Resource — extend it for your hero class)
var hero := Combatant.new()
hero.max_health = 30
hero.current_health = 30

var enemy := Combatant.new()
enemy.max_health = 30
enemy.current_health = 30

# Build a deck (an Array[CardData])
var deck: Array[CardData] = []
var card := CardData.new()
card.card_id = "grunt"
card.name = "Grunt"
card.cost = 1
card.attack = 2
card.health = 1
card.play_kind = CardData.PlayKind.UNIT
deck.append(card)
# ... add more cards

# Create and run
var session := CombatSession.new()
session.setup(hero, deck, enemy, deck, 42)  # 42 = seed for deterministic replay
session.auto_resolve()                        # AI vs AI headless
print(session.get_result())                   # {winner_side, turn_number, hp}
```

This runs a complete combat with the built-in `DummyAI` on both sides. No UI, no
abilities — pure engine logic.

---

## 2. Wiring Abilities with AbilityLibrary

The engine is agnostic by default (no abilities). The `AbilityLibrary` provides a
ready-made keyword system you can opt into:

```gdscript
var session := CombatSession.new()
var lib := AbilityLibrary.new(session)  # the library keeps a weakref to the session
lib.wire_all()  # wires all 5 hooks into that session in one call
```

That single `wire_all` call replaces:

```gdscript
# Manual equivalent of wire_all:
session.ability_fn = lib.ability_handler
session.attack_restriction_fn = lib.taunt_restriction
session.incoming_damage_fn = lib.armor_damage
session.spell_power_fn = lib.spell_power
session.aura_fn = lib.recompute_auras
```

### Supported Keywords

Declare keywords per card in `CardData.metadata`:

```gdscript
var card := CardData.new()
card.card_id = "fire_imp"
card.cost = 2
card.attack = 3
card.health = 2
card.play_kind = CardData.PlayKind.UNIT
card.metadata = {
    "keywords": ["CHARGE", "LIFESTEAL"],
}
```

| Keyword | Effect | Metadata overrides |
|---------|--------|--------------------|
| `CHARGE` | Can attack immediately (no summoning sickness) | — |
| `IMMUNITY` | Absorbs N hits completely | `immunity_hits` (default 1; -1 = infinite) |
| `LIFESTEAL` | Combat damage heals owner's hero | — |
| `TAUNT` | Enemies must attack this creature | — |
| `THORNS` | Reflects N damage to attacker | `thorns` (default 1) |
| `STEALTH` | Can't be targeted until it attacks | — |
| `WINDFURY` | Can attack N times per turn | `windfury_attacks` (default 2) |
| `FREEZE` | Damaged creature is frozen N turns | `freeze_turns` (default 1) |
| `ARMOR` | Reduces each hit by N | `armor` (default 0) |
| `BATTLECRY` | On play, deals N damage to target | `battlecry_damage` (default 1) |
| `SPELLPOWER` | Adds N to owner's spell damage | `spell_power` (default 0) |
| `LORD` | Buffs other friendly creatures +N/+M | `aura_attack`/`aura_health` (default 1/1) |
| `OVERKILL` | Lethal excess tramples to controller's hero | `overkill_factor` (default 1) |
| `SPELLBURST` | Gains +N/+M each time owner casts a spell | `spellburst_attack`/`spellburst_health` (default 1/1) |

You can combine keywords freely: `["CHARGE", "TAUNT", "LIFESTEAL"]`.

---

## 3. Creating Cards

### Creatures

```gdscript
func make_creature(id: String, cost: int, attack: int, health: int, keywords: Array = []) -> CardData:
    var card := CardData.new()
    card.card_id = id
    card.name = id
    card.cost = cost
    card.attack = attack
    card.health = health
    card.play_kind = CardData.PlayKind.UNIT
    if not keywords.is_empty():
        card.metadata = {"keywords": keywords}
    return card
```

### Spells

```gdscript
func make_damage_spell(id: String, cost: int, damage: int, target: SpellEffect.TargetType) -> CardData:
    var card := CardData.new()
    card.card_id = id
    card.name = id
    card.cost = cost
    card.play_kind = CardData.PlayKind.EFFECT
    var effect := SpellEffect.new()
    effect.effect_type = SpellEffect.EffectType.DAMAGE
    effect.value = damage
    effect.target_type = target
    card.spell_effects = [effect]
    return card
```

### Persistent enchantments (auras)

```gdscript
func make_aura(id: String, cost: int) -> CardData:
    var card := CardData.new()
    card.card_id = id
    card.name = id
    card.cost = cost
    card.play_kind = CardData.PlayKind.PERSISTENT  # lives on board, never fights
    card.metadata = {"keywords": ["LORD"], "aura_attack": 2, "aura_health": 1}
    return card
```

### Game-specific data

The engine never reads fields beyond cost/attack/health/play_kind. Put everything
else in `metadata`:

```gdscript
card.metadata = {
    "keywords": ["CHARGE"],
    "rarity": "EPIC",           # your game's concept
    "element": "FIRE",          # your game's concept
    "flavor_text": "Burn!",
    "custom_id": "fire_imp_01",
}
```

---

## 4. Connecting Signals to UI

The engine emits signals you can connect to drive your UI:

```gdscript
session.phase_changed.connect(_on_phase_changed)
session.combatant_damaged.connect(_on_hero_damaged)
session.combatant_healed.connect(_on_hero_healed)
session.creature_died.connect(_on_creature_died)
session.creature_summoned.connect(_on_creature_summoned)
session.combat_ended.connect(_on_combat_ended)
session.spell_fizzled.connect(_on_spell_fizzled)
session.action_rejected.connect(_on_action_rejected)

func _on_phase_changed(old_phase: int, new_phase: int) -> void:
    print("%s -> %s" % [CombatState.phase_name(old_phase), CombatState.phase_name(new_phase)])

func _on_hero_damaged(side: int, amount: int) -> void:
    health_bars[side].value -= amount

func _on_creature_died(card: CardInstance, owner: int) -> void:
    # Animate death, update board layout
    pass

func _on_action_rejected(action: StringName, reason: StringName) -> void:
    # Every driver method that returns false fires this first with a
    # machine-readable reason (&"cannot_attack", &"invalid_hand_index", ...),
    # so the UI can tell the player WHY instead of ignoring the click.
    # Gated by config.emit_action_rejections (default true).
    toast.show("%s rejected: %s" % [action, reason])
```

### Deck-level signals

Each `CombatDeck` also emits signals for card-level events:

```gdscript
session.decks[0].card_drawn.connect(_on_card_drawn)
session.decks[0].card_played.connect(_on_card_played)
session.decks[0].mana_changed.connect(_on_mana_changed)
```

---

## 5. Human Input (turn-based gameplay)

For a human player, don't use `auto_resolve`. Drive the session manually:

```gdscript
# After session.start(), the FSM is in PREPARATION. PREPARATION and BEGIN need an
# external nudge: call session.advance() to move PREPARATION -> MAIN. Your UI reacts
# to phase_changed to know when to show interactions:

func _on_phase_changed(old_phase: int, new_phase: int) -> void:
    match new_phase:
        CombatState.Phase.MAIN:
            _show_hand_interaction()  # player picks a card to play
        CombatState.Phase.ATTACK:
            _show_attack_declaration()  # player picks attackers + targets
        CombatState.Phase.DEFENSE:
            _show_block_declaration()  # player picks blockers

# Leave PREPARATION:
session.advance()

# The direct action methods take objects (CardData / CardInstance), not indices.
# When player clicks a card (a CardData from the hand):
session.play_card(card)

# When player declares an attack (attacker is a CardInstance; target is a
# CardInstance for a creature, or null + target_side for a hero swing):
session.declare_attacker(attacker, target, target_side)

# When player declares a blocker (both are CardInstance):
session.declare_blocker(attacker, blocker)

# End phases:
session.end_main_phase()
session.end_attack_phase()
session.end_defense_phase()
```

> If your driver works in indices (UI / network), prefer `apply_command` with a
> `CombatCommand` whose payload carries `hand_index` / `attacker_index` /
> `blocker_index` (see §12). The engine resolves indices to instances internally.

---

## 6. Custom AI

Subclass `CombatAI` and override the 5 core methods + optional 6th:

```gdscript
class_name MyAI
extends CombatAI

func choose_card_to_play(hand: Array[CardData], mana: int) -> CardData:
    # Return a CardData from the hand to play, or null to skip
    for card in hand:
        if card.cost <= mana:
            return card
    return null

func choose_attackers(board: Array[CardInstance], enemy_heroes: Array[Combatant] = []) -> Array[CardInstance]:
    # Return the CardInstances that should attack
    var attackers: Array[CardInstance] = []
    for inst in board:
        if inst.can_attack_this_turn and inst.is_combatant:
            attackers.append(inst)
    return attackers

func choose_attack_target(attacker: CardInstance, enemy_board: Array[CardInstance], enemy_heroes: Array[Combatant] = []) -> Variant:
    # Return a CardInstance to hit, or null for hero swing
    if enemy_board.is_empty():
        return null  # hit hero
    return enemy_board[0]  # hit first enemy creature

func choose_spell_target(card: CardData, own_board: Array[CardInstance], enemy_board: Array[CardInstance]) -> Variant:
    # Return a CardInstance for single-target spells, or null to skip
    if enemy_board.is_empty():
        return null
    return enemy_board[0]

func choose_blockers(attackers: Array[CardInstance], my_board: Array[CardInstance]) -> Dictionary:
    # Return {attacker_instance: blocker_instance}. The engine calls
    # declare_blocker(attacker, blocker) for each pair, so the key is the
    # attacking CardInstance, not an index.
    var blocks: Dictionary = {}
    for attacker in attackers:
        if my_board.size() > 0:
            blocks[attacker] = my_board[0]
    return blocks

# Optional: enable battlecry targeting
func choose_play_target(card: CardData, own_board: Array, enemy_board: Array) -> Variant:
    return enemy_board[0] if not enemy_board.is_empty() else null
```

Then inject before setup:

```gdscript
var ai := MyAI.new()
session.ais[1] = ai  # AI controls side 1 (enemy)
session.setup(player_hero, player_deck, enemy_hero, enemy_deck, seed)
```

---

## 7. Custom Spell Effects (effect_fn)

For spell effects outside the built-in catalog (DAMAGE, HEAL, BUFF_ATTACK,
AOE_DAMAGE, SUMMON):

```gdscript
var card := CardData.new()
card.card_id = "steal_life"
card.cost = 3
card.play_kind = CardData.PlayKind.EFFECT

var effect := SpellEffect.new()
effect.effect_type = SpellEffect.EffectType.DAMAGE  # fallback type
effect.target_type = SpellEffect.TargetType.ENEMY_CREATURES
effect.effect_fn = _drain_effect  # custom resolution
card.spell_effects = [effect]


func _drain_effect(_effect: SpellEffect, target: Variant, context: Dictionary) -> Dictionary:
    var session: CombatSession = context["session"]
    var owner_id: int = context["owner_id"]
    if target is CardInstance and not target.is_dead:
        target.take_damage(3, null)
        session.heal_hero(owner_id, 3)  # drain: damage + heal
    return {}
```

---

## 8. Custom Ability Handler

If `AbilityLibrary` doesn't cover your needs, write your own `ability_fn`:

```gdscript
func my_ability_handler(inst: Variant, trigger: int, context: Dictionary) -> void:
    # inst is null for side-level triggers (ON_DRAW, ON_CAST)
    if trigger == CardInstance.Trigger.ON_CAST and inst == null:
        _on_spell_cast(context)
        return

    if not (inst is CardInstance):
        return

    match trigger:
        CardInstance.Trigger.ON_SETUP:
            # Custom on-play effect
            if inst.card_data.metadata.get("custom_effect") == "enrage":
                inst.apply_permanent_buff(2, 0)  # +2 attack permanently
        CardInstance.Trigger.ON_DAMAGE_TAKEN:
            # Custom retaliation
            if inst.card_data.metadata.get("custom_effect") == "retaliate":
                var source = context.get("source")
                if source is CardInstance:
                    source.take_damage(1, inst)
```

Wire it:

```gdscript
session.ability_fn = my_ability_handler
```

---

## 9. Balance Configuration

Tweak before `setup()`:

```gdscript
session.config.starting_max_mana = 1          # default 2
session.config.mana_ramp_per_turn = 1         # default 2
session.config.max_mana_cap = 10              # default 10
session.config.initial_hand_size = 4          # default 3
session.config.stalemate_turn_limit = 40      # default 50
session.config.max_board_size = 5             # default -1 (unlimited)
session.config.max_hand_size = 8              # default -1 (unlimited)
session.config.max_permanent_buffs_per_card = 3  # default -1 (unlimited)
session.config.record_events = false          # disable event_log for mass simulation
session.config.emit_action_rejections = false # silence action_rejected in headless sims
```

---

## 10. Save / Resume

```gdscript
# Save
var save_data: Dictionary = session.serialize()
# Store save_data to disk / cloud

# Resume — deserialize is STATIC and returns the rebuilt session.
var session := CombatSession.deserialize(save_data, {
    "ability_fn": my_ability_handler,
    "damage_fn": Callable(),
    "exhaust_fn": Callable(),
    "discard_fn": Callable(),
    "attack_restriction_fn": my_taunt_restriction,
    "incoming_damage_fn": Callable(),
    "cost_fn": Callable(),
    "spell_power_fn": Callable(),
    "aura_fn": Callable(),
    "config": my_config,
    "heroes": [player_hero, enemy_hero],  # optional: re-inject your hero subclass
    "ais": [player_ai, enemy_ai],          # optional: re-inject your AI instances
})
# Session is now at the exact point where serialize() was called.
# Deterministic: same inputs produce the same rest of the match.
```

---

## 11. Multi-Side (2v2, FFA)

```gdscript
# 2v2: 4 sides, teams [0,0,1,1]
session.setup_sides([
    {"hero": hero_a, "cards": deck_a},
    {"hero": hero_b, "cards": deck_b},
    {"hero": enemy_a, "cards": enemy_deck_a},
    {"hero": enemy_b, "cards": enemy_deck_b},
], [0, 0, 1, 1], seed)

# FFA: 3 sides, no teams (each side is its own team)
session.setup_sides([
    {"hero": hero_a, "cards": deck_a},
    {"hero": hero_b, "cards": deck_b},
    {"hero": hero_c, "cards": deck_c},
], [], seed)  # empty teams = FFA
```

---

## 12. Networking / Replay

### Replay from events

```gdscript
var events: Array = session.event_log
# Store events. To replay, just read them — each CombatEvent has .type and .payload.
```

### Replay from inputs (authoritative server)

```gdscript
# Server side: accept commands, validate, apply.
# CombatCommand.new(type, side, payload) — type is required.
var cmd := CombatCommand.new(
    CombatCommand.CommandType.PLAY_CARD,
    player_side,
    {"hand_index": chosen_index},
)
var accepted: bool = session.apply_command(cmd)

# The command_log stores all accepted commands.
# Send them to clients for deterministic replay.
```

---

## Quick Reference: Injection Points

| Hook | Signature | Purpose |
|------|-----------|---------|
| `ability_fn` | `(inst, trigger, ctx) -> void` | Ability semantics |
| `damage_fn` | `(attacker, defender) -> int` | Custom damage formula |
| `exhaust_fn` | `(owner_id) -> void` | Fatigue when deck is empty |
| `discard_fn` | `(card, owner_id) -> void` | Overdraw (hand full) or `deck.discard_card()` |
| `attack_restriction_fn` | `(attacker, enemies) -> Array` | Force targeting (TAUNT) |
| `incoming_damage_fn` | `(inst, amount, source) -> int` | Armor / prevention |
| `cost_fn` | `(card, owner_id) -> int` | Dynamic mana cost |
| `spell_power_fn` | `(owner_id) -> int` | Spell damage bonus |
| `aura_fn` | `(session) -> void` | Recompute continuous buffs |
| `effect_fn` (per SpellEffect) | `(effect, target, ctx) -> Dict` | Custom spell resolution |

All are `Callable()` by default (no-op). Set them before `setup()`.

Two `CombatConfig` flags shape observability (both default `true`):
`record_events` (set `false` to skip `event_log` recording in mass simulation;
live signals still fire) and `emit_action_rejections` (set `false` to silence
the `action_rejected(action, reason)` signal — see §4).

For a one-off effect outside a card's authored `spell_effects`, the session also
exposes `play_spell(card, effect, target)`: it consumes `card` from the active
hand and resolves the externally-built `SpellEffect` through the same
fizzle / sweep / `ON_CAST` pipeline as `play_card`.
