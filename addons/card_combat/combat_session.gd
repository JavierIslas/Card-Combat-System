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

class_name CombatSession
extends RefCounted
## Alternating-turn combat FSM: orchestrates turns, decks, AI and damage
## resolution. The model is symmetric per `side` (0/1) and agnostic to who drives
## each side (human UI, AI or a network peer), which makes it PvP-ready. On every
## turn one side is ACTIVE (takes its turn and attacks) and the other is PASSIVE
## (declares blockers). turn_number counts half-turns (one per side turn).

signal phase_changed(old_phase: int, new_phase: int)
signal combat_ended(winner_side: int)
signal creature_died(card: CardInstance, owner: int)
signal creature_summoned(card: CardInstance, owner: int)
signal combatant_damaged(side: int, amount: int)
signal combatant_healed(side: int, amount: int)
signal spell_fizzled(card: CardData)

# Safety guards (engine internals, not game balance): cap auto_resolve loop
# iterations and the number of card plays resolved automatically per turn.
const AUTO_RESOLVE_MAX_ITERATIONS := 200
const MAX_PLAYS_PER_TURN := 10

# Effective iteration cap for auto_resolve. Defaults to the const; overridable
# (e.g. tests) so the exhaustion path can be exercised without a pathological
# combat that never converges.
var _auto_resolve_max_iterations: int = AUTO_RESOLVE_MAX_ITERATIONS

var phase: CombatState.Phase = CombatState.Phase.BEGIN
## Side taking its turn (0 or 1). The other side (1 - active_side) is passive.
var active_side: int = 0
## Winning side once the combat ends, or -1 for no winner (stalemate / both dead).
## Meaningful when the winning team has a single side (1v1, FFA); in team games
## prefer winner_team and read the surviving side(s) from it.
var winner_side: int = -1
## Winning team id once the combat ends, or -1 for no winner. The team-aware
## counterpart of winner_side: in 1v1 it equals teams[winner_side].
var winner_team: int = -1
## Team id per side, indexed by side: same id = allies. Sized in setup() alongside
## the per-side arrays. 1v1 default is [0, 1] (each side its own team), so the
## engine behaves exactly as before; 2v2 = [0, 0, 1, 1], FFA = [0, 1, 2, 3].
var teams: Array[int] = [0, 1]
## Heroes and decks indexed by side. Drivers (UI/AI/network) interact through the
## same per-side surface; the engine never assumes which side is "the player".
var heroes: Array[Combatant] = [null, null]
var decks: Array[CombatDeck] = [null, null]
## AI driver per side, used by auto_resolve(). Assign ais[side] before setup() to
## inject a custom controller; otherwise setup() seeds a reference DummyAI.
var ais: Array[CombatAI] = [null, null]
var turn_number: int = 0
# Turn order over sides, interleaved by team so teammates don't act back-to-back
# (round-robin between teams). Rebuilt from `teams` in setup_sides / deserialize.
var _turn_order: Array[int] = [0, 1]
# CombatPair declared by each side, indexed by side.
var _attack_pairs: Array[Array] = [[], []]
# attacker CardInstance -> blocker CardInstance, for the current turn.
var _block_assignments: Dictionary = {}
var _combat_over: bool = false
var _resolver: CombatDamageResolver = CombatDamageResolver.new()
# Creatures that died during combat, tracked per side for external retrieval.
var _dead_creatures: Array[Array] = [[], []]

## Structured, replay-friendly stream of what the combat did. Mirrors the signals
## below; the game layer can consume it instead of wiring each signal. Cleared on
## setup(). Card-level events (draw/play) live on CombatDeck, not here.
var event_log: Array[CombatEvent] = []

## Structured stream of driver intentions (input), the counterpart of event_log
## (output). apply_command() appends each accepted command here, so a match can be
## replayed from input and an authoritative server can audit what was requested.
## Cleared on setup(); serialized with the session.
var command_log: Array[CombatCommand] = []

## Balance parameters. Reassign before setup() to customize.
var config: CombatConfig = CombatConfig.new()

## Ability handler. Injected by the game layer before setup() (the game layer
## injects its own ability handler). Empty = engine-agnostic.
var ability_fn: Callable = Callable()

## Optional damage formula hook, seeded into the resolver on setup().
## Signature: (attacker, defender) -> int. Empty = engine default.
var damage_fn: Callable = Callable()

## Optional fatigue hook, seeded into both decks on setup().
## Signature: (owner_id: int). Empty = decks only emit deck_exhausted.
var exhaust_fn: Callable = Callable()

## Optional overdraw hook, seeded into both decks on setup().
## Signature: (card: CardData, owner_id: int). Invoked when a drawn card is burned
## because the hand is full (see config.max_hand_size). Empty = burned silently.
var discard_fn: Callable = Callable()

## Optional attack-targeting restriction hook (e.g. TAUNT). Signature:
## (attacker: CardInstance, enemy_creatures: Array) -> Array. Returns the subset of
## living enemy creatures the attacker is RESTRICTED to: a non-empty list means the
## attacker MUST hit one of them (a hero swing or any other creature is illegal); an
## empty list means no restriction (any creature / hero, the previous behavior).
## Empty Callable = no restriction. Agnostic: the engine never reads what makes a
## creature "taunt"; the hook decides. Re-injected via deserialize hooks.
var attack_restriction_fn: Callable = Callable()

## How ability triggers are dispatched. INLINE (default) fires ability_fn the
## moment a trigger happens, exactly as before — a chained trigger resolves
## depth-first, mid-sweep. QUEUED defers every trigger into a FIFO queue drained at
## safe points (before each board sweep / at the end of each driver action), so a
## chain (a trigger that kills a creature that fires another trigger) resolves
## breadth-first in one flat order. Opt-in: set before setup(). Both are
## deterministic; they differ only in the order of chained reactions.
enum TriggerMode { INLINE, QUEUED }
var trigger_mode: TriggerMode = TriggerMode.INLINE

## Deferred-trigger queue, fed only in QUEUED mode. Owns the pending list; the
## session passes itself no further than the dispatch Callable (explicit dependency).
var _trigger_queue: CombatTriggerQueue = CombatTriggerQueue.new()

## The ability_fn actually handed to decks/instances. In INLINE it IS ability_fn,
## so _fire() calls the game handler directly and the queue is never touched. In
## QUEUED it is _enqueue_trigger, so every _fire() enqueues instead, and the real
## ability_fn runs later via _dispatch_trigger. Computed in setup()/deserialize.
var _effective_ability_fn: Callable = Callable()


func setup(side0_hero: Combatant, side0_cards: Array[CardData], side1_hero: Combatant, side1_cards: Array[CardData], ai_seed: int = -1) -> void:
	## Positional 1v1 setup: side 0 = first hero/cards, side 1 = second hero/cards.
	## Thin wrapper over setup_sides with the default two-team layout [0, 1], kept so
	## existing 1v1 callers (and the demo) need no changes.
	setup_sides([
		{"hero": side0_hero, "cards": side0_cards},
		{"hero": side1_hero, "cards": side1_cards},
	], [0, 1], ai_seed)


func setup_sides(sides: Array, side_teams: Array[int] = [], ai_seed: int = -1) -> void:
	## Generic N-side setup. Each entry of `sides` is {"hero": Combatant, "cards":
	## Array[CardData]}. `side_teams` assigns a team id per side (same id = allies);
	## empty means every side is its own team (free-for-all). Sizes all per-side
	## arrays to sides.size(), so the rest of the engine indexes by side uniformly.
	var n: int = sides.size()
	teams = side_teams.duplicate() if not side_teams.is_empty() else _default_teams(n)
	_rebuild_turn_order()

	# Seed the optional damage hook so the resolver uses it for this combat.
	_resolver.damage_fn = damage_fn
	# Resolve the effective trigger sink BEFORE building decks: _make_deck propagates
	# it to each deck/instance and draws the initial hands (which fire ON_DRAW).
	_compute_effective_ability_fn()

	# Reset combat state BEFORE building decks so the initial-hand draws (emitted
	# inside _make_deck) land in a freshly cleared event_log.
	phase = CombatState.Phase.BEGIN
	active_side = 0
	winner_side = -1
	winner_team = -1
	turn_number = 0
	_block_assignments.clear()
	event_log.clear()
	command_log.clear()
	_combat_over = false

	_init_side_arrays(n)
	for side in n:
		heroes[side] = sides[side].get("hero", null)
		# Derive a distinct shuffle seed per side from the combat seed so a fixed
		# ai_seed reproduces every deck order. A negative seed leaves decks
		# randomized (engine default). The +side+1 keeps side 0/1 identical to the
		# previous two-side formula.
		var side_seed: int = ai_seed if ai_seed < 0 else ai_seed * 2 + side + 1
		decks[side] = _make_deck(_cards_of(sides[side]), side, side_seed)
		# Seed a reference AI per side unless a driver already assigned one.
		_seed_ai(side, ai_seed)

	# Fire the deferred initial-hand ON_DRAW triggers (QUEUED); no-op in INLINE.
	_drain_triggers()


