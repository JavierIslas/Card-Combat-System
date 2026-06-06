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

class_name AbilityLibrary
extends RefCounted
## Opt-in keyword library: a ready-made ability_fn + attack_restriction_fn pair that
## interprets a small set of common keywords declared in CardData.metadata["keywords"]
## (an opaque Array[String] the engine itself never reads). This is NOT part of the
## agnostic core: a game wires it in explicitly, or ignores it and writes its own
## handler. Wiring:
##
##   var lib := AbilityLibrary.new(session)
##   session.ability_fn = lib.ability_handler
##   session.attack_restriction_fn = lib.taunt_restriction
##   # Optional extra hooks, only needed for the keywords that use them:
##   session.incoming_damage_fn = lib.armor_damage      # ARMOR
##   session.spell_power_fn = lib.spell_power            # SPELLPOWER
##   session.aura_fn = lib.recompute_auras              # LORD
##
## Supported keywords (declared per card as metadata = {"keywords": ["CHARGE", ...]}):
##   CHARGE     - can attack the turn it enters play (no summoning sickness)
##   IMMUNITY   - absorbs the next N hits (metadata["immunity_hits"], default 1; -1 = all)
##   LIFESTEAL  - combat damage it deals heals its owner's hero by the same amount
##   TAUNT      - while alive, enemy attackers must target it (via taunt_restriction)
##   THORNS     - when hit, deals metadata["thorns"] (default 1) back to the dealer
##   STEALTH    - cannot be chosen as an attack target until it attacks (via can_be_attacked)
##   WINDFURY   - may attack metadata["windfury_attacks"] (default 2) times per turn
##   FREEZE     - the creatures it damages are frozen metadata["freeze_turns"] (default 1) turns
##   ARMOR      - reduces each incoming hit by metadata["armor"] (needs incoming_damage_fn wired)
##   BATTLECRY  - on play, deals metadata["battlecry_damage"] (default 1) to the chosen target
##   SPELLPOWER - adds metadata["spell_power"] to its owner's spell damage (needs spell_power_fn wired)
##   LORD       - buffs other friendly creatures by metadata["aura_attack"]/["aura_health"]
##                (default 1/1) while alive (needs aura_fn wired)
##   OVERKILL   - lethal combat damage with excess tramples metadata["overkill_factor"]
##                (default 1) x the excess to the slain creature's controller's hero
##   SPELLBURST - each time its owner casts a spell, gains metadata["spellburst_attack"]/
##                ["spellburst_health"] (default 1/1) as a permanent buff (recurring;
##                respects the permanent-buff cap). Reacts to the side-level ON_CAST
##
## When multiple restriction fns are needed (e.g. TAUNT + STEALTH), wire the composed
## callable instead of one fn alone:
##   session.attack_restriction_fn = AbilityLibrary.compose_restrictions(
##       [lib.taunt_restriction, lib.stealth_restriction]
##   )

const KEYWORD_CHARGE := "CHARGE"
const KEYWORD_IMMUNITY := "IMMUNITY"
const KEYWORD_LIFESTEAL := "LIFESTEAL"
const KEYWORD_STEALTH := "STEALTH"
const KEYWORD_TAUNT := "TAUNT"
const KEYWORD_THORNS := "THORNS"
const KEYWORD_WINDFURY := "WINDFURY"
const KEYWORD_FREEZE := "FREEZE"
const KEYWORD_ARMOR := "ARMOR"
const KEYWORD_BATTLECRY := "BATTLECRY"
const KEYWORD_SPELLPOWER := "SPELLPOWER"
const KEYWORD_LORD := "LORD"
const KEYWORD_OVERKILL := "OVERKILL"
const KEYWORD_SPELLBURST := "SPELLBURST"

## Continuous-modifier source id the LORD aura recompute owns on every buffed creature.
## A single aggregated key (replaced each recompute) keeps the buff idempotent.
const AURA_SOURCE_ID := "ability_library_lord"

## Weak reference to the session, used only by LIFESTEAL to heal the owner's hero
## through the session's observable API (heal_hero emits the heal event). Weak so the
## library never forms a RefCounted cycle with the session that holds its Callable
## (session -> ability_fn -> library -> session), mirroring _wire_deck_events.
var _session_ref: WeakRef


