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


func test_play_kind_persistent_round_trip() -> void:
	var card := CardData.from_dict({"card_id": "aura", "play_kind": "PERSISTENT"})
	assert_not_null(card, "PERSISTENT es un play_kind válido")
	assert_eq(card.play_kind, CardData.PlayKind.PERSISTENT, "se parsea como PERSISTENT")
	assert_eq(card.serialize()["play_kind"], "PERSISTENT", "round-trips a PERSISTENT")


func _spell_card(type: SpellEffect.EffectType, target: SpellEffect.TargetType, count: int = 1) -> CardData:
	var card := CardData.new()
	card.play_kind = CardData.PlayKind.EFFECT
	var e := SpellEffect.new()
	e.effect_type = type
	e.target_type = target
	e.target_count = count
	var effects: Array[SpellEffect] = [e]
	card.spell_effects = effects
	return card


func test_needs_explicit_target() -> void:
	assert_true(_spell_card(SpellEffect.EffectType.DAMAGE, SpellEffect.TargetType.PLAYER_CREATURE).needs_explicit_target(), "PLAYER_CREATURE necesita target")
	assert_true(_spell_card(SpellEffect.EffectType.DAMAGE, SpellEffect.TargetType.CHOSEN_CREATURES).needs_explicit_target(), "CHOSEN_CREATURES necesita target")
	assert_false(_spell_card(SpellEffect.EffectType.DAMAGE, SpellEffect.TargetType.ENEMY_HERO).needs_explicit_target(), "ENEMY_HERO no necesita target")
	assert_false(CardData.new().needs_explicit_target(), "una carta sin efectos no necesita target")


func test_chosen_target_count() -> void:
	assert_eq(_spell_card(SpellEffect.EffectType.DAMAGE, SpellEffect.TargetType.CHOSEN_CREATURES, 3).chosen_target_count(), 3, "devuelve target_count de CHOSEN_CREATURES")
	assert_eq(_spell_card(SpellEffect.EffectType.DAMAGE, SpellEffect.TargetType.PLAYER_CREATURE).chosen_target_count(), 0, "0 sin efecto CHOSEN_CREATURES")


func test_targets_enemies() -> void:
	assert_true(_spell_card(SpellEffect.EffectType.DAMAGE, SpellEffect.TargetType.ENEMY_HERO).targets_enemies(), "un hechizo de daño apunta a enemigos")
	assert_true(_spell_card(SpellEffect.EffectType.AOE_DAMAGE, SpellEffect.TargetType.ENEMY_CREATURES).targets_enemies(), "AOE_DAMAGE apunta a enemigos")
	assert_false(_spell_card(SpellEffect.EffectType.HEAL, SpellEffect.TargetType.PLAYER_CREATURE).targets_enemies(), "un heal apunta a aliados")
	assert_true(CardData.new().targets_enemies(), "sin efectos, por defecto apunta a enemigos")
