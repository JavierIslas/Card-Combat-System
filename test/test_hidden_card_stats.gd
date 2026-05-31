extends GutTest
## Caracterizacion de HiddenCardStats: parseo from_dict y passthrough opaco de
## declared_abilities (el nucleo no interpreta su contenido).


func test_from_dict_parsea_stats_declarados() -> void:
	var s := HiddenCardStats.from_dict({"declared_attack": 3, "declared_health": 4, "total_mana_invested": 5})
	assert_eq(s.declared_attack, 3)
	assert_eq(s.declared_health, 4)
	assert_eq(s.total_mana_invested, 5)


func test_from_dict_defaults_si_faltan_claves() -> void:
	var s := HiddenCardStats.from_dict({})
	assert_eq(s.declared_attack, 0)
	assert_eq(s.declared_health, 0)
	assert_eq(s.total_mana_invested, 0)
	assert_eq(s.declared_abilities.size(), 0, "sin abilities declaradas arranca vacio")


func test_declared_abilities_passthrough_opaco() -> void:
	# El nucleo no interpreta el contenido: lo guarda tal cual.
	var abilities := ["CARGA", {"tipo": "INMUNIDAD", "golpes": 2}]
	var s := HiddenCardStats.from_dict({"declared_abilities": abilities})
	assert_eq(s.declared_abilities.size(), 2, "preserva las abilities declaradas")
	assert_eq(s.declared_abilities[0], "CARGA")


func test_declared_abilities_se_duplica() -> void:
	var abilities := ["X"]
	var s := HiddenCardStats.from_dict({"declared_abilities": abilities})
	abilities.append("Y")
	assert_eq(s.declared_abilities.size(), 1, "from_dict duplico el array, no es la misma ref")


func test_from_dict_abilities_no_array_quedan_vacias() -> void:
	var s := HiddenCardStats.from_dict({"declared_abilities": "no-es-array"})
	assert_eq(s.declared_abilities.size(), 0, "un valor no-array se ignora")