func _init(session: CombatSession = null) -> void:
	_session_ref = weakref(session)


static func compose_restrictions(fns: Array) -> Callable:
	## Chains multiple attack_restriction_fn callables so several keywords (e.g. TAUNT
	## and STEALTH) can coexist on the same session. Each fn receives the pool narrowed
	## by the previous one. If any fn restricts the pool the final pool is returned as
	## the mandatory target list; if none restrict, returns [] (no restriction), which
	## preserves the original single-fn contract.
	return func(attacker: CardInstance, enemies: Array) -> Array:
		var pool: Array = enemies
		var restricted := false
		for fn: Callable in fns:
			if not fn.is_valid():
				continue
			var result: Array = fn.call(attacker, pool)
			if not result.is_empty():
				pool = result
				restricted = true
		return pool if restricted else []


func ability_handler(inst: Variant, trigger: int, context: Dictionary) -> void:
	## ability_fn entry point. Dispatches the supported keywords by trigger. The
	## side-level ON_CAST carries a null instance and scans the caster's board itself, so
	## it is handled before the instance guard; the other side-level trigger (ON_DRAW)
	## has no keyword work and falls through the guard as a no-op.
	if trigger == CardInstance.Trigger.ON_CAST:
		_apply_spellburst(context)
		return
	if not (inst is CardInstance):
		return
	var keywords: Array = _keywords_of(inst)
	if keywords.is_empty():
		return
	match trigger:
		CardInstance.Trigger.ON_SETUP:
			_apply_on_setup(inst, keywords)
		CardInstance.Trigger.ON_ATTACK:
			if keywords.has(KEYWORD_STEALTH):
				inst.can_be_attacked = true
		CardInstance.Trigger.ON_DAMAGE_DEALT:
			if keywords.has(KEYWORD_LIFESTEAL):
				_apply_lifesteal(inst, context)
			if keywords.has(KEYWORD_FREEZE):
				_apply_freeze(inst, context)
			if keywords.has(KEYWORD_OVERKILL):
				_apply_overkill(inst, context)
		CardInstance.Trigger.ON_DAMAGE_TAKEN:
			if keywords.has(KEYWORD_THORNS):
				_apply_thorns(inst, context)
		CardInstance.Trigger.ON_PLAY:
			if keywords.has(KEYWORD_BATTLECRY):
				_apply_battlecry(inst, context)


func taunt_restriction(_attacker: CardInstance, enemy_creatures: Array) -> Array:
	## attack_restriction_fn entry point for TAUNT: restrict the attacker to the living
	## enemy creatures carrying the TAUNT keyword. No taunt present = empty list =
	## unrestricted. The attacker is unused (TAUNT restricts every attacker equally)
	## but kept for the hook signature.
	var taunts: Array = []
	for inst in enemy_creatures:
		if inst is CardInstance and not inst.is_dead and _keywords_of(inst).has(KEYWORD_TAUNT):
			taunts.append(inst)
	return taunts


func _apply_on_setup(inst: CardInstance, keywords: Array) -> void:
	## On-play keywords: CHARGE clears summoning sickness (combatants only); IMMUNITY
	## seeds the absorbed-hit counter; STEALTH hides the creature from attack targeting.
	if keywords.has(KEYWORD_CHARGE) and inst.is_combatant:
		inst.can_attack_this_turn = true
	if keywords.has(KEYWORD_IMMUNITY):
		inst.immunity_hits_remaining = _immunity_hits(inst)
	if keywords.has(KEYWORD_STEALTH) and inst.is_combatant:
		inst.can_be_attacked = false
	if keywords.has(KEYWORD_WINDFURY) and inst.is_combatant:
		inst.attacks_per_turn = _windfury_attacks(inst)


func _apply_lifesteal(inst: CardInstance, context: Dictionary) -> void:
	## Heal the dealer's hero by the combat damage just dealt. Needs the session to
	## reach the hero observably; a collected session (dead weakref) is a safe no-op.
	var session: CombatSession = _session_ref.get_ref()
	if session == null:
		return
	var amount: int = int(context.get("amount", 0))
	if amount > 0:
		session.heal_hero(inst.owner_id, amount)


