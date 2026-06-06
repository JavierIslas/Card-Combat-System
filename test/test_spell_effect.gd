extends GutTest
## Caracterización de SpellEffect: daño, cura, buff, AOE, invocación (owner por
## contexto) e inyección de id_fn.


func _make_instance(attack: int, health: int) -> CardInstance:
	var data := CardData.new()
	data.attack = attack
	data.health = health
	var inst := CardInstance.new()
	inst.setup(data, 0)
	return inst


# --- from_dict robustez ---

func test_from_dict_effect_type_invalido_default_damage() -> void:
	# Un effect_type desconocido (save corrupto / versión futura) cae a DAMAGE en
	# vez de romper el parseo.
	var e := SpellEffect.from_dict({"effect_type": "NO_EXISTE", "value": 2})
	assert_eq(e.effect_type, SpellEffect.EffectType.DAMAGE)
	assert_eq(e.value, 2, "el resto del payload se sigue parseando")


func test_from_dict_target_type_invalido_default_enemy_hero() -> void:
	var e := SpellEffect.from_dict({"target_type": "??"})
	assert_eq(e.target_type, SpellEffect.TargetType.ENEMY_HERO)


func test_chosen_creatures_y_target_count_round_trip() -> void:
	var data := {"effect_type": "DAMAGE", "value": 3, "target_type": "CHOSEN_CREATURES", "target_count": 2}
	var e := SpellEffect.from_dict(data)
	assert_eq(e.target_type, SpellEffect.TargetType.CHOSEN_CREATURES, "se parsea CHOSEN_CREATURES")
	assert_eq(e.target_count, 2, "target_count se parsea")
	var round := e.serialize()
	assert_eq(round["target_type"], "CHOSEN_CREATURES", "round-trip del target_type")
	assert_eq(round["target_count"], 2, "round-trip del target_count")


func test_target_count_default_uno() -> void:
	var e := SpellEffect.from_dict({"effect_type": "DAMAGE", "value": 1})
	assert_eq(e.target_count, 1, "target_count omitido default 1")


# --- DAMAGE ---

func test_damage_sobre_criatura_retorna_dano() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.value = 3
	var target := _make_instance(0, 5)
	var result := effect.apply(target, {})
	assert_true(result["success"])
	assert_eq(result["damage_dealt"], 3)
	assert_eq(target.current_health, 2)


func test_damage_valor_cero_no_hace_nada() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.value = 0
	var result := effect.apply(_make_instance(0, 5), {})
	assert_false(result["success"])


func test_damage_suma_spell_power_del_context() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.value = 3
	var target := _make_instance(0, 10)
	var result := effect.apply(target, {"spell_power": 2})
	assert_eq(result["damage_dealt"], 5, "daño = valor + spell_power")
	assert_eq(target.current_health, 5)


func test_damage_spell_power_no_baja_de_cero() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.value = 2
	var target := _make_instance(0, 10)
	var result := effect.apply(target, {"spell_power": -5})
	assert_eq(result["damage_dealt"], 0, "un spell_power negativo no produce daño negativo")
	assert_eq(target.current_health, 10)


# --- HEAL ---

func test_heal_sobre_combatant() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.HEAL
	effect.value = 4
	var hero := Combatant.new()
	hero.max_health = 30
	hero.current_health = 20
	var result := effect.apply(hero, {})
	assert_eq(result["healed"], 4)
	assert_eq(hero.current_health, 24)


# --- BUFF_ATTACK ---

func test_buff_sobre_array() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.BUFF_ATTACK
	effect.value = 2
	effect.buff_health = 1
	var a := _make_instance(1, 1)
	var b := _make_instance(3, 3)
	effect.apply([a, b], {})
	assert_eq(a.current_attack, 3)
	assert_eq(b.current_health, 4)


# --- AOE_DAMAGE ---

func test_aoe_golpea_todo_el_array() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.AOE_DAMAGE
	effect.value = 2
	var a := _make_instance(0, 5)
	var b := _make_instance(0, 1)
	effect.apply([a, b], {})
	assert_eq(a.current_health, 3)
	assert_true(b.is_dead, "la criatura de 1 de vida muere por el AOE")


func test_aoe_suma_spell_power_a_cada_objetivo() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.AOE_DAMAGE
	effect.value = 2
	var a := _make_instance(0, 10)
	effect.apply([a], {"spell_power": 3})
	assert_eq(a.current_health, 5, "cada objetivo recibe valor + spell_power")


func test_heal_ignora_spell_power() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.HEAL
	effect.value = 4
	var hero := Combatant.new()
	hero.max_health = 30
	hero.current_health = 10
	effect.apply(hero, {"spell_power": 5})
	assert_eq(hero.current_health, 14, "la curación ignora el spell_power")


# --- SUMMON ---

func test_summon_respeta_owner_del_contexto() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.SUMMON
	effect.summon_name = "Eco"
	effect.summon_attack = 2
	effect.summon_health = 2
	effect.summon_count = 2
	var result := effect.apply(null, {"owner_id": 1})
	var summoned: Array = result["summoned"]
	assert_eq(summoned.size(), 2)
	assert_eq(summoned[0].owner_id, 1, "owner sale del contexto, no hardcodeado a 0")
	assert_eq(summoned[0].current_attack, 2)


