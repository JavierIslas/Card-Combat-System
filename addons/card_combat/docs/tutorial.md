# Tutorial: Build Your First Card Game

This is a hands-on, build-it-from-zero walkthrough. By the end you will have a
small but **complete** card duel — *Tiny Clash* — that runs headless first, then
takes a keyword ability, a custom ability, live signals, and finally a
human-driven turn.

If the [Integration Guide](integration_guide.md) is the reference manual, this is
the guided first project. Read it top to bottom; every snippet builds on the
previous one.

> **Prerequisites:** Godot 4.6, with the `card_combat` addon present under
> `res://addons/card_combat/`. The classes register by `class_name`, so no plugin
> needs to be enabled in Project Settings to follow along.

## The mental model (read this once)

Three ideas carry the whole engine:

1. **The engine is agnostic.** It knows about decks, mana, a turn FSM, attacking,
   blocking and damage — nothing about *your* game's rarities, elements or named
   abilities.
2. **You inject the specifics.** Game rules enter through `Callable` hooks
   (`ability_fn`, `damage_fn`, …) and through the opaque `CardData.metadata`
   dictionary. The engine never reads those fields; your code does.
3. **You drive the FSM.** For AI-vs-AI you call `auto_resolve()`. For a human you
   react to the `phase_changed` signal and call the action methods
   (`play_card`, `declare_attacker`, …).

Keep these in mind and every step below is obvious.

---

## Step 1 — A hero

A hero is just a `Combatant` (a `Resource` with health and signals). You can use
it directly or subclass it to attach game-specific fields later.

```gdscript
func make_hero(hp: int) -> Combatant:
    var hero := Combatant.new()
    hero.max_health = hp
    hero.current_health = hp
    return hero
```

---

## Step 2 — A handful of cards

Cards are `CardData`. The engine only reads `cost`, `attack`, `health` and
`play_kind`. Everything else (keywords, your custom data) lives in `metadata`.

```gdscript
func make_creature(id: String, cost: int, attack: int, health: int) -> CardData:
    var card := CardData.new()
    card.card_id = id
    card.name = id
    card.cost = cost
    card.attack = attack
    card.health = health
    card.play_kind = CardData.PlayKind.UNIT   # lives on the board and fights
    return card


func make_bolt(id: String, cost: int, damage: int) -> CardData:
    var card := CardData.new()
    card.card_id = id
    card.name = id
    card.cost = cost
    card.play_kind = CardData.PlayKind.EFFECT  # resolves, then goes to graveyard
    var effect := SpellEffect.new()
    effect.effect_type = SpellEffect.EffectType.DAMAGE
    effect.value = damage
    effect.target_type = SpellEffect.TargetType.ENEMY_CREATURES
    card.spell_effects = [effect]
    return card
```

A deck is simply an `Array[CardData]`:

```gdscript
func build_deck() -> Array[CardData]:
    var deck: Array[CardData] = []
    for i in 6:
        deck.append(make_creature("grunt", 1, 2, 1))
    for i in 3:
        deck.append(make_creature("ogre", 3, 4, 4))
    for i in 2:
        deck.append(make_bolt("bolt", 2, 3))
    return deck
```

---

## Step 3 — Run a whole match (headless)

Before touching abilities or UI, prove the engine works end to end. `setup()`
takes both sides plus a seed; `auto_resolve()` plays the entire match with the
built-in `DummyAI` on both sides.

```gdscript
func run_headless() -> void:
    var session := CombatSession.new()
    session.setup(make_hero(30), build_deck(), make_hero(30), build_deck(), 42)
    session.auto_resolve()
    print(session.get_result())   # {winner_side, turn_number, ...}
```

Run it (`godot --headless -s your_script.gd`) and you should see a result
dictionary. The seed (`42`) makes the match fully reproducible — same seed, same
game, every time. That determinism is what makes save/resume and replays work
later.

> **You now have a working card game.** Everything from here is *flavor*: abilities,
> feedback, and human control.

---

## Step 4 — Give a creature a keyword ability

The engine ships no abilities, but the opt-in `AbilityLibrary` provides a ready
keyword system. Wire it into the session, then declare keywords in `metadata`.

```gdscript
func make_charger() -> CardData:
    var card := make_creature("charger", 2, 3, 2)
    card.metadata = {"keywords": ["CHARGE", "TAUNT"]}
    # CHARGE: can attack the turn it's played. TAUNT: enemies must hit it first.
    return card


func run_with_keywords() -> void:
    var session := CombatSession.new()

    var lib := AbilityLibrary.new(session)
    lib.wire_all()   # installs all keyword hooks into this session

    var deck: Array[CardData] = build_deck()
    deck.append(make_charger())

    session.setup(make_hero(30), deck, make_hero(30), build_deck(), 42)
    session.auto_resolve()
    print(session.get_result())
```

