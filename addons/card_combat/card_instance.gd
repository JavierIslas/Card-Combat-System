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

class_name CardInstance
extends RefCounted
## Live instance of a card on the combat board. Pure logic, no scene dependency.

signal card_died(card: CardInstance)
signal card_damaged(card: CardInstance, amount: int)
signal card_revealed(card: CardInstance)

## Lifecycle triggers. The ability handler (injected by the game via ability_fn)
## reacts to these points; the engine does not know the concrete semantics of each
## ability. Each trigger fire carries a context Dictionary (see ability_fn).
##
## Instance-bound triggers fire on a concrete CardInstance: ON_SETUP,
## ON_TURN_REFRESH, ON_DEATH, ON_REVEAL, ON_ATTACK, ON_BLOCK, ON_DAMAGE_TAKEN,
## ON_DAMAGE_DEALT, ON_HEAL, ON_TURN_START, ON_TURN_END. The side-level ON_DRAW
## fires with a null instance (the drawn card is still CardData in hand), so a
## handler must tolerate inst == null and read context["card"] instead.
enum Trigger {
	ON_SETUP,
	ON_TURN_REFRESH,
	ON_DEATH,
	ON_REVEAL,
	ON_ATTACK,
	ON_BLOCK,
	ON_DAMAGE_TAKEN,
	ON_DAMAGE_DEALT,
	ON_HEAL,
	ON_TURN_START,
	ON_TURN_END,
	ON_DRAW,
}

var card_data: CardData = null
var owner_id: int = 0
var is_hidden: bool = false
var is_dead: bool = false
var hidden_stats: HiddenCardStats = null
## Whether this instance fights. Derived from card_data.play_kind in setup (UNIT =
## true; PERSISTENT = false): a non-combatant persists on the board and fires
## triggers but never attacks or blocks. The engine reads this, not play_kind, so
## the combat checks stay a single boolean. Single source = play_kind.
var is_combatant: bool = true

var current_attack: int = 0
var current_health: int = 0
## Current maximum health of the instance (includes permanent buffs). It is the
## cap that heal() respects. The engine does not derive it from game rules.
var current_max_health: int = 0
var can_attack_this_turn: bool = false
## Damage absorbed this turn. The engine writes it (take_damage) and resets it on
## turn refresh, but never reads it: it is a read hook for the game layer, e.g. an
## ability that retaliates based on how much it was hurt this turn.
var damage_taken_this_turn: int = 0
## Attack counter for the turn. The engine only resets it and round-trips it; it
## does not increment it. Single-attack rules use has_attacked_this_turn instead.
## Left as a hook for game layers with multi-attack abilities to increment/read.
var times_attacked: int = 0
var has_attacked_this_turn: bool = false

# Immunity
var immunity_hits_remaining: int = 0
## When false this creature cannot be chosen as an attack target. Set by abilities
## (e.g. STEALTH) and cleared when the creature acts. The engine enforces this in
## _attack_target_allowed; it does not interpret why it is false.
var can_be_attacked: bool = true

## Accumulated permanent buffs (generic: any delta via apply_permanent_buff). The
## engine does not know "+1/+1": the delta and the cap are decided by the game
## layer. The cap is seeded from CombatConfig via the deck.
var permanent_buff_count: int = 0
var max_permanent_buffs: int = -1  # -1 = unlimited
## Accumulated permanent-buff deltas. Kept so reveal() can rebuild real stats
## without discarding buffs applied while the card was hidden.
var _buff_attack_total: int = 0
var _buff_health_total: int = 0
## Accumulated temporary-buff deltas (e.g. spell buffs). Expire on the creature's
## next turn refresh. Tracked like permanent buffs so reveal() can rebuild stats
## without dropping a temp buff applied while the card was hidden.
var _temp_attack_total: int = 0
var _temp_health_total: int = 0
## Continuous modifiers keyed by an opaque source id (e.g. an aura). Unlike
## permanent/temp buffs, a continuous modifier stays only while its source keeps it
## applied: the game adds it (ON_SETUP of the aura) and removes it (ON_DEATH of the
## aura), and re-adding the same source id replaces the old delta instead of
## stacking. Each entry is {"attack": int, "health": int}. The engine knows no
## "aura" rule; it only provides the add/remove primitive and the deterministic
## recompute. Totals are tracked like the other layers so reveal() can rebuild stats.
var _continuous_modifiers: Dictionary = {}
var _continuous_attack_total: int = 0
var _continuous_health_total: int = 0