func _apply_thorns(inst: CardInstance, context: Dictionary) -> void:
	## Reflect damage back at the dealer. `source` is the dealer carried in the
	## ON_DAMAGE_TAKEN context: a living CardInstance in combat, or null for sourceless
	## damage (spell / fatigue), which reflects nothing. A dead source is left alone.
	var source: Variant = context.get("source", null)
	if source is CardInstance and not source.is_dead:
		source.take_damage(_thorns_damage(inst), inst)


func _apply_freeze(inst: CardInstance, context: Dictionary) -> void:
	## FREEZE: the creature this one just dealt combat damage to is frozen. `target` is
	## the victim carried in the ON_DAMAGE_DEALT context (a living CardInstance, or null
	## for a hero hit, which freezes nothing).
	var target: Variant = context.get("target", null)
	if target is CardInstance and not target.is_dead:
		target.freeze(_freeze_turns(inst))


func _apply_battlecry(inst: CardInstance, context: Dictionary) -> void:
	## BATTLECRY: on play, deal metadata["battlecry_damage"] to the chosen target. `target`
	## is the on-play target carried in the ON_PLAY context (a living CardInstance, or null
	## when none was chosen, which does nothing).
	var target: Variant = context.get("target", null)
	if target is CardInstance and not target.is_dead:
		target.take_damage(_battlecry_damage(inst), inst)


func _apply_overkill(inst: CardInstance, context: Dictionary) -> void:
	## OVERKILL: lethal combat damage that exceeds the target's life tramples to the
	## slain creature's controller's hero. `lethal`/`excess` come from the engine's
	## ON_DAMAGE_DEALT context (excess is already 0 unless the hit killed the target).
	## The victim travels in context["target"]; its owner_id names the hero to hit, so
	## the excess always lands on the enemy that lost the creature. Needs the session to
	## reach the hero observably; a collected session (dead weakref) is a safe no-op.
	if not context.get("lethal", false):
		return
	var excess: int = int(context.get("excess", 0))
	if excess <= 0:
		return
	var victim: Variant = context.get("target", null)
	if not (victim is CardInstance):
		return
	var session: CombatSession = _session_ref.get_ref()
	if session == null:
		return
	session.deal_damage_to_hero(victim.owner_id, excess * _overkill_factor(inst))


func _apply_spellburst(context: Dictionary) -> void:
	## SPELLBURST: on the caster's ON_CAST, every living SPELLBURST creature on the
	## caster's board gains its permanent buff. Recurring (fires on each cast) and capped
	## by apply_permanent_buff, so it never exceeds the game's permanent-buff limit. Reads
	## the board off the session; a collected session (dead weakref) is a safe no-op.
	var session: CombatSession = _session_ref.get_ref()
	if session == null:
		return
	var owner: int = int(context.get("owner", -1))
	if owner < 0 or owner >= session.side_count():
		return
	for inst in CardInstance.living(session.decks[owner].get_board()):
		if _keywords_of(inst).has(KEYWORD_SPELLBURST):
			inst.apply_permanent_buff(_spellburst_attack(inst), _spellburst_health(inst))


func armor_damage(inst: Variant, amount: int, _source: Variant) -> int:
	## incoming_damage_fn for ARMOR: reduce each incoming hit by metadata["armor"]
	## (floored at 0). A creature without the ARMOR keyword (or armor 0) is unchanged, so
	## this is safe to wire for every instance. Signature matches CardInstance.incoming_damage_fn.
	if not (inst is CardInstance) or not _keywords_of(inst).has(KEYWORD_ARMOR):
		return amount
	return maxi(amount - int(inst.card_data.metadata.get("armor", 0)), 0)


func spell_power(owner_id: int) -> int:
	## spell_power_fn for SPELLPOWER: sum metadata["spell_power"] over the owner's living
	## board creatures carrying the keyword, so a "+N spell damage" minion boosts its
	## owner's damage spells. Needs the session (for the boards); a collected session
	## (dead weakref) contributes 0.
	var session: CombatSession = _session_ref.get_ref()
	if session == null:
		return 0
	var total: int = 0
	for inst in CardInstance.living(session.decks[owner_id].get_board()):
		if _keywords_of(inst).has(KEYWORD_SPELLPOWER):
			total += int(inst.card_data.metadata.get("spell_power", 0))
	return total


