extends GutTest
## Caracterizacion de CardInstance: stats, dano, inmunidad, mejoras permanentes
## genericas (apply_permanent_buff), revelado de bluff y can_be_attacked.


func _make_card(attack: int, health: int) -> CardData:
	var data := CardData.new()
	data.attack = attack
	data.health = health
	return data


func _make_instance(attack: int, health: int, max_buffs: int = -1) -> CardInstance:
	var inst := CardInstance.new()
	inst.max_permanent_buffs = max_buffs
	inst.setup(_make_card(attack, health), 0)
	return inst


func test_with_hooks_siembra_hooks_sin_disparar_setup() -> void:
	# with_hooks deja la instancia con los hooks puestos pero SIN llamar setup(): no
	# dispara ON_SETUP todavía (el caller hace setup tras asignar hidden_stats).
	var fired: Array = []
	var handler := func(_inst: CardInstance, trigger: int, _ctx: Dictionary) -> void: fired.append(trigger)
	var inst := CardInstance.with_hooks(handler, 3)
	assert_eq(inst.max_permanent_buffs, 3, "siembra el tope de mejoras")
	assert_true(inst.ability_fn.is_valid(), "siembra el ability_fn")
	assert_eq(fired.size(), 0, "no dispara ningún trigger antes de setup")
	inst.setup(_make_card(2, 2), 0)
	assert_true(fired.has(CardInstance.Trigger.ON_SETUP), "el ability_fn ya está puesto cuando setup dispara ON_SETUP")