## Injectable ability handler. Signature:
## (inst: CardInstance, trigger: int, context: Dictionary).
## `context` carries trigger-specific data (e.g. {"amount": n} for ON_DAMAGE_TAKEN,
## {"target": inst} for ON_ATTACK); it is {} when a trigger has none. `inst` is null
## for side-level triggers (ON_DRAW). If not injected, the engine applies no ability
## semantics (agnostic).
var ability_fn: Callable = Callable()


static func with_hooks(p_ability_fn: Callable, p_max_buffs: int) -> CardInstance:
	## Build a bare instance with the deck-owned hooks (ability_fn + permanent-buff
	## cap) already seeded, but WITHOUT calling setup(): the caller assigns
	## hidden_stats if needed and then calls setup() so ON_SETUP fires with the
	## handler in place. Single source for the creation shared by play_creature and
	## spell summons.
	var inst := CardInstance.new()
	inst.ability_fn = p_ability_fn
	inst.max_permanent_buffs = p_max_buffs
	return inst


static func living(board: Array) -> Array[CardInstance]:
	## Filter a board down to its living instances. Single source for the "skip the
	## dead" sweep shared by the decks and AIs, instead of repeating the loop.
	var result: Array[CardInstance] = []
	for inst in board:
		if inst is CardInstance and not inst.is_dead:
			result.append(inst)
	return result


func setup(data: CardData, p_owner: int, p_hidden: bool = false) -> void:
	card_data = data
	owner_id = p_owner
	is_hidden = p_hidden
	# Only UNIT cards fight; a PERSISTENT permanent sits on the board without ever
	# attacking or blocking. Derived here so the rest of the engine reads one bool.
	is_combatant = data.play_kind == CardData.PlayKind.UNIT

	if p_hidden:
		current_attack = hidden_stats.declared_attack if hidden_stats else data.attack
		current_health = hidden_stats.declared_health if hidden_stats else data.health
	else:
		current_attack = data.attack
		current_health = data.health
	current_max_health = current_health

	_fire(Trigger.ON_SETUP)


func reveal() -> void:
	if not is_hidden:
		return

	is_hidden = false
	# Carry over damage already taken while hidden so revealing does not heal the
	# creature: the real max is base + buffs, and current health keeps the same
	# missing-health gap it had under the declared (bluff) stats.
	var damage_taken: int = current_max_health - current_health
	current_attack = card_data.attack + _buff_attack_total + _temp_attack_total + _continuous_attack_total
	current_max_health = card_data.health + _buff_health_total + _temp_health_total + _continuous_health_total
	current_health = maxi(current_max_health - damage_taken, 0)

	_fire(Trigger.ON_REVEAL)

	card_revealed.emit(self)


func take_damage(amount: int, source: Variant = null) -> int:
	## Applies damage. Returns the actual damage taken (may be 0 with immunity).
	## `source` is who dealt it (a CardInstance in combat, or null for sourceless
	## damage like spells or fatigue); it travels in the ON_DAMAGE_TAKEN context so a
	## reflect/thorns ability can hit back. Optional and null-defaulted, so existing
	## sourceless callers are unchanged.
	if amount <= 0:
		return 0
	if immunity_hits_remaining != 0:
		if immunity_hits_remaining > 0:
			immunity_hits_remaining -= 1
		return 0

	var actual := mini(amount, current_health)
	current_health -= actual
	damage_taken_this_turn += actual
	card_damaged.emit(self, actual)
	# ON_DAMAGE_TAKEN fires before any death so an ability can react to the hit
	# (e.g. retaliate) before ON_DEATH. `source` is null when the dealer is not a
	# creature (spell / fatigue); combat passes the opponent instance.
	_fire(Trigger.ON_DAMAGE_TAKEN, {"amount": actual, "source": source})

	if current_health <= 0:
		_die()

	return actual