func _cards_of(side_entry: Dictionary) -> Array[CardData]:
	## Extract a typed card list from a side entry, tolerating an untyped input array
	## (a direct setup_sides caller may pass a plain Array).
	var cards: Array[CardData] = []
	for c in side_entry.get("cards", []):
		cards.append(c)
	return cards


func _default_teams(n: int) -> Array[int]:
	## Free-for-all default: each side is its own team (id == side index).
	var out: Array[int] = []
	for side in n:
		out.append(side)
	return out


func _init_side_arrays(n: int) -> void:
	## Size the per-side arrays to `n` sides and reset the in-flight attack/dead
	## tracking, so the rest of the engine indexes by side uniformly. Shared by
	## setup_sides (fresh combat) and _restore_topology (resume).
	heroes.resize(n)
	decks.resize(n)
	ais.resize(n)
	_attack_pairs = []
	_dead_creatures = []
	for _i in n:
		_attack_pairs.append([])
		_dead_creatures.append([])


func _make_deck(cards: Array[CardData], side: int, shuffle_seed: int) -> CombatDeck:
	var deck := CombatDeck.new()
	deck.setup(cards, side, config.starting_max_mana, _effective_ability_fn, config.max_permanent_buffs_per_card, shuffle_seed)
	deck.exhaust_fn = exhaust_fn
	deck.max_board_size = config.max_board_size
	deck.max_hand_size = config.max_hand_size
	deck.discard_fn = discard_fn
	_wire_deck_events(deck)
	deck.draw_initial_hand(config.initial_hand_size)
	return deck


func _wire_deck_events(deck: CombatDeck) -> void:
	## Mirror the deck's card-level signals into the session event_log so the log
	## alone is a full replay/spectator stream. The deck signals stay intact for
	## live listeners; the session is the single owner of event_log appends. Shared
	## by _make_deck and deserialize so a resumed combat keeps logging.
	##
	## The handlers capture a weakref to the session and the owner id (a primitive),
	## never `self` or `deck`: a lambda stored on the deck's signal that captured
	## either would form a RefCounted cycle (deck -> signal -> lambda -> session/deck)
	## that never frees. Through the weakref the deck holds the session weakly, so a
	## finished combat is collected normally (see the no-cycle test).
	var owner: int = deck.owner_id
	var weak: WeakRef = weakref(self)
	deck.card_drawn.connect(func(card: CardData) -> void:
		var s: CombatSession = weak.get_ref()
		if s == null:
			return
		s._emit_card_drawn(card, owner)
		# Side-level ON_DRAW: the drawn card is still CardData in hand, so inst is null
		# and the card travels in context. Handlers must tolerate a null instance. Goes
		# through the effective sink so QUEUED defers it like every other trigger.
		if s._effective_ability_fn.is_valid():
			s._effective_ability_fn.call(null, CardInstance.Trigger.ON_DRAW, {"card": card, "owner": owner}))
	deck.card_played.connect(func(inst: CardInstance) -> void:
		var s: CombatSession = weak.get_ref()
		if s != null:
			s._emit_card_played(inst, owner))
	deck.mana_changed.connect(func(new_mana: int) -> void:
		var s: CombatSession = weak.get_ref()
		if s != null:
			s._emit_mana_changed(owner, new_mana))
	deck.max_mana_changed.connect(func(new_max: int) -> void:
		var s: CombatSession = weak.get_ref()
		if s != null:
			s._emit_max_mana_changed(owner, new_max))
	deck.deck_exhausted.connect(func() -> void:
		var s: CombatSession = weak.get_ref()
		if s != null:
			s._emit_deck_exhausted(owner))


func _deck_hooks() -> Dictionary:
	## Non-serializable deck config, re-supplied to CombatDeck.deserialize. Uses the
	## effective sink so a QUEUED combat keeps deferring triggers after a resume.
	return {
		"ability_fn": _effective_ability_fn,
		"max_permanent_buffs": config.max_permanent_buffs_per_card,
		"exhaust_fn": exhaust_fn,
		"discard_fn": discard_fn,
		"max_board_size": config.max_board_size,
		"max_hand_size": config.max_hand_size,
	}


func _seed_ai(side: int, ai_seed: int) -> void:
	## Honor an AI assigned to ais[side] before setup; otherwise seed a reference
	## DummyAI (deterministic for a fixed seed, distinct per side).
	if ais[side] != null:
		return
	var dummy := DummyAI.new()
	dummy.setup(ai_seed if ai_seed < 0 else ai_seed * 2 + side + 1)
	ais[side] = dummy


func _compute_effective_ability_fn() -> void:
	## Resolve which Callable decks/instances fire on a trigger, from trigger_mode +
	## ability_fn. QUEUED only matters when there is a real handler to defer; with no
	## ability_fn it stays empty (same as INLINE), so the queue is never fed pointlessly.
	if trigger_mode == TriggerMode.QUEUED and ability_fn.is_valid():
		_effective_ability_fn = _enqueue_trigger
	else:
		_effective_ability_fn = ability_fn


func _enqueue_trigger(inst: Variant, trigger: int, context: Dictionary) -> void:
	## QUEUED-mode sink: defer a trigger instead of firing it. Matches the ability_fn
	## signature so it slots in transparently wherever _effective_ability_fn is used.
	_trigger_queue.enqueue(inst, trigger, context)


func _dispatch_trigger(inst: Variant, trigger: int, context: Dictionary) -> void:
	## Drain-time handler: run the real game ability_fn for one dequeued trigger.
	if ability_fn.is_valid():
		ability_fn.call(inst, trigger, context)


func _drain_triggers() -> void:
	## Fire every deferred trigger in FIFO order (QUEUED mode). No-op in INLINE: the
	## queue is never fed there, so this costs a single is_empty check.
	_trigger_queue.drain(_dispatch_trigger)


func start() -> void:
	_transition_to(CombatState.Phase.PREPARATION)


func play_card(card: CardData, as_hidden: bool = false, declared_attack: int = 0, declared_health: int = 0, target: Variant = null, target_side: int = -1) -> bool:
	## Plays a card from the ACTIVE side's hand. `target` only applies to
	## single-target spells (e.g. PLAYER_CREATURE). `target_side` names which enemy
	## hero an ENEMY_HERO spell hits (-1 = first living enemy); ignored by other
	## effects. A single-target spell cast with no valid target fizzles: it is NOT
	## consumed (mana and card stay), `spell_fizzled` is emitted and play_card returns
	## false. The caller is responsible for picking a target and retrying.
	if not _can_play_from_hand(card):
		return false
	if card.play_kind == CardData.PlayKind.EFFECT:
		if _spell_needs_missing_target(card, target):
			_emit_spell_fizzled(card)
			return false
		if not _consume_spell(card):
			return false
		_apply_spell_effects(card, active_side, target, target_side)
		_drain_triggers()
		return true
	var inst: CardInstance = decks[active_side].play_creature(card, as_hidden, declared_attack, declared_health)
	# Fire the deferred ON_SETUP (QUEUED) before handing control back to the driver.
	_drain_triggers()
	return inst != null


func play_spell(card: CardData, effect: SpellEffect, target: Variant = null) -> bool:
	## Ad-hoc casting: applies a single externally-built SpellEffect to `target`,
	## bypassing the card's own TargetType-relative spell_effects. For normal
	## casting prefer play_card(card, ..., target), which honors the card's
	## declared spell_effects and target_type.
	if not _can_play_from_hand(card):
		return false
	# Same fizzle contract as play_card: a single-target effect with no living
	# target is rejected before consuming, so the card and mana are not wasted.
	if _effect_needs_missing_target(effect, target):
		_emit_spell_fizzled(card)
		return false
	if not _consume_spell(card):
		return false
	var context: Dictionary = {"session": self, "owner_id": active_side}
	# An externally-built effect can kill (damage/AOE/custom effect_fn). Sweeping
	# afterwards surfaces those deaths like any other (_record_death is idempotent),
	# matching the play_card path; otherwise an ad-hoc kill would leave a zombie on
	# the board and break the event_log / get_dead_creatures invariant.
	_apply_effect_and_sweep(effect, target, context)
	return true


func _spell_needs_missing_target(card: CardData, target: Variant) -> bool:
	## A spell fizzles when any of its effects is single-target (PLAYER_CREATURE)
	## and no living creature target was provided. Casting is atomic: the whole
	## spell is rejected so a half-applied multi-effect card can't be consumed.
	for effect in card.spell_effects:
		if _effect_needs_missing_target(effect, target):
			return true
	return false


