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
##
## Supported keywords (declared per card as metadata = {"keywords": ["CHARGE", ...]}):
##   CHARGE    - can attack the turn it enters play (no summoning sickness)
##   IMMUNITY  - absorbs the next N hits (metadata["immunity_hits"], default 1; -1 = all)
##   LIFESTEAL - combat damage it deals heals its owner's hero by the same amount
##   TAUNT     - while alive, enemy attackers must target it (via taunt_restriction)
##   THORNS    - when hit, deals metadata["thorns"] (default 1) back to the dealer

const KEYWORD_CHARGE := "CHARGE"
const KEYWORD_IMMUNITY := "IMMUNITY"
const KEYWORD_LIFESTEAL := "LIFESTEAL"
const KEYWORD_TAUNT := "TAUNT"
const KEYWORD_THORNS := "THORNS"

## Weak reference to the session, used only by LIFESTEAL to heal the owner's hero
## through the session's observable API (heal_hero emits the heal event). Weak so the
## library never forms a RefCounted cycle with the session that holds its Callable
## (session -> ability_fn -> library -> session), mirroring _wire_deck_events.
var _session_ref: WeakRef


func _init(session: CombatSession = null) -> void:
	_session_ref = weakref(session)


func ability_handler(inst: Variant, trigger: int, context: Dictionary) -> void:
	## ability_fn entry point. Dispatches the supported keywords by trigger. Side-level
	## triggers (ON_DRAW) carry a null instance and no keyword work, so they are ignored.
	if not (inst is CardInstance):
		return
	var keywords: Array = _keywords_of(inst)
	if keywords.is_empty():
		return
	match trigger:
		CardInstance.Trigger.ON_SETUP:
			_apply_on_setup(inst, keywords)
		CardInstance.Trigger.ON_DAMAGE_DEALT:
			if keywords.has(KEYWORD_LIFESTEAL):
				_apply_lifesteal(inst, context)
		CardInstance.Trigger.ON_DAMAGE_TAKEN:
			if keywords.has(KEYWORD_THORNS):
				_apply_thorns(inst, context)


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
	## seeds the absorbed-hit counter.
	if keywords.has(KEYWORD_CHARGE) and inst.is_combatant:
		inst.can_attack_this_turn = true
	if keywords.has(KEYWORD_IMMUNITY):
		inst.immunity_hits_remaining = _immunity_hits(inst)


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


func _thorns_damage(inst: CardInstance) -> int:
	## Damage THORNS reflects: metadata["thorns"] (default 1).
	return int(inst.card_data.metadata.get("thorns", 1))


func _immunity_hits(inst: CardInstance) -> int:
	## Hits IMMUNITY absorbs: metadata["immunity_hits"] (default 1; -1 = all).
	return int(inst.card_data.metadata.get("immunity_hits", 1))


func _keywords_of(inst: CardInstance) -> Array:
	## The opaque keyword list a card declares in metadata. Empty when absent or wrong-typed.
	if inst.card_data == null:
		return []
	var kw: Variant = inst.card_data.metadata.get("keywords", [])
	return kw if kw is Array else []