func test_take_damage_dispara_on_damage_taken_con_monto() -> void:
	var events: Array = []
	var inst := CardInstance.new()
	inst.ability_fn = func(_i: CardInstance, trigger: int, ctx: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_DAMAGE_TAKEN:
			events.append(ctx.get("amount", -1))
	inst.setup(_make_card(0, 5), 0)
	inst.take_damage(3)
	assert_eq(events, [3], "ON_DAMAGE_TAKEN lleva el daño real recibido")


func test_inmunidad_no_dispara_on_damage_taken() -> void:
	var events: Array = []
	var inst := CardInstance.new()
	inst.ability_fn = func(_i: CardInstance, trigger: int, _ctx: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_DAMAGE_TAKEN:
			events.append(true)
	inst.setup(_make_card(0, 5), 0)
	inst.immunity_hits_remaining = 1
	inst.take_damage(3)
	assert_eq(events.size(), 0, "un golpe absorbido no dispara ON_DAMAGE_TAKEN")


func test_take_damage_expone_la_fuente_en_on_damage_taken() -> void:
	# The damage source travels in the trigger context so a reflect/thorns ability can
	# hit back at whoever dealt the hit.
	var sources: Array = []
	var atacante := CardInstance.new()
	atacante.setup(_make_card(2, 2), 1)
	var inst := CardInstance.new()
	inst.ability_fn = func(_i: CardInstance, trigger: int, ctx: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_DAMAGE_TAKEN:
			sources.append(ctx.get("source", "missing"))
	inst.setup(_make_card(0, 5), 0)
	inst.take_damage(3, atacante)
	assert_eq(sources, [atacante], "ON_DAMAGE_TAKEN expone quién causó el daño")


func test_take_damage_sin_fuente_deja_source_nulo() -> void:
	# Sources without a creature (spells, fatigue) keep the previous behavior: source
	# is null, never absent, so a handler can read it uniformly.
	var sources: Array = []
	var inst := CardInstance.new()
	inst.ability_fn = func(_i: CardInstance, trigger: int, ctx: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_DAMAGE_TAKEN:
			sources.append(ctx.get("source", "missing"))
	inst.setup(_make_card(0, 5), 0)
	inst.take_damage(3)
	assert_eq(sources, [null], "sin fuente el source viaja como null")


func test_heal_dispara_on_heal_solo_con_delta_real() -> void:
	var events: Array = []
	var inst := CardInstance.new()
	inst.ability_fn = func(_i: CardInstance, trigger: int, ctx: Dictionary) -> void:
		if trigger == CardInstance.Trigger.ON_HEAL:
			events.append(ctx.get("amount", -1))
	inst.setup(_make_card(0, 5), 0)
	inst.take_damage(3)  # 2/5
	inst.heal(10)        # cura 3 (topa al max), no 10
	inst.heal(5)         # ya full -> sin delta -> sin trigger
	assert_eq(events, [3], "ON_HEAL lleva el delta real curado y no dispara sin cura")


func test_setup_inicializa_stats_y_max_health() -> void:
	var inst := _make_instance(3, 5)
	assert_eq(inst.current_attack, 3, "ataque desde card_data")
	assert_eq(inst.current_health, 5, "vida desde card_data")
	assert_eq(inst.current_max_health, 5, "max_health arranca igual a la vida")


func test_take_damage_retorna_dano_real() -> void:
	var inst := _make_instance(0, 5)
	assert_eq(inst.take_damage(3), 3, "dano real recibido")
	assert_eq(inst.current_health, 2)


func test_take_damage_no_baja_de_cero_y_marca_muerte() -> void:
	var inst := _make_instance(0, 4)
	var dealt := inst.take_damage(10)
	assert_eq(dealt, 4, "el dano real se topa a la vida restante")
	assert_true(inst.is_dead, "la criatura muere")


func test_inmunidad_absorbe_un_golpe() -> void:
	var inst := _make_instance(0, 5)
	inst.immunity_hits_remaining = 1
	assert_eq(inst.take_damage(3), 0, "primer golpe absorbido por inmunidad")
	assert_eq(inst.current_health, 5, "sin dano")
	assert_eq(inst.take_damage(3), 3, "segundo golpe ya si pega")
	assert_eq(inst.current_health, 2)


func test_heal_se_topa_a_current_max_health() -> void:
	var inst := _make_instance(0, 5)
	inst.take_damage(3)
	inst.heal(10)
	assert_eq(inst.current_health, 5, "cura topada al max actual")


func test_heal_respeta_max_subido_por_buff() -> void:
	var inst := _make_instance(0, 5)
	inst.apply_permanent_buff(0, 3)
	inst.take_damage(6)
	inst.heal(100)
	assert_eq(inst.current_health, 8, "el cura respeta el nuevo max (5+3)")


func test_buff_sin_tope_acumula() -> void:
	var inst := _make_instance(2, 2)
	assert_true(inst.apply_permanent_buff(1, 1))
	assert_true(inst.apply_permanent_buff(1, 1))
	assert_true(inst.apply_permanent_buff(1, 1))
	assert_true(inst.apply_permanent_buff(1, 1), "sin tope no corta")
	assert_eq(inst.current_attack, 6, "2 + 4 buffs")
	assert_eq(inst.current_health, 6)
	assert_eq(inst.current_max_health, 6)


func test_buff_corta_al_tope_de_la_instancia() -> void:
	var inst := _make_instance(1, 1, 3)
	assert_true(inst.apply_permanent_buff(1, 1))
	assert_true(inst.apply_permanent_buff(1, 1))
	assert_true(inst.apply_permanent_buff(1, 1))
	assert_false(inst.apply_permanent_buff(1, 1), "cuarto buff rechazado por el tope")
	assert_eq(inst.current_attack, 4, "1 + 3 buffs aplicados")
	assert_eq(inst.permanent_buff_count, 3)


func test_buff_override_de_tope_por_parametro() -> void:
	var inst := _make_instance(1, 1)
	assert_true(inst.apply_permanent_buff(1, 1, 1))
	assert_false(inst.apply_permanent_buff(1, 1, 1), "el override de tope=1 corta el segundo")


func test_buff_delta_arbitrario() -> void:
	var inst := _make_instance(2, 2)
	inst.apply_permanent_buff(5, 3)
	assert_eq(inst.current_attack, 7, "delta de ataque arbitrario")
	assert_eq(inst.current_health, 5)
	assert_eq(inst.current_max_health, 5)


func test_setup_oculto_usa_declared_y_max_health_declarado() -> void:
	var inst := CardInstance.new()
	var hidden := HiddenCardStats.new()
	hidden.declared_attack = 1
	hidden.declared_health = 1
	inst.hidden_stats = hidden
	inst.setup(_make_card(9, 9), 0, true)
	assert_eq(inst.current_attack, 1, "muestra stats declarados")
	assert_eq(inst.current_max_health, 1, "max_health sigue al declarado mientras oculto")


func test_reveal_resetea_a_stats_reales() -> void:
	var inst := CardInstance.new()
	var hidden := HiddenCardStats.new()
	hidden.declared_attack = 1
	hidden.declared_health = 1
	inst.hidden_stats = hidden
	inst.setup(_make_card(9, 9), 0, true)
	inst.reveal()
	assert_false(inst.is_hidden, "deja de estar oculta")
	assert_eq(inst.current_attack, 9, "stats reales tras revelar")
	assert_eq(inst.current_health, 9)
	assert_eq(inst.current_max_health, 9, "max_health real tras revelar")


func test_reveal_preserva_buffs_permanentes() -> void:
	# Regresion bug #3: un buff permanente aplicado mientras la carta esta oculta
	# debe sobrevivir al reveal (real + delta acumulado), no descartarse.
	var inst := CardInstance.new()
	var hidden := HiddenCardStats.new()
	hidden.declared_attack = 1
	hidden.declared_health = 1
	inst.hidden_stats = hidden
	inst.setup(_make_card(4, 6), 0, true)
	inst.apply_permanent_buff(2, 2)
	inst.reveal()
	assert_eq(inst.current_attack, 6, "base real 4 + buff 2")
	assert_eq(inst.current_health, 8, "base real 6 + buff 2")
	assert_eq(inst.current_max_health, 8, "max real 6 + buff 2")


func test_reveal_conserva_dano_recibido_oculta() -> void:
	# Regresion: una criatura oculta que recibio dano no debe curarse al revelar.
	# Real 5/5, declarada 3/3; recibe 2 (queda 1/3 oculta) -> revela a 3/5 (dano 2),
	# no a 5/5.
	var inst := CardInstance.new()
	var hidden := HiddenCardStats.new()
	hidden.declared_attack = 1
	hidden.declared_health = 3
	inst.hidden_stats = hidden
	inst.setup(_make_card(2, 5), 0, true)
	inst.take_damage(2)
	assert_eq(inst.current_health, 1, "1/3 mientras oculta y danada")
	inst.reveal()
	assert_eq(inst.current_max_health, 5, "max real tras revelar")
	assert_eq(inst.current_health, 3, "real 5 menos 2 de dano, no curada a tope")


func test_temp_buff_sube_stats_y_max() -> void:
	var inst := _make_instance(3, 5)
	inst.apply_temp_buff(2, 2)
	assert_eq(inst.current_attack, 5, "ataque sube por buff temporal")
	assert_eq(inst.current_health, 7, "vida sube por buff temporal")
	assert_eq(inst.current_max_health, 7, "max sube por buff temporal")


func test_temp_buff_expira_en_refresh() -> void:
	# Regresion bug #4: un buff temporal de hechizo expira en el refresh de turno
	# de la criatura, devolviendo stats y max al estado previo.
	var inst := _make_instance(3, 5)
	inst.apply_temp_buff(2, 2)
	inst.refresh_for_turn()
	assert_eq(inst.current_attack, 3, "ataque vuelve al base")
	assert_eq(inst.current_max_health, 5, "max vuelve al base")
	assert_eq(inst.current_health, 5, "vida topada al max restaurado")


func test_temp_buff_expirado_no_penaliza_dano_absorbido() -> void:
	# El colchon temporal absorbe el dano; al expirar la vida se topa al nuevo
	# max en vez de restar el delta a ciegas (no penaliza dos veces).
	var inst := _make_instance(0, 5)
	inst.apply_temp_buff(0, 3)  # 5/8
	inst.take_damage(2)  # 3 < buff, totalmente absorbido -> 6/8
	inst.refresh_for_turn()
	assert_eq(inst.current_max_health, 5, "max vuelve al base")
	assert_eq(inst.current_health, 5, "dano absorbido por el colchon, queda full")


func test_reveal_preserva_buff_temporal_activo() -> void:
	# Un buff temporal aplicado mientras la carta esta oculta debe sobrevivir al
	# reveal (real + permanente + temporal acumulado).
	var inst := CardInstance.new()
	var hidden := HiddenCardStats.new()
	hidden.declared_attack = 1
	hidden.declared_health = 1
	inst.hidden_stats = hidden
	inst.setup(_make_card(4, 6), 0, true)
	inst.apply_temp_buff(2, 2)
	inst.reveal()
	assert_eq(inst.current_attack, 6, "base real 4 + temp 2")
	assert_eq(inst.current_health, 8, "base real 6 + temp 2")
	assert_eq(inst.current_max_health, 8, "max real 6 + temp 2")


func test_continuous_modifier_sube_stats_y_max() -> void:
	var inst := _make_instance(3, 5)
	inst.add_continuous_modifier("aura", 2, 2)
	assert_true(inst.has_continuous_modifier("aura"), "el modificador queda registrado")
	assert_eq(inst.current_attack, 5, "ataque sube por el aura")
	assert_eq(inst.current_health, 7, "vida sube por el aura")
	assert_eq(inst.current_max_health, 7, "max sube por el aura")


func test_continuous_modifier_se_quita_al_remover() -> void:
	var inst := _make_instance(3, 5)
	inst.add_continuous_modifier("aura", 2, 2)
	assert_true(inst.remove_continuous_modifier("aura"), "remove devuelve true si existia")
	assert_false(inst.has_continuous_modifier("aura"), "ya no esta registrado")
	assert_eq(inst.current_attack, 3, "ataque vuelve al base")
	assert_eq(inst.current_max_health, 5, "max vuelve al base")
	assert_eq(inst.current_health, 5, "vida topada al max restaurado")


func test_remove_continuous_modifier_ausente_devuelve_false() -> void:
	var inst := _make_instance(3, 5)
	assert_false(inst.remove_continuous_modifier("nope"), "remove de fuente ausente es false")
	assert_eq(inst.current_attack, 3, "no toca stats")


func test_re_agregar_misma_fuente_reemplaza_sin_apilar() -> void:
	# Re-adding the same source id replaces its delta instead of stacking, so a game
	# can refresh an aura idempotently (e.g. its value changed).
	var inst := _make_instance(3, 5)
	inst.add_continuous_modifier("aura", 2, 2)
	inst.add_continuous_modifier("aura", 1, 1)
	assert_eq(inst.current_attack, 4, "queda solo el ultimo delta (3 + 1), no apila")
	assert_eq(inst.current_max_health, 6, "max = 5 + 1, no apila")


func test_dos_fuentes_continuas_distintas_se_suman() -> void:
	var inst := _make_instance(3, 5)
	inst.add_continuous_modifier("aura_a", 2, 0)
	inst.add_continuous_modifier("aura_b", 1, 0)
	assert_eq(inst.current_attack, 6, "dos fuentes distintas suman 3 + 2 + 1")
	inst.remove_continuous_modifier("aura_a")
	assert_eq(inst.current_attack, 4, "al quitar una queda la otra (3 + 1)")


func test_continuous_modifier_no_penaliza_dano_absorbido() -> void:
	# Like temp buffs: the modifier's health buffer absorbs damage; removing it caps
	# current health to the restored max instead of subtracting blindly.
	var inst := _make_instance(0, 5)
	inst.add_continuous_modifier("aura", 0, 3)  # 8/8
	inst.take_damage(2)  # 6/8, fully absorbed by the buffer
	inst.remove_continuous_modifier("aura")
	assert_eq(inst.current_max_health, 5, "max vuelve al base")
	assert_eq(inst.current_health, 5, "dano absorbido por el colchon, queda full")


func test_reveal_preserva_modificador_continuo_activo() -> void:
	# A continuous modifier added while hidden survives the reveal (real base +
	# permanent + temp + continuous).
	var inst := CardInstance.new()
	var hidden := HiddenCardStats.new()
	hidden.declared_attack = 1
	hidden.declared_health = 1
	inst.hidden_stats = hidden
	inst.setup(_make_card(4, 6), 0, true)
	inst.add_continuous_modifier("aura", 2, 2)
	inst.reveal()
	assert_eq(inst.current_attack, 6, "base real 4 + continuo 2")
	assert_eq(inst.current_max_health, 8, "max real 6 + continuo 2")


func test_continuous_modifier_round_trip_serializa() -> void:
	var inst := _make_instance(3, 5)
	inst.add_continuous_modifier("aura", 2, 2)
	var restored := CardInstance.deserialize(inst.serialize())
	assert_true(restored.has_continuous_modifier("aura"), "el modificador sobrevive el round-trip")
	assert_eq(restored.current_attack, 5, "stats restaurados")
	# And it still rolls back exactly after a resume.
	restored.remove_continuous_modifier("aura")
	assert_eq(restored.current_attack, 3, "se revierte exacto tras el resume")


func test_unit_es_combatiente() -> void:
	var inst := _make_instance(3, 5)  # _make_card default play_kind = UNIT
	assert_true(inst.is_combatant, "una UNIT es combatiente")


func test_persistent_no_es_combatiente() -> void:
	var data := _make_card(0, 4)
	data.play_kind = CardData.PlayKind.PERSISTENT
	var inst := CardInstance.new()
	inst.setup(data, 0)
	assert_false(inst.is_combatant, "una PERSISTENT no es combatiente")


func test_is_combatant_se_re_deriva_en_deserialize() -> void:
	var data := _make_card(0, 4)
	data.play_kind = CardData.PlayKind.PERSISTENT
	var inst := CardInstance.new()
	inst.setup(data, 0)
	var restored := CardInstance.deserialize(inst.serialize())
	assert_false(restored.is_combatant, "is_combatant se re-deriva de play_kind tras el resume")


# --- can_be_attacked ---

func test_can_be_attacked_default_es_true() -> void:
	var inst := _make_instance(2, 3)
	assert_true(inst.can_be_attacked, "por defecto una criatura puede ser objetivo de ataque")


func test_can_be_attacked_false_sobrevive_round_trip() -> void:
	var inst := _make_instance(2, 3)
	inst.can_be_attacked = false
	var restored := CardInstance.deserialize(inst.serialize())
	assert_false(restored.can_be_attacked, "can_be_attacked=false se preserva en el round-trip")


func test_can_be_attacked_true_sobrevive_round_trip() -> void:
	var inst := _make_instance(2, 3)
	inst.can_be_attacked = true
	var restored := CardInstance.deserialize(inst.serialize())
	assert_true(restored.can_be_attacked, "can_be_attacked=true se preserva en el round-trip")


func test_can_be_attacked_default_en_saves_legacy() -> void:
	# Un save que no contiene la clave debe deserializar como true (no romper saves viejos).
	var inst := _make_instance(2, 3)
	var data: Dictionary = inst.serialize()
	data.erase("can_be_attacked")
	var restored := CardInstance.deserialize(data)
	assert_true(restored.can_be_attacked, "save legacy sin can_be_attacked deserializa como true")


func test_attacks_per_turn_sobrevive_round_trip() -> void:
	var inst := _make_instance(2, 3)
	inst.attacks_per_turn = 2
	var restored := CardInstance.deserialize(inst.serialize())
	assert_eq(restored.attacks_per_turn, 2, "attacks_per_turn se preserva en el round-trip")


func test_attacks_per_turn_default_uno_en_saves_legacy() -> void:
	# Un save anterior a multi-ataque no trae la clave: debe deserializar como 1.
	var inst := _make_instance(2, 3)
	var data: Dictionary = inst.serialize()
	data.erase("attacks_per_turn")
	var restored := CardInstance.deserialize(data)
	assert_eq(restored.attacks_per_turn, 1, "save legacy sin attacks_per_turn deserializa como 1")


func test_freeze_marca_y_tick_descongela() -> void:
	var inst := _make_instance(2, 3)
	assert_false(inst.is_frozen(), "arranca sin congelar")
	inst.freeze(1)
	assert_true(inst.is_frozen(), "freeze(1) la congela")
	inst.tick_freeze()
	assert_false(inst.is_frozen(), "un tick la descongela")
	inst.tick_freeze()
	assert_eq(inst.frozen_turns, 0, "tick no baja de cero")


func test_freeze_toma_la_duracion_mas_larga() -> void:
	var inst := _make_instance(2, 3)
	inst.freeze(2)
	inst.freeze(1)
	assert_eq(inst.frozen_turns, 2, "re-congelar conserva la duración más larga")
	inst.freeze(0)
	assert_eq(inst.frozen_turns, 2, "freeze(0) es no-op")


func test_frozen_turns_sobrevive_round_trip_y_default_legacy() -> void:
	var inst := _make_instance(2, 3)
	inst.freeze(2)
	var restored := CardInstance.deserialize(inst.serialize())
	assert_eq(restored.frozen_turns, 2, "frozen_turns se preserva en el round-trip")
	var data: Dictionary = inst.serialize()
	data.erase("frozen_turns")
	var legacy := CardInstance.deserialize(data)
	assert_eq(legacy.frozen_turns, 0, "save legacy sin frozen_turns deserializa como 0")


func test_incoming_damage_fn_reduce_el_dano() -> void:
	var inst := _make_instance(2, 10)
	inst.incoming_damage_fn = func(_i: CardInstance, amount: int, _src: Variant) -> int: return amount - 2
	var dealt := inst.take_damage(5)
	assert_eq(dealt, 3, "el hook resta 2 al daño entrante")
	assert_eq(inst.current_health, 7, "la vida baja solo el daño reducido")


func test_incoming_damage_fn_previene_sin_consumir_inmunidad() -> void:
	# El hook corre antes de la inmunidad: un golpe totalmente prevenido (devuelve 0) no
	# gasta una carga de inmunidad.
	var inst := _make_instance(2, 10)
	inst.immunity_hits_remaining = 1
	inst.incoming_damage_fn = func(_i: CardInstance, _amount: int, _src: Variant) -> int: return 0
	var dealt := inst.take_damage(5)
	assert_eq(dealt, 0, "daño prevenido")
	assert_eq(inst.current_health, 10, "vida intacta")
	assert_eq(inst.immunity_hits_remaining, 1, "la inmunidad no se consumió")


func test_incoming_damage_fn_recibe_la_fuente() -> void:
	var inst := _make_instance(2, 10)
	var source := _make_instance(3, 3)
	var seen_source: Array = [null]
	inst.incoming_damage_fn = func(_i: CardInstance, amount: int, src: Variant) -> int:
		seen_source[0] = src
		return amount
	inst.take_damage(4, source)
	assert_eq(seen_source[0], source, "el hook recibe la fuente del daño")