func _effect_needs_missing_target(effect: SpellEffect, target: Variant) -> bool:
	## Single source of truth for the fizzle predicate. A single-target effect
	## (PLAYER_CREATURE) needs one living creature; a multi-target effect
	## (CHOSEN_CREATURES) needs at least target_count living creatures supplied.
	## Shared by play_card (via _spell_needs_missing_target) and play_spell.
	if effect.target_type == SpellEffect.TargetType.PLAYER_CREATURE:
		return not (target is CardInstance and not target.is_dead)
	if effect.target_type == SpellEffect.TargetType.CHOSEN_CREATURES:
		return _count_living_targets(target) < maxi(effect.target_count, 1)
	return false


func _count_living_targets(target: Variant) -> int:
	## Number of living creatures in a chosen-target list (0 if it is not an Array).
	if not (target is Array):
		return 0
	return CardInstance.living(target).size()


func _can_play_from_hand(card: CardData) -> bool:
	## Shared precondition: a card can only be played from the active side's hand
	## during MAIN, while the combat is live and the deck can afford it.
	if phase != CombatState.Phase.MAIN:
		return false
	if _combat_over:
		return false
	return decks[active_side].can_play_card(card)


func _consume_spell(card: CardData) -> bool:
	## Single source of truth for moving a spell out of hand and spending mana.
	return decks[active_side].play_spell(card) != null


func declare_attacker(attacker: CardInstance, target: Variant = null, target_side: int = -1) -> bool:
	## Active-side action: declare an attacker. `target` is an enemy creature for a
	## directed attack, or null to swing at an enemy hero. With more than one enemy,
	## `target_side` names which enemy hero is hit; -1 picks the first living enemy.
	## A blocker declared in DEFENSE can later redirect this pair's damage. Returns
	## true if the attacker was declared; false if any precondition rejected it.
	if not CombatState.is_active_action_phase(phase):
		return false
	if _combat_over:
		return false
	if attacker == null:
		return false
	if not decks[active_side].get_board().has(attacker):
		return false
	# Reject summoning-sick creatures and attackers that already used up their swings
	# this turn. attacks_per_turn defaults to 1 (classic single attack); a multi-attack
	# creature may declare again until times_attacked reaches it.
	if not attacker.can_attack_this_turn or attacker.times_attacked >= attacker.attacks_per_turn:
		return false
	var ts: int = -1
	if not (target is CardInstance):
		# Hero attack: resolve and validate the target side (must be a living enemy).
		ts = target_side if target_side >= 0 else _default_enemy_side(active_side)
		if ts < 0 or are_allies(ts, active_side):
			return false
	# Targeting restriction (e.g. TAUNT): when the hook restricts this attacker to a
	# set of creatures, a hero swing or a non-listed creature is illegal.
	if not _attack_target_allowed(attacker, target):
		return false
	var pair = CombatPair.new(attacker, target)
	pair.target_side = ts
	_attack_pairs[active_side].append(pair)
	attacker.has_attacked_this_turn = true
	attacker.times_attacked += 1
	# target is a CardInstance for a directed attack, or null when swinging at the hero.
	attacker._fire(CardInstance.Trigger.ON_ATTACK, {"target": target})
	_drain_triggers()
	return true


func declare_blocker(attacker: CardInstance, blocker: CardInstance) -> bool:
	## Passive-side action during DEFENSE: assign one of the passive side's
	## defenders to intercept an attacker declared by the active side. This
	## redirects that attack's damage to the blocker, overriding any directed
	## target. A blocker can only be assigned once per turn. Returns true if the
	## block was assigned; false if any precondition rejected it.
	if not CombatState.is_passive_action_phase(phase):
		return false
	if _combat_over:
		return false
	if attacker == null or blocker == null:
		return false
	# The blocker must belong to an enemy side of the active attacker (any enemy
	# team, not just a single passive side), and be one of that side's defenders.
	var blocker_side: int = blocker.owner_id
	if are_allies(blocker_side, active_side):
		return false
	if not decks[blocker_side].get_defenders().has(blocker):
		return false
	if blocker.is_dead:
		return false
	if _block_assignments.values().has(blocker):
		return false
	var pair: CombatPair = _find_attack_pair(attacker)
	if pair == null:
		return false
	pair.defender = blocker
	_block_assignments[attacker] = blocker
	blocker._fire(CardInstance.Trigger.ON_BLOCK, {"attacker": attacker})
	_drain_triggers()
	return true


func _find_attack_pair(attacker: CardInstance) -> CombatPair:
	for pair in _attack_pairs[active_side]:
		if pair.attacker == attacker:
			return pair
	return null


func _required_attack_targets(attacker: CardInstance) -> Array:
	## Creatures the attack_restriction_fn forces `attacker` to choose among (e.g. the
	## living enemy taunts). Empty when there is no hook or no restriction in play.
	## Single source for both the declare_attacker guard and the auto-play redirect.
	if not attack_restriction_fn.is_valid():
		return []
	return attack_restriction_fn.call(attacker, CardInstance.living(enemy_boards(active_side)))


func _attack_target_allowed(attacker: CardInstance, target: Variant) -> bool:
	## Enforce targeting restrictions: a creature with can_be_attacked=false is never
	## a valid target regardless of other rules; then the restriction hook (e.g. TAUNT)
	## must be satisfied if it narrows the required set.
	if target is CardInstance and not target.can_be_attacked:
		return false
	var required: Array = _required_attack_targets(attacker)
	if required.is_empty():
		return true
	return target is CardInstance and required.has(target)


func end_main_phase() -> void:
	if phase != CombatState.Phase.MAIN:
		return
	_transition_to(CombatState.Phase.ATTACK)


func end_attack_phase() -> void:
	if phase != CombatState.Phase.ATTACK:
		return
	# A spell in MAIN may have already killed a hero: settle victory first.
	_check_victory()
	if _combat_over:
		return
	_transition_to(CombatState.Phase.DEFENSE)


func end_defense_phase() -> void:
	if phase != CombatState.Phase.DEFENSE:
		return
	_transition_to(CombatState.Phase.RESOLVE)


func advance() -> void:
	## Manual driver for the phases that need an external nudge. PREPARATION and
	## RESOLVE auto-chain inside their _enter_* handlers, and END is terminal,
	## so only BEGIN and PREPARATION are actionable here.
	match phase:
		CombatState.Phase.BEGIN:
			start()
		CombatState.Phase.PREPARATION:
			# Auto-advance to MAIN
			_transition_to(CombatState.Phase.MAIN)


# --- Command layer (authoritative input / replay-from-input) ----------------
# apply_command validates a driver intention and routes it to the existing action
# methods, so a network peer or replay can drive the session by serializable
# commands. Cards/creatures are referenced by index (hand index, board index per
# side), matching how attack pairs serialize.

func apply_command(cmd: CombatCommand) -> bool:
	## Validate and route a command. Returns true only if the action took effect; on
	## success the command is appended to command_log. Rejects without mutating when a
	## precondition fails, so a bad/illegal command from a client is a no-op.
	if cmd == null or _combat_over:
		return false
	if not _route_command(cmd):
		return false
	command_log.append(cmd)
	return true


func _route_command(cmd: CombatCommand) -> bool:
	match cmd.type:
		CombatCommand.CommandType.PLAY_CARD:
			return _cmd_play_card(cmd)
		CombatCommand.CommandType.DECLARE_ATTACKER:
			return _cmd_declare_attacker(cmd)
		CombatCommand.CommandType.DECLARE_BLOCKER:
			return _cmd_declare_blocker(cmd)
		CombatCommand.CommandType.END_MAIN:
			return _cmd_end_phase(cmd.side, active_side, CombatState.Phase.MAIN, end_main_phase)
		CombatCommand.CommandType.END_ATTACK:
			return _cmd_end_phase(cmd.side, active_side, CombatState.Phase.ATTACK, end_attack_phase)
		CombatCommand.CommandType.END_DEFENSE:
			# Ending defense is any passive side's call (defense is a global phase).
			return _cmd_end_defense(cmd)
		CombatCommand.CommandType.ADVANCE:
			return _cmd_advance()
	return false


func _cmd_play_card(cmd: CombatCommand) -> bool:
	if cmd.side != active_side or phase != CombatState.Phase.MAIN:
		return false
	var hand: Array[CardData] = decks[cmd.side].get_hand()
	var hi: int = int(cmd.payload.get("hand_index", -1))
	if hi < 0 or hi >= hand.size():
		return false
	return play_card(
		hand[hi],
		cmd.payload.get("as_hidden", false),
		int(cmd.payload.get("declared_attack", 0)),
		int(cmd.payload.get("declared_health", 0)),
		_resolve_command_target(cmd.payload),
		# ENEMY_HERO spells: which enemy hero to hit (-1 = first living enemy).
		int(cmd.payload.get("hero_target_side", -1)),
	)


