class_name SpellEffect
extends RefCounted

enum EffectType { DAMAGE, HEAL, BUFF_ATTACK, AOE_DAMAGE, SUMMON }

enum TargetType { ENEMY_HERO, PLAYER_HERO, PLAYER_CREATURE, ENEMY_CREATURES, PLAYER_CREATURES, SUMMON_BOARD }

var effect_type: EffectType = EffectType.DAMAGE
var value: int = 0
var target_type: TargetType = TargetType.ENEMY_HERO
var buff_health: int = 0
var summon_name: String = ""
var summon_attack: int = 0
var summon_health: int = 0
var summon_count: int = 0

## Generador de id para criaturas invocadas. Inyectable por la capa de juego.
## Firma: (name: String, index: int, count: int) -> String.
## Si no se inyecta, se usa un slug básico agnóstico (ver _make_summon_id).
var id_fn: Callable = Callable()


func apply(target: Variant, _combat_context: Dictionary) -> Dictionary:
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
			return _apply_summon(int(_combat_context.get("owner_id", 0)))
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


func _apply_summon(owner_id: int = 0) -> Dictionary:
	if summon_count <= 0:
		return _empty_result()
	var summoned: Array[CardInstance] = []
	for i in summon_count:
		var data := CardData.new()
		data.card_id = _make_summon_id(i)
		data.name = summon_name
		data.attack = summon_attack
		data.health = summon_health
		data.card_type = CardData.CardType.CRIATURA
		var inst := CardInstance.new()
		inst.setup(data, owner_id)
		summoned.append(inst)
	return {"success": true, "damage_dealt": 0, "healed": 0, "buff_amount": 0, "summoned": summoned}


func _make_summon_id(index: int) -> String:
	if id_fn.is_valid():
		return id_fn.call(summon_name, index, summon_count)
	# Default agnóstico: slug básico sin la tabla de acentos del juego.
	var base: String = summon_name.to_lower().replace(" ", "_")
	if summon_count > 1:
		return base + "_%d" % index
	return base