func recompute_auras(session: CombatSession) -> void:
	## aura_fn for LORD: idempotently buff every creature by the summed aura of the OTHER
	## living LORD creatures on its own board. Each creature carries a single aggregated
	## continuous modifier under AURA_SOURCE_ID, re-added (replaced) on every recompute, so
	## a lord entering or dying re-derives the totals without stacking.
	if session == null:
		return
	for side in session.side_count():
		var board: Array = CardInstance.living(session.decks[side].get_board())
		var total_attack: int = 0
		var total_health: int = 0
		for src in board:
			if _keywords_of(src).has(KEYWORD_LORD):
				total_attack += int(src.card_data.metadata.get("aura_attack", 1))
				total_health += int(src.card_data.metadata.get("aura_health", 1))
		for inst in board:
			# A lord does not buff itself: subtract its own contribution from the total.
			var attack_delta: int = total_attack
			var health_delta: int = total_health
			if _keywords_of(inst).has(KEYWORD_LORD):
				attack_delta -= int(inst.card_data.metadata.get("aura_attack", 1))
				health_delta -= int(inst.card_data.metadata.get("aura_health", 1))
			if attack_delta != 0 or health_delta != 0:
				inst.add_continuous_modifier(AURA_SOURCE_ID, attack_delta, health_delta)
			else:
				inst.remove_continuous_modifier(AURA_SOURCE_ID)


func _overkill_factor(inst: CardInstance) -> int:
	## Multiplier OVERKILL applies to the excess that tramples: metadata["overkill_factor"]
	## (default 1 = the raw excess).
	return int(inst.card_data.metadata.get("overkill_factor", 1))


func _spellburst_attack(inst: CardInstance) -> int:
	## Attack SPELLBURST grants per cast: metadata["spellburst_attack"] (default 1).
	return int(inst.card_data.metadata.get("spellburst_attack", 1))


func _spellburst_health(inst: CardInstance) -> int:
	## Health SPELLBURST grants per cast: metadata["spellburst_health"] (default 1).
	return int(inst.card_data.metadata.get("spellburst_health", 1))


func _windfury_attacks(inst: CardInstance) -> int:
	## Attacks WINDFURY grants: metadata["windfury_attacks"] (default 2).
	return int(inst.card_data.metadata.get("windfury_attacks", 2))


func _freeze_turns(inst: CardInstance) -> int:
	## Turns FREEZE applies: metadata["freeze_turns"] (default 1).
	return int(inst.card_data.metadata.get("freeze_turns", 1))


func _battlecry_damage(inst: CardInstance) -> int:
	## Damage BATTLECRY deals to its target: metadata["battlecry_damage"] (default 1).
	return int(inst.card_data.metadata.get("battlecry_damage", 1))


func _thorns_damage(inst: CardInstance) -> int:
	## Damage THORNS reflects: metadata["thorns"] (default 1).
	return int(inst.card_data.metadata.get("thorns", 1))


func _immunity_hits(inst: CardInstance) -> int:
	## Hits IMMUNITY absorbs: metadata["immunity_hits"] (default 1; -1 = all).
	return int(inst.card_data.metadata.get("immunity_hits", 1))


func wire_all() -> void:
	## Convenience method that wires all library hooks into the session passed to the
	## constructor at once. Reduces 5 lines of manual wiring to a single call. Safe to
	## call multiple times (idempotent). No-op if the session has been freed. Only wires
	## hooks the library owns; STEALTH uses can_be_attacked (flag-based) and does not
	## need an attack_restriction_fn.
	var session: CombatSession = _session_ref.get_ref()
	if session == null:
		return
	session.ability_fn = ability_handler
	session.attack_restriction_fn = taunt_restriction
	session.incoming_damage_fn = armor_damage
	session.spell_power_fn = spell_power
	session.aura_fn = recompute_auras


func _keywords_of(inst: CardInstance) -> Array:
	## The opaque keyword list a card declares in metadata. Empty when absent or wrong-typed.
	if inst.card_data == null:
		return []
	var kw: Variant = inst.card_data.metadata.get("keywords", [])
	return kw if kw is Array else []
