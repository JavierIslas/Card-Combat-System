extends GutTest
## Caracterización de la taxonomía de fases de CombatState (API pública usada por
## la capa-juego/UI; el motor hace transiciones explícitas y no la consume).

func test_phase_name_devuelve_la_clave_del_enum() -> void:
	assert_eq(CombatState.phase_name(CombatState.Phase.MAIN), "MAIN")
	assert_eq(CombatState.phase_name(CombatState.Phase.DEFENSE), "DEFENSE")


func test_fases_de_accion_del_lado_activo() -> void:
	assert_true(CombatState.is_active_action_phase(CombatState.Phase.MAIN))
	assert_true(CombatState.is_active_action_phase(CombatState.Phase.ATTACK))
	assert_false(CombatState.is_active_action_phase(CombatState.Phase.DEFENSE))
	assert_false(CombatState.is_active_action_phase(CombatState.Phase.BEGIN))


func test_fase_de_accion_del_lado_pasivo() -> void:
	assert_true(CombatState.is_passive_action_phase(CombatState.Phase.DEFENSE))
	assert_false(CombatState.is_passive_action_phase(CombatState.Phase.ATTACK))
	assert_false(CombatState.is_passive_action_phase(CombatState.Phase.MAIN))


func test_fases_automaticas() -> void:
	assert_true(CombatState.is_auto_phase(CombatState.Phase.BEGIN))
	assert_true(CombatState.is_auto_phase(CombatState.Phase.PREPARATION))
	assert_true(CombatState.is_auto_phase(CombatState.Phase.RESOLVE))
	assert_true(CombatState.is_auto_phase(CombatState.Phase.END))
	assert_false(CombatState.is_auto_phase(CombatState.Phase.MAIN))
	assert_false(CombatState.is_auto_phase(CombatState.Phase.DEFENSE))


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