That is the whole keyword system: `wire_all()` once, then opaque keyword strings
per card. See the keyword table in the [Integration Guide §2](integration_guide.md#2-wiring-abilities-with-abilitylibrary)
for the full list (`LIFESTEAL`, `WINDFURY`, `ARMOR`, `OVERKILL`, …).

---

## Step 5 — A custom ability the library doesn't have

Your game will always have abilities no generic library can cover. Those go
through `ability_fn`: a `Callable` the engine fires on every lifecycle trigger of
every creature. Let's add a **deathrattle**: *when this creature dies, deal 2
damage to an enemy creature.*

Mark the card with your own metadata flag, then handle the `ON_DEATH` trigger:

```gdscript
func make_bomber() -> CardData:
    var card := make_creature("bomber", 3, 2, 2)
    card.metadata = {"deathrattle_damage": 2}   # your own key; the engine ignores it
    return card


func run_with_custom_ability() -> void:
    var session := CombatSession.new()

    # The handler needs the session to reach the board, but the session also holds
    # the handler — capture a weakref to avoid a reference cycle (and a leak).
    var session_ref: WeakRef = weakref(session)

    session.ability_fn = func(inst: Variant, trigger: int, _context: Dictionary) -> void:
        if not (inst is CardInstance):
            return   # inst is null for side-level triggers (ON_DRAW, ON_CAST)
        if trigger != CardInstance.Trigger.ON_DEATH:
            return
        var damage: int = int(inst.card_data.metadata.get("deathrattle_damage", 0))
        if damage <= 0:
            return
        var s: CombatSession = session_ref.get_ref()
        if s == null:
            return
        var enemy_side: int = 1 - inst.owner_id
        var enemies := CardInstance.living(s.decks[enemy_side].get_board())
        if not enemies.is_empty():
            enemies[0].take_damage(damage, inst)   # first living enemy = deterministic

    var deck: Array[CardData] = build_deck()
    deck.append(make_bomber())

    session.setup(make_hero(30), deck, make_hero(30), build_deck(), 42)
    session.auto_resolve()
    print(session.get_result())
```

Two things worth internalizing here:

- **`metadata` is your contract with yourself.** `deathrattle_damage` means
  nothing to the engine — it's just a key your handler agrees to read.
- **Stay deterministic.** Picking `enemies[0]` instead of a random target keeps
  replays reproducible. If you need randomness, draw it from a seeded source, not
  bare `randi()`.

> Want both the keyword library *and* your custom handler? Compose them: call the
> library's handler first, then your own. See
> [Integration Guide §8](integration_guide.md#8-custom-ability-handler).

---

## Step 6 — Watch what happens (signals)

So far the match runs silently. The session emits signals you connect to — for a
real game these drive the UI; here we just print.

```gdscript
func run_with_log() -> void:
    var session := CombatSession.new()
    AbilityLibrary.new(session).wire_all()

    session.phase_changed.connect(func(old_p: int, new_p: int) -> void:
        print("phase: %s -> %s" % [CombatState.phase_name(old_p), CombatState.phase_name(new_p)]))
    session.creature_died.connect(func(card: CardInstance, owner: int) -> void:
        print("died: %s (side %d)" % [card.card_data.name, owner]))
    session.combatant_damaged.connect(func(side: int, amount: int) -> void:
        print("hero %d took %d" % [side, amount]))
    session.combat_ended.connect(func(winner: int) -> void:
        print("winner: side %d" % winner))

    session.setup(make_hero(30), build_deck(), make_hero(30), build_deck(), 42)
    session.auto_resolve()
```

Run it and you get a play-by-play. Decks also emit their own signals
(`card_drawn`, `card_played`, `mana_changed`) via `session.decks[side]`.

---

## Step 7 — Hand one side to a human

`auto_resolve()` plays both sides automatically. To let a human play side 0,
**don't** call it — drive the FSM yourself and leave side 1 to the AI. In a real
project this lives in a `Node` that reacts to `phase_changed`; the skeleton:

```gdscript
var _session: CombatSession


func _ready() -> void:
    _session = CombatSession.new()
    AbilityLibrary.new(_session).wire_all()
    _session.ais[1] = HeuristicAI.new()   # AI drives the enemy; side 0 is left for us
    _session.phase_changed.connect(_on_phase_changed)
    _session.setup(make_hero(30), build_deck(), make_hero(30), build_deck(), 42)
    _session.start()
    _session.advance()   # nudge PREPARATION -> MAIN so play can begin


func _on_phase_changed(_old_phase: int, new_phase: int) -> void:
    if _session.active_side != 0:
        return   # not our turn; the AI driver handles side 1
    match new_phase:
        CombatState.Phase.MAIN:
            _show_hand()       # let the player pick a card, then call play_card
        CombatState.Phase.ATTACK:
            _show_attackers()  # let the player pick attackers + targets


# Called from your UI when the player commits an action. The action methods take
# objects (CardData / CardInstance), never indices:
func on_player_plays(card: CardData) -> void:
    _session.play_card(card)

func on_player_attacks(attacker: CardInstance, target: Variant) -> void:
    # target is a CardInstance to trade, or null for a hero swing
    _session.declare_attacker(attacker, target)

func on_player_done_with_main() -> void:
    _session.end_main_phase()

func on_player_done_attacking() -> void:
    _session.end_attack_phase()
```

That's the entire human-input contract: **react to `phase_changed`, call the
action methods, end the phase.** The engine validates every action (illegal plays
are rejected, not crashed) and advances the FSM for you.

---

## Where to go next

You've touched every layer the engine exposes. To go deeper:

| You want to… | See |
|--------------|-----|
| The full keyword list and overrides | [Integration Guide §2](integration_guide.md#2-wiring-abilities-with-abilitylibrary) |
| Spells outside the built-in catalog | [Integration Guide §7](integration_guide.md#7-custom-spell-effects-effect_fn) |
| Save / resume a match | [Integration Guide §10](integration_guide.md#10-save--resume) |
| 2v2 and free-for-all | [Integration Guide §11](integration_guide.md#11-multi-side-2v2-ffa) |
| Authoritative networking / replay | [Integration Guide §12](integration_guide.md#12-networking--replay) |
| A runnable demo scene | [`examples/demo.tscn`](../examples/demo.tscn) |
| The architecture and design rules | [`README.md`](../README.md) |

Build *Tiny Clash* once by hand and the rest of the engine reads like a map of a
city you've already walked.
