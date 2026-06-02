extends GutTest
## Caracterizacion de CardInstance: stats, dano, inmunidad, mejoras permanentes
## genericas (apply_permanent_buff) y revelado de bluff.


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