func _cmd_declare_attacker(cmd: CombatCommand) -> bool:
	# Command-layer authorization: only the active side declares attackers. The rest
	# of the preconditions (phase, board membership, summoning sickness) are the
	# action method's job, so we route and report its bool directly.
	if cmd.side != active_side:
		return false
	var attacker: CardInstance = _board_at(cmd.side, int(cmd.payload.get("attacker_index", -1)))
	# A creature target ({target_side,target_index}) takes precedence; otherwise
	# `hero_side` names which enemy hero to swing at (-1 = first living enemy).
	return declare_attacker(attacker, _resolve_command_target(cmd.payload), int(cmd.payload.get("hero_side", -1)))


func _cmd_declare_blocker(cmd: CombatCommand) -> bool:
	# Command-layer authorization: the declaring side must be an enemy of the active
	# attacker (any enemy team). Phase, defender membership and double-block are the
	# action method's job, so we route and report its bool directly.
	if are_allies(cmd.side, active_side):
		return false
	var attacker: CardInstance = _board_at(active_side, int(cmd.payload.get("attacker_index", -1)))
	var blocker: CardInstance = _board_at(cmd.side, int(cmd.payload.get("blocker_index", -1)))
	return declare_blocker(attacker, blocker)


func _cmd_end_defense(cmd: CombatCommand) -> bool:
	## Any passive side can end the (global) defense phase.
	if cmd.side == active_side or phase != CombatState.Phase.DEFENSE:
		return false
	var before: CombatState.Phase = phase
	end_defense_phase()
	return phase != before


func _cmd_end_phase(cmd_side: int, expected_side: int, required_phase: CombatState.Phase, ender: Callable) -> bool:
	## Phase-end commands report success by whether the phase actually changed (the
	## end_* methods are void and may also settle victory / auto-chain).
	if cmd_side != expected_side or phase != required_phase:
		return false
	var before: CombatState.Phase = phase
	ender.call()
	return phase != before


func _cmd_advance() -> bool:
	var before: CombatState.Phase = phase
	advance()
	return phase != before


func _resolve_command_target(payload: Dictionary) -> Variant:
	## Decode a creature target. Multi-target (CHOSEN_CREATURES) is encoded as
	## `target_specs`: an Array of {side, index} decoded into an Array[CardInstance].
	## Single-target is {target_side, target_index}; returns null (the hero, or "no
	## target") when either field is absent/negative.
	if payload.has("target_specs"):
		var chosen: Array[CardInstance] = []
		for spec in payload["target_specs"]:
			var inst: CardInstance = _board_at(int(spec.get("side", -1)), int(spec.get("index", -1)))
			if inst != null:
				chosen.append(inst)
		return chosen
	var ts: int = int(payload.get("target_side", -1))
	var ti: int = int(payload.get("target_index", -1))
	if ts < 0 or ti < 0:
		return null
	return _board_at(ts, ti)


func get_result() -> Dictionary:
	var hp: Array[int] = []
	for s in side_count():
		hp.append(heroes[s].current_health if heroes[s] != null else 0)
	return {
		"winner_side": winner_side,
		"winner_team": winner_team,
		"turn_number": turn_number,
		"hp": hp,
	}


func get_dead_creatures(side: int) -> Array:
	if decks[side] == null:
		return []
	return _dead_creatures[side]


# --- Side / team topology (single source for "who is enemy / ally") ----------
# These resolve relationships by `teams`, not by liveness, so they stay valid
# before combat and during board-only scenarios. Turn rotation / victory layer
# on liveness separately.

func side_count() -> int:
	return decks.size()


func are_allies(side_a: int, side_b: int) -> bool:
	## Whether two sides share a team. Single source of truth for team membership so
	## a future alliance model only has to change here.
	return teams[side_a] == teams[side_b]


func allies_of(side: int) -> Array[int]:
	## Sides on the same team as `side`, INCLUDING `side` itself (per design D1: a
	## PLAYER_CREATURES spell covers the caster's board and its teammates' boards).
	var out: Array[int] = []
	for s in side_count():
		if are_allies(s, side):
			out.append(s)
	return out


func enemies_of(side: int) -> Array[int]:
	## Sides on a different team from `side`. In 1v1 this is just the other side.
	var out: Array[int] = []
	for s in side_count():
		if not are_allies(s, side):
			out.append(s)
	return out


func passive_sides() -> Array[int]:
	## Every side other than the active one. Generalizes the old `1 - active_side`
	## single-passive assumption for N sides.
	var out: Array[int] = []
	for s in side_count():
		if s != active_side:
			out.append(s)
	return out


func enemy_boards(side: int) -> Array[CardInstance]:
	## Flattened living-or-not board of every enemy side, for AoE / multi-target
	## effects. Order follows side index.
	var out: Array[CardInstance] = []
	for s in enemies_of(side):
		out.append_array(decks[s].get_board())
	return out


func ally_boards(side: int) -> Array[CardInstance]:
	## Flattened board of every allied side (includes the caster's own, per D1).
	var out: Array[CardInstance] = []
	for s in allies_of(side):
		out.append_array(decks[s].get_board())
	return out


func _rebuild_turn_order() -> void:
	## Build the per-side turn order interleaving teams, so no team acts twice in a
	## row when another team still has a side to play (round-robin between teams).
	## Teams and sides keep their first-appearance order. 1v1 -> [0, 1]; FFA -> by
	## index; 2v2 teams=[0,0,1,1] -> [0, 2, 1, 3] (A1, B1, A2, B2).
	# Driven by teams.size(), not side_count(): setup_sides rebuilds the order right
	# after assigning teams, before the decks array is resized.
	var n: int = teams.size()
	_turn_order = []
	var team_order: Array[int] = []
	var groups: Dictionary = {}
	for s in n:
		var t: int = teams[s]
		if not groups.has(t):
			groups[t] = [] as Array[int]
			team_order.append(t)
		groups[t].append(s)
	var round_idx: int = 0
	while _turn_order.size() < n:
		for t in team_order:
			var g: Array = groups[t]
			if round_idx < g.size():
				_turn_order.append(g[round_idx])
		round_idx += 1


func _is_side_out(side: int) -> bool:
	## A side is out when its hero exists and is dead. A null hero (board-only
	## scenario) is never "out", matching the original victory guards.
	return heroes[side] != null and heroes[side].current_health <= 0


func _next_living_side() -> int:
	## Next side in turn order whose hero is still alive, cycling from the active one.
	## Falls back to the current active side if no other side is alive.
	if _turn_order.is_empty():
		return active_side
	var pos: int = _turn_order.find(active_side)
	if pos < 0:
		pos = 0
	for step in range(1, _turn_order.size() + 1):
		var cand: int = _turn_order[(pos + step) % _turn_order.size()]
		if not _is_side_out(cand):
			return cand
	return active_side


func _default_enemy_side(side: int) -> int:
	## First living enemy side (used when an attacker swings at "the hero" without
	## naming a side). -1 if there is no enemy at all.
	for s in enemies_of(side):
		if not _is_side_out(s):
			return s
	var en: Array[int] = enemies_of(side)
	return en[0] if not en.is_empty() else -1


func _living_teams() -> Array[int]:
	## Team ids with at least one side still in (hero alive or null). The combat ends
	## when this drops to one (or zero).
	var out: Array[int] = []
	for s in side_count():
		if not _is_side_out(s) and not out.has(teams[s]):
			out.append(teams[s])
	return out


func _first_living_side_of_team(team: int) -> int:
	for s in side_count():
		if teams[s] == team and not _is_side_out(s):
			return s
	return -1


# --- Serialization (save/resume + authoritative networking) ---------------
# The non-serializable hooks (config, ability_fn, damage_fn, exhaust_fn,
# discard_fn) and AIs are re-injected via the deserialize `hooks` dictionary;
# everything else is captured as primitives so the snapshot round-trips. Cross-
# references (attack pairs, blockers) are encoded by board index; dead creatures
# (already off-board) are stored as full instances.

## Serialization schema version. Bumped when the snapshot format changes so
## deserialize can branch on it; a save without the field is treated as legacy (0).
const SCHEMA_VERSION := 1


func serialize() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"phase": CombatState.Phase.keys()[phase],
		"active_side": active_side,
		"winner_side": winner_side,
		"winner_team": winner_team,
		"turn_number": turn_number,
		"combat_over": _combat_over,
		"trigger_mode": TriggerMode.keys()[trigger_mode],
		"teams": teams.duplicate(),
		"heroes": _map_sides(_serialize_hero),
		"decks": _map_sides(func(s: int) -> Dictionary: return decks[s].serialize()),
		"event_log": event_log.map(func(ev: CombatEvent) -> Dictionary: return ev.serialize()),
		"command_log": command_log.map(func(c: CombatCommand) -> Dictionary: return c.serialize()),
		"dead_creatures": _map_sides(_serialize_dead),
		"attack_pairs": _map_sides(_serialize_pairs),
		"block_assignments": _serialize_blocks(),
		# Per-side AI internal state (empty for a stateless AI). Lets a resumed combat
		# stay deterministic without re-injecting the AIs via deserialize hooks.
		"ai_states": _map_sides(func(s: int) -> Dictionary: return ais[s].serialize_state() if ais[s] != null else {}),
	}