func test_summon_sin_owner_default_cero() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.SUMMON
	effect.summon_name = "Eco"
	effect.summon_count = 1
	var result := effect.apply(null, {})
	assert_eq(result["summoned"][0].owner_id, 0, "default agnóstico = 0")


func test_summon_id_default_slug() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.SUMMON
	effect.summon_name = "Lobo Gris"
	effect.summon_count = 2
	var result := effect.apply(null, {})
	assert_eq(result["summoned"][0].card_data.card_id, "lobo_gris_0", "slug agnóstico con índice")


func test_summon_id_fn_inyectado() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.SUMMON
	effect.summon_name = "Lobo"
	effect.summon_count = 1
	effect.id_fn = func(n: String, i: int, c: int) -> String: return "GAME::%s::%d/%d" % [n, i, c]
	var result := effect.apply(null, {})
	assert_eq(result["summoned"][0].card_data.card_id, "GAME::Lobo::0/1", "usa el id_fn del juego")


func test_summon_recibe_incoming_damage_fn_del_contexto() -> void:
	# Una criatura invocada hereda el hook de daño entrante que viaja en el contexto,
	# igual que ability_fn, para que armadura/prevención también la cubra.
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.SUMMON
	effect.summon_name = "Eco"
	effect.summon_attack = 1
	effect.summon_health = 5
	effect.summon_count = 1
	var reduce := func(_i: CardInstance, amount: int, _src: Variant) -> int: return amount - 1
	var result := effect.apply(null, {"incoming_damage_fn": reduce})
	var inst: CardInstance = result["summoned"][0]
	assert_eq(inst.take_damage(3), 2, "el invocado aplica el incoming_damage_fn del contexto")


func test_effect_fn_inyectado_reemplaza_el_match() -> void:
	# El effect_fn inyectado corta el match interno: la capa-juego resuelve un
	# tipo de efecto fuera del catálogo del motor.
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.DAMAGE
	effect.value = 99
	# The lambda reads e.value (instead of capturing `effect`) to avoid a
	# RefCounted reference cycle that would leak the SpellEffect at exit.
	effect.effect_fn = func(e: SpellEffect, _t: Variant, _c: Dictionary) -> Dictionary:
		return {"success": true, "custom": true, "seen_value": e.value}
	var target := _make_instance(0, 5)
	var result := effect.apply(target, {})
	assert_true(result.get("custom", false), "el effect_fn resuelve el efecto")
	assert_eq(result.get("seen_value", -1), 99, "recibe el propio SpellEffect como primer arg")
	assert_eq(target.current_health, 5, "el match interno (DAMAGE) no corrió")


func test_buff_sube_current_max_health() -> void:
	# Regresion bug #2: un buff de vida debe subir current_max_health para que una
	# cura posterior pueda alcanzar el nuevo maximo.
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.BUFF_ATTACK
	effect.value = 0
	effect.buff_health = 3
	var inst := _make_instance(2, 5)
	effect.apply(inst, {})
	assert_eq(inst.current_max_health, 8, "max sube con el buff de vida")
	inst.take_damage(4)
	inst.heal(10)
	assert_eq(inst.current_health, 8, "la cura alcanza el nuevo maximo")


func test_buff_de_hechizo_es_temporal_y_expira() -> void:
	# Regresion bug #4: el buff de hechizo es temporal y se registra como tal, de
	# modo que expira en el refresh de turno de la criatura.
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.BUFF_ATTACK
	effect.value = 2
	effect.buff_health = 2
	var inst := _make_instance(3, 5)
	effect.apply(inst, {})
	assert_eq(inst.current_attack, 5, "ataque buffeado")
	inst.refresh_for_turn()
	assert_eq(inst.current_attack, 3, "el buff expira en el refresh")
	assert_eq(inst.current_max_health, 5, "el max vuelve al base")


func test_buff_de_hechizo_sobre_array_es_temporal() -> void:
	var effect := SpellEffect.new()
	effect.effect_type = SpellEffect.EffectType.BUFF_ATTACK
	effect.value = 2
	effect.buff_health = 1
	var a := _make_instance(1, 1)
	var b := _make_instance(3, 3)
	effect.apply([a, b], {})
	assert_eq(a.current_attack, 3, "buff aplicado al array")
	a.refresh_for_turn()
	assert_eq(a.current_attack, 1, "el buff de array tambien expira")


func test_is_damage() -> void:
	var e := SpellEffect.new()
	e.effect_type = SpellEffect.EffectType.DAMAGE
	assert_true(e.is_damage(), "DAMAGE es daño")
	e.effect_type = SpellEffect.EffectType.AOE_DAMAGE
	assert_true(e.is_damage(), "AOE_DAMAGE es daño")
	e.effect_type = SpellEffect.EffectType.HEAL
	assert_false(e.is_damage(), "HEAL no es daño")


func test_needs_explicit_target() -> void:
	var e := SpellEffect.new()
	e.target_type = SpellEffect.TargetType.PLAYER_CREATURE
	assert_true(e.needs_explicit_target(), "PLAYER_CREATURE necesita target")
	e.target_type = SpellEffect.TargetType.CHOSEN_CREATURES
	assert_true(e.needs_explicit_target(), "CHOSEN_CREATURES necesita target")
	e.target_type = SpellEffect.TargetType.ENEMY_CREATURES
	assert_false(e.needs_explicit_target(), "ENEMY_CREATURES no necesita target explícito")
