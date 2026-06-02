extends GutTest
## Caracterización de la taxonomía de fases de CombatState (API pública usada por
## la capa-juego/UI; el motor hace transiciones explícitas y no la consume).

func test_phase_name_devuelve_la_clave_del_enum() -> void:
	assert_eq(CombatState.phase_name(CombatState.Phase.PRINCIPAL), "PRINCIPAL")
	assert_eq(CombatState.phase_name(CombatState.Phase.DEFENSA), "DEFENSA")


func test_fases_de_accion_del_lado_activo() -> void:
	assert_true(CombatState.is_active_action_phase(CombatState.Phase.PRINCIPAL))
	assert_true(CombatState.is_active_action_phase(CombatState.Phase.ATAQUE))
	assert_false(CombatState.is_active_action_phase(CombatState.Phase.DEFENSA))
	assert_false(CombatState.is_active_action_phase(CombatState.Phase.INICIO))


func test_fase_de_accion_del_lado_pasivo() -> void:
	assert_true(CombatState.is_passive_action_phase(CombatState.Phase.DEFENSA))
	assert_false(CombatState.is_passive_action_phase(CombatState.Phase.ATAQUE))
	assert_false(CombatState.is_passive_action_phase(CombatState.Phase.PRINCIPAL))


func test_fases_automaticas() -> void:
	assert_true(CombatState.is_auto_phase(CombatState.Phase.INICIO))
	assert_true(CombatState.is_auto_phase(CombatState.Phase.PREPARACION))
	assert_true(CombatState.is_auto_phase(CombatState.Phase.RESOLVER))
	assert_true(CombatState.is_auto_phase(CombatState.Phase.FINAL))
	assert_false(CombatState.is_auto_phase(CombatState.Phase.PRINCIPAL))
	assert_false(CombatState.is_auto_phase(CombatState.Phase.DEFENSA))


func test_las_tres_categorias_particionan_las_fases() -> void:
	# Toda fase cae en exactamente una categoría: activa, pasiva o automática. Esto
	# es lo que garantiza que la taxonomía sea total y sin solapes.
	for phase in CombatState.Phase.values():
		var count := 0
		if CombatState.is_active_action_phase(phase):
			count += 1
		if CombatState.is_passive_action_phase(phase):
			count += 1
		if CombatState.is_auto_phase(phase):
			count += 1
		assert_eq(count, 1, "%s pertenece a exactamente una categoría" % CombatState.phase_name(phase))