func heal(amount: int) -> void:
	if amount <= 0:
		return
	var before: int = current_health
	current_health = mini(current_health + amount, current_max_health)
	var healed: int = current_health - before
	if healed > 0:
		_fire(Trigger.ON_HEAL, {"amount": healed})


func apply_permanent_buff(attack_delta: int, health_delta: int, max_buffs: int = -1) -> bool:
	## Generic permanent buff. The delta is decided by the game layer; the cap comes
	## from max_buffs (one-off override) or max_permanent_buffs (seeded from
	## CombatConfig). Cap < 0 = unlimited. Returns false if the cap was reached.
	var cap := max_buffs if max_buffs >= 0 else max_permanent_buffs
	if cap >= 0 and permanent_buff_count >= cap:
		return false
	permanent_buff_count += 1
	_buff_attack_total += attack_delta
	_buff_health_total += health_delta
	current_attack += attack_delta
	current_health += health_delta
	current_max_health += health_delta
	return true


func apply_temp_buff(attack_delta: int, health_delta: int) -> void:
	## Temporary buff (e.g. a spell). Raises current stats and tracks the deltas
	## so they can expire on the next turn refresh and survive a reveal meanwhile.
	_temp_attack_total += attack_delta
	_temp_health_total += health_delta
	current_attack += attack_delta
	current_health += health_delta
	current_max_health += health_delta


func add_continuous_modifier(source_id: String, attack_delta: int, health_delta: int) -> void:
	## Apply (or replace) a continuous stat modifier from `source_id`. Re-adding the
	## same source replaces its previous delta instead of stacking, so a game can
	## refresh an aura idempotently. The delta and when to add/remove it are decided
	## by the game layer; the engine only keeps the stats consistent.
	if _continuous_modifiers.has(source_id):
		remove_continuous_modifier(source_id)
	_continuous_modifiers[source_id] = {"attack": attack_delta, "health": health_delta}
	_continuous_attack_total += attack_delta
	_continuous_health_total += health_delta
	current_attack += attack_delta
	current_health += health_delta
	current_max_health += health_delta


func remove_continuous_modifier(source_id: String) -> bool:
	## Roll back the continuous modifier from `source_id` (e.g. its source died).
	## Mirrors _expire_temp_buffs: max health drops and current health is capped to
	## the restored max rather than subtracted blindly, so damage already absorbed by
	## the modifier's buffer is not double-counted. Returns false if absent.
	if not _continuous_modifiers.has(source_id):
		return false
	var mod: Dictionary = _continuous_modifiers[source_id]
	var attack_delta: int = mod["attack"]
	var health_delta: int = mod["health"]
	_continuous_modifiers.erase(source_id)
	_continuous_attack_total -= attack_delta
	_continuous_health_total -= health_delta
	current_attack -= attack_delta
	current_max_health -= health_delta
	current_health = mini(current_health, current_max_health)
	return true


func has_continuous_modifier(source_id: String) -> bool:
	return _continuous_modifiers.has(source_id)


func _expire_temp_buffs() -> void:
	## Roll back temporary buffs. Attack drops by the tracked delta; max health
	## drops too and current health is capped to the restored max instead of
	## subtracting the delta blindly, so damage already absorbed by the temporary
	## buffer is not penalized twice.
	current_attack -= _temp_attack_total
	current_max_health -= _temp_health_total
	current_health = mini(current_health, current_max_health)
	_temp_attack_total = 0
	_temp_health_total = 0


func refresh_for_turn() -> void:
	_expire_temp_buffs()
	damage_taken_this_turn = 0
	has_attacked_this_turn = false
	times_attacked = 0
	can_attack_this_turn = false

	_fire(Trigger.ON_TURN_REFRESH)


func _die() -> void:
	is_dead = true
	_fire(Trigger.ON_DEATH)
	card_died.emit(self)


func _fire(trigger: Trigger, context: Dictionary = {}) -> void:
	if ability_fn.is_valid():
		ability_fn.call(self, trigger, context)