func _map_sides(fn: Callable) -> Array:
	## Apply `fn(side)` over every side, in side order. Single source for the
	## per-side arrays in serialize(), so they all scale with side_count().
	var out: Array = []
	for s in side_count():
		out.append(fn.call(s))
	return out


func _serialize_hero(side: int) -> Variant:
	return heroes[side].serialize() if heroes[side] != null else null


func _serialize_dead(side: int) -> Array:
	return _dead_creatures[side].map(func(inst: CardInstance) -> Dictionary: return inst.serialize())


func _board_index(inst: CardInstance) -> int:
	## Inverse of _board_at: a creature's index on its own owner's board (-1 if it
	## is null or off-board). Single source for the index-encoded cross-references
	## (attack pairs, blockers) that serialize() round-trips.
	if inst == null:
		return -1
	return decks[inst.owner_id].get_board().find(inst)


func _serialize_pairs(side: int) -> Array:
	var out: Array = []
	for pair in _attack_pairs[side]:
		# Defenders can belong to any enemy side, so record the defender's side too.
		out.append({
			"attacker": _board_index(pair.attacker),
			"defender": _board_index(pair.defender),
			"defender_side": pair.defender.owner_id if pair.defender != null else -1,
			"target_side": pair.target_side,
		})
	return out


func _serialize_blocks() -> Array:
	var out: Array = []
	for attacker in _block_assignments:
		var blocker: CardInstance = _block_assignments[attacker]
		out.append({
			"attacker": _board_index(attacker),
			"blocker": _board_index(blocker),
			"blocker_side": blocker.owner_id,
		})
	return out


static func deserialize(data: Dictionary, hooks: Dictionary = {}) -> CombatSession:
	## Rebuilds a session from serialize(). `hooks` re-supplies the non-serializable
	## pieces: config, ability_fn, damage_fn, exhaust_fn, discard_fn, and optionally
	## `heroes` (for a game's subclassed hero) and `ais` (for deterministic resume).
	var session := CombatSession.new()
	# Schema version hook: absent = legacy (0). Kept so future format changes can
	# branch here; today every field tolerates absence via get(.., default).
	var _schema: int = int(data.get("schema_version", 0))
	session.config = hooks.get("config", CombatConfig.new())
	session.ability_fn = hooks.get("ability_fn", Callable())
	session.damage_fn = hooks.get("damage_fn", Callable())
	session.exhaust_fn = hooks.get("exhaust_fn", Callable())
	session.discard_fn = hooks.get("discard_fn", Callable())
	session.attack_restriction_fn = hooks.get("attack_restriction_fn", Callable())
	session._resolver.damage_fn = session.damage_fn
	session._restore_topology(data)
	session._restore_scalars(data)
	# Recompute the effective sink from the restored trigger_mode + ability_fn before
	# rebuilding decks, so resumed board instances fire through the right path.
	session._compute_effective_ability_fn()
	session._restore_heroes(data, hooks.get("heroes", null))
	session._restore_decks(data)
	session._restore_log(data)
	session._restore_command_log(data)
	session._restore_dead(data)
	session._restore_pairs_and_blocks(data)
	session._restore_ais(hooks.get("ais", null))
	session._restore_ai_states(data)
	session._rebuild_turn_order()
	return session


func _restore_topology(data: Dictionary) -> void:
	## Size every per-side array to the saved side count and restore `teams`. Older
	## two-side saves carry no "teams"; default them to one team per side.
	var n: int = (data.get("decks", []) as Array).size()
	var t: Array[int] = []
	for v in data.get("teams", []):
		t.append(int(v))
	# A teams array that does not cover every side would index out of bounds in
	# are_allies; fall back to one team per side rather than trust a corrupt save.
	if not t.is_empty() and t.size() != n:
		push_warning("CombatSession: teams size %d != side count %d — using default teams" % [t.size(), n])
		t = []
	teams = t if not t.is_empty() else _default_teams(n)
	_init_side_arrays(n)


func _restore_scalars(data: Dictionary) -> void:
	var idx: int = CombatState.Phase.keys().find(data.get("phase", "BEGIN"))
	phase = (idx if idx != -1 else CombatState.Phase.BEGIN) as CombatState.Phase
	active_side = int(data.get("active_side", 0))
	winner_side = int(data.get("winner_side", -1))
	winner_team = int(data.get("winner_team", -1))
	turn_number = int(data.get("turn_number", 0))
	_combat_over = data.get("combat_over", false)
	# Legacy saves (no trigger_mode) default to INLINE, the pre-feature behavior.
	var tm_idx: int = TriggerMode.keys().find(data.get("trigger_mode", "INLINE"))
	trigger_mode = (tm_idx if tm_idx != -1 else TriggerMode.INLINE) as TriggerMode


func _restore_heroes(data: Dictionary, override: Variant) -> void:
	var raw: Array = data.get("heroes", [])
	var has_override: bool = override is Array and override.size() == side_count()
	for side in side_count():
		var raw_hero: Variant = raw[side] if side < raw.size() else null
		if has_override and override[side] != null:
			heroes[side] = override[side]
			if raw_hero is Dictionary:
				heroes[side].current_health = int(raw_hero.get("current_health", heroes[side].current_health))
		elif raw_hero is Dictionary:
			heroes[side] = Combatant.deserialize(raw_hero)
		else:
			heroes[side] = null


func _restore_decks(data: Dictionary) -> void:
	var deck_hooks: Dictionary = _deck_hooks()
	var raw: Array = data.get("decks", [])
	for side in side_count():
		decks[side] = CombatDeck.deserialize(raw[side], deck_hooks)
		_wire_deck_events(decks[side])


func _restore_log(data: Dictionary) -> void:
	var log: Array[CombatEvent] = []
	for ed in data.get("event_log", []):
		log.append(CombatEvent.deserialize(ed))
	event_log = log


func _restore_command_log(data: Dictionary) -> void:
	var log: Array[CombatCommand] = []
	for cd in data.get("command_log", []):
		log.append(CombatCommand.deserialize(cd))
	command_log = log


func _restore_dead(data: Dictionary) -> void:
	var raw: Array = data.get("dead_creatures", [])
	for side in side_count():
		if side >= raw.size():
			continue
		for d in raw[side]:
			_dead_creatures[side].append(CardInstance.deserialize(d, ability_fn))


func _restore_pairs_and_blocks(data: Dictionary) -> void:
	var raw_pairs: Array = data.get("attack_pairs", [])
	for side in side_count():
		if side >= raw_pairs.size():
			continue
		for p in raw_pairs[side]:
			var attacker: CardInstance = _board_at(side, int(p.get("attacker", -1)))
			if attacker == null:
				push_warning("CombatSession: dropping attack pair with missing attacker on side %d" % side)
				continue
			# Older saves lack defender_side; fall back to the lone opponent (1 - side).
			var def_side: int = int(p.get("defender_side", 1 - side))
			var defender: Variant = _board_at(def_side, int(p.get("defender", -1)))
			var pair := CombatPair.new(attacker, defender)
			pair.target_side = int(p.get("target_side", -1))
			_attack_pairs[side].append(pair)
	_block_assignments.clear()
	for b in data.get("block_assignments", []):
		var atk: CardInstance = _board_at(active_side, int(b.get("attacker", -1)))
		var blk_side: int = int(b.get("blocker_side", 1 - active_side))
		var blk: CardInstance = _board_at(blk_side, int(b.get("blocker", -1)))
		if atk != null and blk != null:
			_block_assignments[atk] = blk


func _board_at(side: int, idx: int) -> CardInstance:
	# Guard the side too: deserialized indices (e.g. a legacy 1 - side fallback under
	# an N-side topology) can point outside decks. Out of range resolves to null.
	if idx < 0 or side < 0 or side >= side_count():
		return null
	var board: Array[CardInstance] = decks[side].get_board()
	return board[idx] if idx < board.size() else null


func _restore_ais(override: Variant) -> void:
	if override is Array and override.size() == side_count():
		ais = override
	# Seed a reference AI for any side left without one. The saved ai_states are
	# applied afterwards (see _restore_ai_states) so a stateful AI (e.g. DummyAI's
	# RNG) resumes deterministically without re-injecting it via hooks.
	for side in side_count():
		_seed_ai(side, -1)


