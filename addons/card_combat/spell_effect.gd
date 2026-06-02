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

class_name SpellEffect
extends Resource
## A spell's effect. Extends Resource (not RefCounted) so CardData.spell_effects
## can be @export'd and authored/persisted as a .tres alongside the card. The
## injected Callables (id_fn, effect_fn) stay non-@export: they are re-injected by
## the game layer, never saved.

enum EffectType { DAMAGE, HEAL, BUFF_ATTACK, AOE_DAMAGE, SUMMON }

enum TargetType { ENEMY_HERO, PLAYER_HERO, PLAYER_CREATURE, ENEMY_CREATURES, PLAYER_CREATURES, SUMMON_BOARD }

@export var effect_type: EffectType = EffectType.DAMAGE
@export var value: int = 0
@export var target_type: TargetType = TargetType.ENEMY_HERO
@export var buff_health: int = 0
@export var summon_name: String = ""
@export var summon_attack: int = 0
@export var summon_health: int = 0
@export var summon_count: int = 0

## Id generator for summoned creatures. Injectable by the game layer.
## Signature: (name: String, index: int, count: int) -> String.
## If not injected, a basic agnostic slug is used (see _make_summon_id).
var id_fn: Callable = Callable()

## Full effect resolution, injectable by the game layer for effect types outside
## the engine catalog (EffectType). Signature:
## (effect: SpellEffect, target: Variant, context: Dictionary) -> Dictionary.
## Si no se inyecta, se usa el match interno por EffectType.
var effect_fn: Callable = Callable()


func serialize() -> Dictionary:
	## Data-only snapshot of the effect. The injected Callables (id_fn, effect_fn)
	## are NOT serialized: the game layer re-injects them on deserialize, same as
	## the other engine hooks. Round-trips built-in EffectType spells faithfully.
	return {
		"effect_type": EffectType.keys()[effect_type],
		"value": value,
		"target_type": TargetType.keys()[target_type],
		"buff_health": buff_health,
		"summon_name": summon_name,
		"summon_attack": summon_attack,
		"summon_health": summon_health,
		"summon_count": summon_count,
	}


static func from_dict(data: Dictionary) -> SpellEffect:
	var e := SpellEffect.new()
	var et: int = EffectType.keys().find(data.get("effect_type", "DAMAGE"))
	e.effect_type = (et if et != -1 else EffectType.DAMAGE) as EffectType
	var tt: int = TargetType.keys().find(data.get("target_type", "ENEMY_HERO"))
	e.target_type = (tt if tt != -1 else TargetType.ENEMY_HERO) as TargetType
	e.value = int(data.get("value", 0))
	e.buff_health = int(data.get("buff_health", 0))
	e.summon_name = data.get("summon_name", "")
	e.summon_attack = int(data.get("summon_attack", 0))
	e.summon_health = int(data.get("summon_health", 0))
	e.summon_count = int(data.get("summon_count", 0))
	return e


func apply(target: Variant, _combat_context: Dictionary) -> Dictionary:
	if effect_fn.is_valid():
		return effect_fn.call(self, target, _combat_context)
	match effect_type:
		EffectType.DAMAGE:
			return _apply_damage(target)
		EffectType.HEAL:
			return _apply_heal(target)
		EffectType.BUFF_ATTACK:
			return _apply_buff(target)
		EffectType.AOE_DAMAGE:
			return _apply_aoe_damage(target)
		EffectType.SUMMON:
			return _apply_summon(_combat_context)
		_:
			return _empty_result()


func _empty_result() -> Dictionary:
	return {"success": false, "damage_dealt": 0, "healed": 0, "buff_amount": 0}


func _apply_damage(target: Variant) -> Dictionary:
	if value <= 0:
		return _empty_result()
	if target is CardInstance:
		if target.is_dead:
			return _empty_result()
		var dealt: int = target.take_damage(value)
		return {"success": true, "damage_dealt": dealt, "healed": 0, "buff_amount": 0}
	if target is int:
		return {"success": true, "damage_dealt": value, "healed": 0, "buff_amount": 0}
	return _empty_result()


func _apply_heal(target: Variant) -> Dictionary:
	if value <= 0:
		return _empty_result()
	if target is CardInstance:
		if target.is_dead:
			return _empty_result()
		var health_before: int = target.current_health
		target.heal(value)
		var healed: int = target.current_health - health_before
		return {"success": true, "damage_dealt": 0, "healed": healed, "buff_amount": 0}
	if target is Combatant:
		var health_before: int = target.current_health
		target.heal(value)
		var healed: int = target.current_health - health_before
		return {"success": true, "damage_dealt": 0, "healed": healed, "buff_amount": 0}
	return _empty_result()


func _apply_buff(target: Variant) -> Dictionary:
	## `buff_amount` in the result reports the attack delta (`value`) per affected
	## creature, not a board total nor the health delta (`buff_health`). Callers that
	## need totals should count the targets themselves.
	if value <= 0 and buff_health <= 0:
		return _empty_result()
	if target is Array:
		for inst in target:
			if inst is CardInstance and not inst.is_dead:
				inst.apply_temp_buff(value, buff_health)
		return {"success": true, "damage_dealt": 0, "healed": 0, "buff_amount": value}
	if target is CardInstance:
		if target.is_dead:
			return _empty_result()
		target.apply_temp_buff(value, buff_health)
		return {"success": true, "damage_dealt": 0, "healed": 0, "buff_amount": value}
	return _empty_result()


func _apply_aoe_damage(target: Variant) -> Dictionary:
	if value <= 0:
		return _empty_result()
	if target is Array:
		for inst in target:
			if inst is CardInstance and not inst.is_dead:
				inst.take_damage(value)
		return {"success": true, "damage_dealt": value, "healed": 0, "buff_amount": 0}
	return _empty_result()


func _apply_summon(context: Dictionary) -> Dictionary:
	if summon_count <= 0:
		return _empty_result()
	# Seed the hooks the deck owns BEFORE setup() so the summoned creature fires
	# ON_SETUP with the game handler already in place (no post-hoc re-seeding).
	var owner_id: int = int(context.get("owner_id", 0))
	var ability: Callable = context.get("ability_fn", Callable())
	var buff_cap: int = int(context.get("max_permanent_buffs", -1))
	var summoned: Array[CardInstance] = []
	for i in summon_count:
		var data := CardData.new()
		data.card_id = _make_summon_id(i)
		data.name = summon_name
		data.attack = summon_attack
		data.health = summon_health
		data.card_type = CardData.CardType.CRIATURA
		var inst := CardInstance.with_hooks(ability, buff_cap)
		inst.setup(data, owner_id)
		summoned.append(inst)
	return {"success": true, "damage_dealt": 0, "healed": 0, "buff_amount": 0, "summoned": summoned}


func _make_summon_id(index: int) -> String:
	if id_fn.is_valid():
		return id_fn.call(summon_name, index, summon_count)
	# Agnostic default: basic slug without the game's accent table.
	var base: String = summon_name.to_lower().replace(" ", "_")
	if summon_count > 1:
		return base + "_%d" % index
	return base
