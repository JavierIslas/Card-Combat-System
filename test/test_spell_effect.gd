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