func serialize() -> Dictionary:
	## Full state snapshot for save/resume. The ability_fn Callable is NOT stored;
	## it is re-injected on deserialize (by the owning deck), same as other hooks.
	return {
		"card_data": card_data.serialize() if card_data != null else {},
		"owner_id": owner_id,
		"is_hidden": is_hidden,
		"is_dead": is_dead,
		"hidden_stats": hidden_stats.serialize() if hidden_stats != null else null,
		"current_attack": current_attack,
		"current_health": current_health,
		"current_max_health": current_max_health,
		"can_attack_this_turn": can_attack_this_turn,
		"damage_taken_this_turn": damage_taken_this_turn,
		"times_attacked": times_attacked,
		"has_attacked_this_turn": has_attacked_this_turn,
		"immunity_hits_remaining": immunity_hits_remaining,
		"can_be_attacked": can_be_attacked,
		"permanent_buff_count": permanent_buff_count,
		"max_permanent_buffs": max_permanent_buffs,
		"buff_attack_total": _buff_attack_total,
		"buff_health_total": _buff_health_total,
		"temp_attack_total": _temp_attack_total,
		"temp_health_total": _temp_health_total,
		"continuous_modifiers": _continuous_modifiers.duplicate(true),
		"continuous_attack_total": _continuous_attack_total,
		"continuous_health_total": _continuous_health_total,
	}


static func deserialize(data: Dictionary, p_ability_fn: Callable = Callable()) -> CardInstance:
	## Rebuilds the instance state directly WITHOUT calling setup(), so resuming a
	## saved combat does not re-fire ON_SETUP (which would re-apply on-play effects).
	var inst := CardInstance.new()
	inst.card_data = CardData.from_dict(data.get("card_data", {}))
	# Re-derive the combatant flag from play_kind (deserialize skips setup).
	inst.is_combatant = inst.card_data != null and inst.card_data.play_kind == CardData.PlayKind.UNIT
	inst.owner_id = int(data.get("owner_id", 0))
	inst.is_hidden = data.get("is_hidden", false)
	inst.is_dead = data.get("is_dead", false)
	var hs: Variant = data.get("hidden_stats", null)
	inst.hidden_stats = HiddenCardStats.from_dict(hs) if hs is Dictionary else null
	inst.current_attack = int(data.get("current_attack", 0))
	inst.current_health = int(data.get("current_health", 0))
	inst.current_max_health = int(data.get("current_max_health", 0))
	inst.can_attack_this_turn = data.get("can_attack_this_turn", false)
	inst.damage_taken_this_turn = int(data.get("damage_taken_this_turn", 0))
	inst.times_attacked = int(data.get("times_attacked", 0))
	inst.has_attacked_this_turn = data.get("has_attacked_this_turn", false)
	inst.immunity_hits_remaining = int(data.get("immunity_hits_remaining", 0))
	inst.can_be_attacked = data.get("can_be_attacked", true)
	inst.permanent_buff_count = int(data.get("permanent_buff_count", 0))
	inst.max_permanent_buffs = int(data.get("max_permanent_buffs", -1))
	inst._buff_attack_total = int(data.get("buff_attack_total", 0))
	inst._buff_health_total = int(data.get("buff_health_total", 0))
	inst._temp_attack_total = int(data.get("temp_attack_total", 0))
	inst._temp_health_total = int(data.get("temp_health_total", 0))
	# Rebuild the continuous modifiers, normalizing deltas to int (a JSON round-trip
	# turns them into floats), so remove_continuous_modifier subtracts exact ints.
	var raw_mods: Dictionary = data.get("continuous_modifiers", {})
	for source_id in raw_mods:
		var mod: Dictionary = raw_mods[source_id]
		inst._continuous_modifiers[source_id] = {"attack": int(mod.get("attack", 0)), "health": int(mod.get("health", 0))}
	inst._continuous_attack_total = int(data.get("continuous_attack_total", 0))
	inst._continuous_health_total = int(data.get("continuous_health_total", 0))
	inst.ability_fn = p_ability_fn
	return inst
