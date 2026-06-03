extends GutTest
## Caracterización de CardData: coste, round-trip dict y metadata opaca.

func test_can_afford() -> void:
	var card := CardData.new()
	card.cost = 3
	assert_true(card.can_afford(3), "alcanza justo")
	assert_true(card.can_afford(5), "alcanza de sobra")
	assert_false(card.can_afford(2), "no alcanza")


func test_get_total_cost() -> void:
	var card := CardData.new()
	card.cost = 4
	assert_eq(card.get_total_cost(), 4)


func test_from_dict_serialize_round_trip() -> void:
	var data := {
		"card_id": "c1",
		"name": "Goblin",
		"cost": 2,
		"attack": 3,
		"health": 1,
		"play_kind": "UNIT",
		"metadata": {"rareza": "comun"},
		"spell_effects": [],
	}
	var card := CardData.from_dict(data)
	assert_not_null(card)
	assert_eq(card.serialize(), data, "serialize reconstruye el dict original")


func test_from_dict_play_kind_invalido_retorna_null() -> void:
	var card := CardData.from_dict({"card_id": "x", "play_kind": "DRAGON_MITICO"})
	assert_null(card, "play_kind fuera del enum → null")


func test_metadata_es_opaca_y_se_duplica() -> void:
	# El motor no interpreta metadata; from_dict la copia sin tocarla.
	var meta := {"flavor": "texto", "abilities": ["x"]}
	var card := CardData.from_dict({"card_id": "c", "play_kind": "EFFECT", "metadata": meta})
	assert_eq(card.metadata, meta, "metadata se preserva tal cual")
	meta["flavor"] = "mutado"
	assert_eq(card.metadata["flavor"], "texto", "metadata se duplicó, no es la misma ref")