func _restore_ai_states(data: Dictionary) -> void:
	## Feed each side's saved AI state back through restore_state(). Stateless AIs
	## (empty dict / default no-op) are unaffected; a DummyAI rebuilds its RNG.
	var raw: Array = data.get("ai_states", [])
	for side in side_count():
		if side < raw.size() and raw[side] is Dictionary and not (raw[side] as Dictionary).is_empty():
			ais[side].restore_state(raw[side])


func auto_resolve() -> void:
	## Drives the whole combat headless using the per-side AIs in `ais` (seeded in
	## setup, or injected by a driver before setup). Deterministic for a fixed seed.
	start()
	var iterations_left: int = _auto_resolve_max_iterations
	while phase != CombatState.Phase.END and not _combat_over and iterations_left > 0:
		iterations_left -= 1
		match phase:
			CombatState.Phase.MAIN:
				_auto_play_active()
				end_main_phase()
			CombatState.Phase.ATTACK:
				end_attack_phase()
			CombatState.Phase.DEFENSE:
				_auto_declare_blockers()
				end_defense_phase()
			CombatState.Phase.PREPARATION, CombatState.Phase.RESOLVE:
				pass
	if not _combat_over:
		# Loop exhausted before the combat resolved on its own: force END but
		# warn with diagnostics, since a silent termination hides a stuck combat.
		if iterations_left <= 0:
			push_warning("CombatSession.auto_resolve hit the iteration cap (%d) at turn %d, phase %s; forcing END" % [_auto_resolve_max_iterations, turn_number, CombatState.phase_name(phase)])
		_combat_over = true
		_transition_to(CombatState.Phase.END)


func _auto_play_active() -> void:
	## Headless turn of the active side: play its hand, then declare attackers
	## (optionally directed) via its AI.
	var side: int = active_side
	var deck: CombatDeck = decks[side]
	var side_ai: CombatAI = ais[side]
	_play_hand(deck, side, side_ai)
	var enemy_heroes: Array[Combatant] = _living_enemy_heroes(side)
	var enemy_board: Array[CardInstance] = enemy_boards(side)
	var attackers: Array[CardInstance] = side_ai.choose_attackers(deck.get_board(), enemy_heroes)
	for attacker in attackers:
		# null -> swing at a hero; the engine routes it to the first living enemy side.
		var target: Variant = side_ai.choose_attack_target(attacker, enemy_board, enemy_heroes)
		# Redirect to a legal target when a restriction (e.g. TAUNT) applies, so the
		# attack isn't wasted on an illegal target the AI can't see.
		target = _redirect_for_restriction(attacker, target)
		declare_attacker(attacker, target)


func _redirect_for_restriction(attacker: CardInstance, chosen: Variant) -> Variant:
	## Map an AI's chosen target to a legal one. If chosen already passes
	## _attack_target_allowed (covers both can_be_attacked and TAUNT), keep it.
	## Otherwise force the first required creature (TAUNT), or null (hero swing)
	## when there is no required set. Keeps auto_resolve deterministic without
	## teaching the AI about TAUNT or STEALTH.
	if _attack_target_allowed(attacker, chosen):
		return chosen
	var required: Array = _required_attack_targets(attacker)
	if not required.is_empty():
		return required[0]
	return null


func _living_enemy_heroes(side: int) -> Array[Combatant]:
	## Heroes of every living enemy side, for the AI's lethal reasoning.
	var out: Array[Combatant] = []
	for s in enemies_of(side):
		if not _is_side_out(s) and heroes[s] != null:
			out.append(heroes[s])
	return out


func _auto_declare_blockers() -> void:
	## Headless defense: each enemy side of the active attacker assigns blockers from
	## its own defenders, via that side's AI. Generalizes the old single-passive path.
	var attackers: Array[CardInstance] = []
	for pair in _attack_pairs[active_side]:
		attackers.append(pair.attacker)
	if attackers.is_empty():
		return
	for s in enemies_of(active_side):
		if _is_side_out(s):
			continue
		var def_ai: CombatAI = ais[s]
		var own_board: Array[CardInstance] = decks[s].get_defenders()
		var blocks: Dictionary = def_ai.choose_blockers(attackers, own_board)
		for attacker in blocks:
			declare_blocker(attacker, blocks[attacker])


func _snapshot_hand(deck: CombatDeck) -> Array[CardData]:
	## Typed copy of a deck's hand, so the AI sees a stable list while we mutate
	## the real hand by playing cards out of it.
	var hand: Array[CardData] = []
	for card in deck.get_hand():
		hand.append(card)
	return hand


func _play_hand(deck: CombatDeck, side: int, side_ai: CombatAI) -> void:
	## Plays cards from `side`'s hand until the AI passes or the per-turn cap is
	## hit. Shared by both sides' auto-play so spells and creatures resolve the
	## same way regardless of who is active. A single-target spell asks the AI for
	## a target; if none fits it is skipped (not consumed) and hidden from the AI
	## for the rest of the turn so it isn't re-picked uselessly.
	var skipped: Array[CardData] = []
	var card_to_play: CardData = side_ai.choose_card_to_play(_playable_hand(deck, skipped), deck.mana)
	var plays: int = 0
	while card_to_play != null and plays < MAX_PLAYS_PER_TURN:
		if card_to_play.play_kind == CardData.PlayKind.EFFECT:
			var target: Variant = _ai_spell_target(card_to_play, side, side_ai)
			if _spell_needs_missing_target(card_to_play, target):
				skipped.append(card_to_play)
			else:
				deck.play_spell(card_to_play)
				_apply_spell_effects(card_to_play, side, target)
				plays += 1
		else:
			deck.play_creature(card_to_play)
			plays += 1
		card_to_play = side_ai.choose_card_to_play(_playable_hand(deck, skipped), deck.mana)


func _ai_spell_target(card: CardData, side: int, side_ai: CombatAI) -> Variant:
	## Consult the AI for a spell that needs explicit targets (single PLAYER_CREATURE
	## or multi CHOSEN_CREATURES). The AI returns a CardInstance or an Array depending
	## on the spell; other spells resolve relative to the caster and need no target.
	if not _spell_needs_explicit_target(card):
		return null
	return side_ai.choose_spell_target(card, ally_boards(side), enemy_boards(side))


func _spell_needs_explicit_target(card: CardData) -> bool:
	for effect in card.spell_effects:
		if effect.target_type == SpellEffect.TargetType.PLAYER_CREATURE:
			return true
		if effect.target_type == SpellEffect.TargetType.CHOSEN_CREATURES:
			return true
	return false


func _playable_hand(deck: CombatDeck, skipped: Array[CardData]) -> Array[CardData]:
	## Hand snapshot minus cards already skipped this turn (e.g. untargetable
	## single-target spells), so the AI doesn't keep re-picking them.
	var hand: Array[CardData] = []
	for card in _snapshot_hand(deck):
		if not skipped.has(card):
			hand.append(card)
	return hand


func _transition_to(new_phase: CombatState.Phase) -> void:
	var old_phase: CombatState.Phase = phase
	phase = new_phase
	_emit_phase_changed(old_phase, new_phase)
	_enter_phase(new_phase)


# --- Signal + event-log emitters (single source for each combat event) ---
# Each helper emits the signal AND appends a structured CombatEvent, so existing
# listeners keep working while event_log offers a replay-friendly stream.

func _emit_phase_changed(old_phase: int, new_phase: int) -> void:
	phase_changed.emit(old_phase, new_phase)
	event_log.append(CombatEvent.new(CombatEvent.EventType.PHASE_CHANGED, {
		"old_phase": old_phase, "new_phase": new_phase,
	}))


func _emit_combatant_damaged(side: int, amount: int) -> void:
	combatant_damaged.emit(side, amount)
	event_log.append(CombatEvent.new(CombatEvent.EventType.COMBATANT_DAMAGED, {
		"side": side, "amount": amount,
	}))


func _emit_combatant_healed(side: int, amount: int) -> void:
	combatant_healed.emit(side, amount)
	event_log.append(CombatEvent.new(CombatEvent.EventType.COMBATANT_HEALED, {
		"side": side, "amount": amount,
	}))


func _card_id_of(card: CardData) -> String:
	## Null-safe card id for event payloads (a missing card logs an empty id).
	return card.card_id if card != null else ""


func _inst_card_id(inst: CardInstance) -> String:
	## Null-safe card id reached through a CardInstance's CardData.
	return _card_id_of(inst.card_data) if inst != null else ""


func _emit_creature_died(card: CardInstance, owner: int) -> void:
	creature_died.emit(card, owner)
	event_log.append(CombatEvent.new(CombatEvent.EventType.CREATURE_DIED, {
		"owner": owner, "card_id": _inst_card_id(card),
	}))


