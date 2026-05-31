extends GutTest
## Caracterizacion del contrato base CombatAI: DummyAI es-un CombatAI y tanto la
## base como la implementacion de referencia exponen las 4 firmas del contrato.

const CONTRACT_METHODS := [
	"choose_card_to_play",
	"choose_attackers",
	"choose_attack_target",
	"choose_blockers",
]


func test_dummy_ai_es_un_combat_ai() -> void:
	var ai := DummyAI.new()
	assert_true(ai is CombatAI, "DummyAI hereda del contrato base CombatAI")


func test_combat_ai_define_el_contrato_completo() -> void:
	var ai := CombatAI.new()
	for method_name in CONTRACT_METHODS:
		assert_true(ai.has_method(method_name), "CombatAI define %s" % method_name)


func test_dummy_ai_cumple_el_contrato_completo() -> void:
	var ai := DummyAI.new()
	for method_name in CONTRACT_METHODS:
		assert_true(ai.has_method(method_name), "DummyAI implementa %s" % method_name)
