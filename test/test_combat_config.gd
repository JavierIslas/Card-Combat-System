extends GutTest
## Caracterización de los defaults de balance de CombatConfig.

func test_defaults_balance() -> void:
	var cfg := CombatConfig.new()
	assert_eq(cfg.max_mana_cap, 10, "tope de maná por defecto")
	assert_eq(cfg.mana_ramp_per_turn, 2, "ramp de maná por turno")
	assert_eq(cfg.starting_max_mana, 2, "maná máximo inicial")
	assert_eq(cfg.initial_hand_size, 3, "mano inicial")
	assert_eq(cfg.stalemate_turn_limit, 50, "límite de tablas")


func test_config_es_mutable_por_la_capa_juego() -> void:
	# El balance se inyecta reasignando campos; un juego distinto puede cambiarlos.
	var cfg := CombatConfig.new()
	cfg.max_mana_cap = 20
	cfg.initial_hand_size = 5
	assert_eq(cfg.max_mana_cap, 20)
	assert_eq(cfg.initial_hand_size, 5)


func test_config_es_resource_autorable() -> void:
	# CombatConfig extiende Resource para poder autorar presets de balance como .tres.
	var cfg := CombatConfig.new()
	assert_true(cfg is Resource, "CombatConfig es un Resource")


func test_record_events_default_true() -> void:
	# El recorder de event_log está ON por defecto: el comportamiento previo (loguear
	# cada combate) es byte-idéntico. Un juego de balancing lo apaga explícitamente.
	var cfg := CombatConfig.new()
	assert_eq(cfg.record_events, true, "record_events arranca en true (comportamiento previo)")