func _emit_creature_summoned(card: CardInstance, owner: int) -> void:
	creature_summoned.emit(card, owner)
	event_log.append(CombatEvent.new(CombatEvent.EventType.CREATURE_SUMMONED, {
		"owner": owner, "card_id": _inst_card_id(card),
	}))


func _emit_combat_ended(winner: int) -> void:
	combat_ended.emit(winner)
	event_log.append(CombatEvent.new(CombatEvent.EventType.COMBAT_ENDED, {"winner_side": winner}))


func _emit_spell_fizzled(card: CardData) -> void:
	spell_fizzled.emit(card)
	event_log.append(CombatEvent.new(CombatEvent.EventType.SPELL_FIZZLED, {"card_id": _card_id_of(card)}))


# Card-level events mirrored from the per-side decks. The deck still emits its own
# signals for live listeners; here we only append the serializable record so the
# event_log is a complete, replay-friendly stream.

func _emit_card_drawn(card: CardData, owner: int) -> void:
	event_log.append(CombatEvent.new(CombatEvent.EventType.CARD_DRAWN, {"owner": owner, "card_id": _card_id_of(card)}))


func _emit_card_played(inst: CardInstance, owner: int) -> void:
	event_log.append(CombatEvent.new(CombatEvent.EventType.CARD_PLAYED, {"owner": owner, "card_id": _inst_card_id(inst)}))


func _emit_mana_changed(owner: int, new_mana: int) -> void:
	event_log.append(CombatEvent.new(CombatEvent.EventType.MANA_CHANGED, {"owner": owner, "new_mana": new_mana}))


func _emit_max_mana_changed(owner: int, new_max: int) -> void:
	event_log.append(CombatEvent.new(CombatEvent.EventType.MAX_MANA_CHANGED, {"owner": owner, "new_max": new_max}))


func _emit_deck_exhausted(owner: int) -> void:
	event_log.append(CombatEvent.new(CombatEvent.EventType.DECK_EXHAUSTED, {"owner": owner}))


func _enter_phase(p: CombatState.Phase) -> void:
	# MAIN, ATTACK and DEFENSE have no on-enter work: they wait for driver actions
	# (play_card / declare_* / end_*). DEFENSE in particular is driver-driven
	# (declare_blocker / auto_resolve); the engine does not auto-assign blockers,
	# which would assume the passive side is an AI.
	match p:
		CombatState.Phase.PREPARATION:
			_enter_preparation()
		CombatState.Phase.RESOLVE:
			_enter_resolve()
		CombatState.Phase.END:
			_enter_end()


func _enter_preparation() -> void:
	turn_number += 1

	# Only the active side ramps mana, draws and refreshes on its own turn.
	var deck: CombatDeck = decks[active_side]
	_ramp_mana_for(deck)
	deck.draw_card()
	deck.refresh_creatures_for_turn()
	_fire_turn_trigger(active_side, CardInstance.Trigger.ON_TURN_START)
	# Fire the deferred prep triggers (ON_DRAW / ON_TURN_REFRESH / ON_TURN_START) in
	# FIFO order before MAIN (QUEUED); no-op in INLINE.
	_drain_triggers()

	# Clear the active side's attack state from its previous turn.
	_attack_pairs[active_side].clear()
	_block_assignments.clear()

	# Auto-advance to MAIN
	_transition_to(CombatState.Phase.MAIN)


func _ramp_mana_for(deck: CombatDeck) -> void:
	## Per-turn mana: refill to the current max, then ramp the max up toward
	## config.max_mana_cap. Same rule for both sides; extracted to keep it single-
	## sourced.
	deck.gain_mana(deck.max_mana)
	if deck.max_mana < config.max_mana_cap:
		deck.increment_max_mana(mini(config.mana_ramp_per_turn, config.max_mana_cap - deck.max_mana))


func _enter_resolve() -> void:
	# Resolve the active side's declared attacks against its enemies.
	_resolve_active_attacks()
	_attack_pairs[active_side].clear()
	_block_assignments.clear()

	_check_victory()
	if _combat_over:
		return

	# End-of-turn triggers for the active side's surviving creatures, before the swap.
	_fire_turn_trigger(active_side, CardInstance.Trigger.ON_TURN_END)
	_drain_triggers()

	# Hand the turn to the next living side (interleaved by team).
	active_side = _next_living_side()
	_transition_to(CombatState.Phase.PREPARATION)


func _resolve_active_attacks() -> void:
	## Resolves the active side's declared attacks. Creature trades are handled by the
	## resolver; unblocked hero attacks deal their damage to the hero of each pair's
	## target_side, aggregated per side so each hit emits one combatant_damaged.
	var pairs: Array = _attack_pairs[active_side]
	if pairs.is_empty():
		return
	var result: Dictionary = _resolver.resolve_combat(pairs)
	var pairs_result: Array = result["pairs_result"]
	var hero_damage_by_side: Dictionary = {}
	for i in pairs.size():
		if pairs[i].defender == null:
			var s: int = pairs[i].target_side
			hero_damage_by_side[s] = hero_damage_by_side.get(s, 0) + pairs_result[i]["attacker_damage_dealt"]
	for s in hero_damage_by_side:
		deal_damage_to_hero(s, hero_damage_by_side[s])
	if not pairs_result.is_empty():
		_fire_damage_dealt(pairs_result)
		# Drain combat triggers (ON_DAMAGE_TAKEN/ON_DEATH/ON_DAMAGE_DEALT) before
		# recording deaths, so abilities run before creature_died like in INLINE.
		_drain_triggers()
		_process_death_results(pairs_result)


func _fire_turn_trigger(side: int, trigger: CardInstance.Trigger) -> void:
	## Fire a per-side turn trigger (ON_TURN_START / ON_TURN_END) on every living
	## creature of `side`. Reuses CardInstance.living so dead creatures are skipped.
	for inst in CardInstance.living(decks[side].get_board()):
		inst._fire(trigger, {"side": side})


func _fire_damage_dealt(pairs_result: Array) -> void:
	## Surface ON_DAMAGE_DEALT for each attacker/defender that dealt combat damage.
	## Fires after the damage was applied (so ON_DAMAGE_TAKEN/ON_DEATH already ran on
	## the victims); a dealer that died in the trade still reports the hit it landed.
	## Spells have no creature dealer, so they never fire ON_DAMAGE_DEALT.
	for pr in pairs_result:
		var attacker: CardInstance = pr["attacker"]
		var defender: Variant = pr["defender"]
		if pr["attacker_damage_dealt"] > 0:
			attacker._fire(CardInstance.Trigger.ON_DAMAGE_DEALT, {"target": defender, "amount": pr["attacker_damage_dealt"]})
		if defender != null and pr["defender_damage_dealt"] > 0:
			defender._fire(CardInstance.Trigger.ON_DAMAGE_DEALT, {"target": attacker, "amount": pr["defender_damage_dealt"]})


func _enter_end() -> void:
	if not _combat_over:
		_combat_over = true
	_resolve_winner()
	_emit_combat_ended(winner_side)


func _resolve_winner() -> void:
	## Last team standing wins: if exactly one team still has a living side, that team
	## wins. Anything else (all teams out, or a stalemate with several alive) is no
	## winner (-1). winner_side reports a representative living side of the winning
	## team, so 1v1 keeps returning 0 / 1 as before.
	var living: Array[int] = _living_teams()
	if living.size() == 1:
		winner_team = living[0]
		winner_side = _first_living_side_of_team(winner_team)
	else:
		winner_team = -1
		winner_side = -1


func _process_death_results(pairs_result: Array) -> void:
	# Record the resolver-known deaths first, in pair order, so their creature_died
	# sequence is preserved exactly as before.
	for pr in pairs_result:
		var attacker: CardInstance = pr["attacker"]
		var defender: Variant = pr["defender"]
		if pr["attacker_died"]:
			_record_death(attacker)
		if defender != null and pr["defender_died"]:
			_record_death(defender)
	# Then sweep every board so collateral deaths from combat triggers (a reflect /
	# thorns chain, or a kill landed during a QUEUED drain) surface like spell deaths:
	# recorded AND removed, not silently dropped by a blind board cleanup. _record_death
	# is idempotent, so the deaths recorded above are not doubled.
	_sweep_all_boards()


func _record_death(inst: CardInstance) -> void:
	## Idempotent: a creature is recorded and announced once. This lets spell
	## resolution sweep boards repeatedly without double-emitting creature_died.
	var side: int = inst.owner_id
	if _dead_creatures[side].has(inst):
		return
	_dead_creatures[side].append(inst)
	_emit_creature_died(inst, side)


func _check_victory() -> void:
	# Combat ends once at most one team has a living side. A null hero (board-only
	# scenario) counts as alive, matching the original guards, so those resolve via
	# stalemate instead of a hero death.
	if _living_teams().size() <= 1 or _is_stalemate():
		_combat_over = true
		_transition_to(CombatState.Phase.END)


func _is_stalemate() -> bool:
	# Stalemate when every side has no cards left anywhere, or the turn cap is hit.
	var all_empty: bool = true
	for s in side_count():
		var deck: CombatDeck = decks[s]
		if deck.hand_size != 0 or deck.board_size != 0 or deck.draw_pile_size != 0:
			all_empty = false
			break
	if all_empty:
		return true
	if turn_number >= config.stalemate_turn_limit:
		return true
	return false


func _apply_spell_effects(card: CardData, side: int, target: Variant = null, target_side: int = -1) -> void:
	for effect in card.spell_effects:
		_apply_single_spell_effect(effect, side, target, target_side)


func _resolve_enemy_hero_side(side: int, target_side: int) -> int:
	## Which enemy hero an ENEMY_HERO spell hits: an explicit, valid enemy
	## target_side when given, otherwise the first living enemy side. -1 if there is
	## no enemy at all. In 1v1 a default (-1) resolves to the lone opponent, so the
	## old `1 - side` behavior is preserved.
	if target_side >= 0 and target_side < side_count() and not are_allies(target_side, side):
		return target_side
	return _default_enemy_side(side)


func _apply_effect_and_sweep(effect: SpellEffect, target: Variant, context: Dictionary) -> void:
	## Apply an effect that can kill across any board (AOE / custom effect_fn / ad-hoc
	## hero effect_fn), then sweep every board so the deaths surface like any other.
	## Single source for the "apply then sweep" pair shared by play_spell and the
	## multi-target / hero-effect_fn branches of _apply_single_spell_effect.
	effect.apply(target, context)
	# Resolve deferred spell triggers (ON_DAMAGE_TAKEN/ON_DEATH and any chained
	# trigger) before sweeping, so chained kills surface in the same sweep (QUEUED);
	# no-op in INLINE.
	_drain_triggers()
	_sweep_all_boards()


func _apply_single_spell_effect(effect: SpellEffect, side: int, target: Variant = null, target_side: int = -1) -> void:
	## Agnostic resolution from the caster's perspective (`side`). TargetType is
	## interpreted relative to the caster, so the same spell serves both sides with no
	## duplicated logic. Each branch with real logic lives in a private helper below;
	## this dispatcher only builds the shared context and routes by target_type.
	# Unified context for every effect.apply path, so a custom effect_fn always
	# receives the session and the casting side (it reaches heroes with full
	# observability via context["session"].deal_damage_to_hero / heal_hero).
	var context: Dictionary = {"session": self, "owner_id": side}
	match effect.target_type:
		SpellEffect.TargetType.ENEMY_HERO:
			_apply_enemy_hero_effect(effect, side, target_side, context)
		SpellEffect.TargetType.PLAYER_HERO:
			_apply_player_hero_effect(effect, side, context)
		SpellEffect.TargetType.PLAYER_CREATURE:
			_apply_player_creature_effect(effect, target, context)
		SpellEffect.TargetType.ENEMY_CREATURES:
			# "All enemies" resolves by teams: every enemy side's board, not a single
			# opponent. In 1v1 this is the one other board, so behavior is unchanged.
			_apply_effect_and_sweep(effect, enemy_boards(side), context)
		SpellEffect.TargetType.PLAYER_CREATURES:
			# "All allies" covers the caster's own board AND its teammates' (D1). A
			# built-in buff can't kill, but a custom effect_fn could; sweep regardless.
			_apply_effect_and_sweep(effect, ally_boards(side), context)
		SpellEffect.TargetType.SUMMON_BOARD:
			_apply_summon_effect(effect, side, context)
		SpellEffect.TargetType.CHOSEN_CREATURES:
			# Bounded multi-target: `target` is the caller-chosen Array of creatures.
			_apply_chosen_creatures(effect, target, context)


func _apply_enemy_hero_effect(effect: SpellEffect, side: int, target_side: int, context: Dictionary) -> void:
	# Resolve which enemy hero is hit by team (explicit target_side or first living
	# enemy), not by `1 - side`, so FFA / team games target correctly. A custom
	# effect_fn overrides hero damage entirely; the default keeps the engine's
	# signaled hero-damage so the event_log stays consistent.
	var enemy_side: int = _resolve_enemy_hero_side(side, target_side)
	if enemy_side < 0:
		return
	if effect.effect_fn.is_valid():
		_apply_effect_and_sweep(effect, heroes[enemy_side], context)
	else:
		deal_damage_to_hero(enemy_side, effect.value)


func _apply_player_hero_effect(effect: SpellEffect, side: int, context: Dictionary) -> void:
	if effect.effect_fn.is_valid():
		_apply_effect_and_sweep(effect, heroes[side], context)
	else:
		heal_hero(side, effect.value)


func _apply_player_creature_effect(effect: SpellEffect, target: Variant, context: Dictionary) -> void:
	# Public casting via play_card() already rejects a missing target before consuming
	# (see _spell_needs_missing_target). This is a low-level guard for internal callers
	# (e.g. auto-play) that bypass that check.
	if target is CardInstance and not target.is_dead:
		# Sweep every board, not just the target's: a built-in single-target damage
		# only kills the target, but an injected effect_fn can hit other sides
		# collaterally, and those deaths must surface like any other.
		_apply_effect_and_sweep(effect, target, context)
	else:
		push_warning("PLAYER_CREATURE spell with no valid target — not applied")


func _apply_chosen_creatures(effect: SpellEffect, target: Variant, context: Dictionary) -> void:
	# Apply the effect to each caster-chosen creature individually, reusing the
	# single-target apply (DAMAGE / HEAL / BUFF_ATTACK). Public casting already
	# rejects a target list shorter than target_count before consuming (fizzle); this
	# is the low-level resolution. Drain + sweep once at the end so chained deaths
	# surface like any other multi-target spell.
	if not (target is Array):
		push_warning("CHOSEN_CREATURES spell with no creature list — not applied")
		return
	for inst in target:
		if inst is CardInstance and not inst.is_dead:
			effect.apply(inst, context)
	_drain_triggers()
	_sweep_all_boards()


func _apply_summon_effect(effect: SpellEffect, side: int, context: Dictionary) -> void:
	# Seed the deck-owned hooks via context so _apply_summon builds the instances
	# already configured (fires ON_SETUP with the handler).
	var caster_deck: CombatDeck = decks[side]
	context["ability_fn"] = caster_deck.ability_fn
	context["max_permanent_buffs"] = caster_deck.max_permanent_buffs
	var result: Dictionary = effect.apply(null, context)
	var summoned: Array = result.get("summoned", [])
	for inst in summoned:
		caster_deck.add_to_board(inst)
		# Spell summons bypass play_creature (no CARD_PLAYED), so emit a dedicated
		# event/signal; otherwise a log-only replay never sees the creature appear.
		_emit_creature_summoned(inst, side)


func deal_damage_to_hero(side: int, amount: int) -> void:
	## Public hero-damage entry: applies damage AND emits combatant_damaged (so it
	## enters the event_log / replay). Shared by combat resolution, the built-in
	## ENEMY_HERO spell, and any effect_fn that wants to hit a hero with full
	## observability (call it via context["session"]).
	if amount <= 0:
		return
	# A side may run headless without a hero (board-only scenarios), same guard as
	# _check_victory / _resolve_winner. Skip silently instead of crashing.
	if heroes[side] == null:
		return
	heroes[side].take_damage(amount)
	_emit_combatant_damaged(side, amount)


func heal_hero(side: int, amount: int) -> void:
	## Public hero-heal entry, counterpart of deal_damage_to_hero. Emits
	## combatant_healed with the ACTUAL amount restored (clamped at max health), so a
	## hero heal enters the event_log and a log-only replay reproduces it.
	if amount <= 0 or heroes[side] == null:
		return
	var before: int = heroes[side].current_health
	heroes[side].heal(amount)
	var healed: int = heroes[side].current_health - before
	if healed > 0:
		_emit_combatant_healed(side, healed)


func _check_board_deaths(deck: CombatDeck) -> void:
	## Spell-caused deaths must surface like combat deaths: record them (emits
	## creature_died, appends CREATURE_DIED to event_log, tracks get_dead_creatures)
	## before removing them from the board. Otherwise an AOE/single-target kill would
	## be invisible to the event_log and break replay.
	var dead: Array[CardInstance] = []
	for inst in deck.get_board():
		if inst.is_dead:
			dead.append(inst)
	for inst in dead:
		_record_death(inst)
		deck.remove_from_board(inst)


func _sweep_all_boards() -> void:
	## Sweep every side's board for spell-caused deaths, generalizing the old
	## two-deck sweep. A custom effect_fn can hit any side (allies included), so all
	## boards must be checked, not just the caster's and the lone opponent's.
	for s in side_count():
		_check_board_deaths(decks[s])
