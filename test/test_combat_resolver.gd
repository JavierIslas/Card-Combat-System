extends GutTest
## Caracterización de CombatDamageResolver: daño simultáneo y muertes.

var _resolver: CombatDamageResolver


func before_each() -> void:
	_resolver = CombatDamageResolver.new()


func _make_creature(attack: int, health: int) -> CardInstance:
	var data := CardData.new()
	data.attack = attack
	data.health = health
	var inst := CardInstance.new()
	inst.setup(data, 0)
	return inst


func test_calculate_damage_minimo_uno() -> void:
	var atacante := _make_creature(0, 5)
	var defensor := _make_creature(2, 5)
	assert_eq(_resolver.calculate_damage(atacante, defensor), 1, "daño mínimo es 1 aunque ataque sea 0")


func test_trade_mutuo_ambos_mueren() -> void:
	var a := _make_creature(3, 3)
	var d := _make_creature(3, 3)
	var pair := CombatPair.new(a, d)
	var result := _resolver.resolve_combat([pair], 30)
	var pr: Dictionary = result["pairs_result"][0]
	assert_true(pr["attacker_died"], "atacante muere")
	assert_true(pr["defender_died"], "defensor muere")
	assert_eq(result["hero_damage"], 0, "sin daño al héroe en trade entre criaturas")


func test_dano_simultaneo_intercambio_completo() -> void:
	# El daño se aplica en una fase posterior: ambos pegan con sus stats originales.
	var a := _make_creature(5, 2)
	var d := _make_creature(2, 4)
	var pair := CombatPair.new(a, d)
	_resolver.resolve_combat([pair], 30)
	assert_eq(a.current_health, 0, "atacante recibe 2 (muere, vida 2)")
	assert_eq(d.current_health, 0, "defensor recibe 5 sobre 4 de vida → muere")


func test_ataque_directo_al_heroe() -> void:
	var a := _make_creature(4, 3)
	var pair := CombatPair.new(a, null)
	var result := _resolver.resolve_combat([pair], 30)
	assert_eq(result["hero_damage"], 4, "daño directo al héroe")
	var pr: Dictionary = result["pairs_result"][0]
	assert_null(pr["defender"])
	assert_false(pr["attacker_died"], "atacante no muere en ataque directo")


func test_ninguno_muere_si_ambos_sobreviven() -> void:
	var a := _make_creature(1, 10)  # pega 1, recibe 5 → vive con 5
	var d := _make_creature(5, 2)   # pega 5, recibe 1 → vive con 1
	var pair := CombatPair.new(a, d)
	var result := _resolver.resolve_combat([pair], 30)
	var pr: Dictionary = result["pairs_result"][0]
	assert_false(pr["attacker_died"], "atacante sobrevive (10-5=5)")
	assert_false(pr["defender_died"], "defensor sobrevive (2-1=1)")
	assert_eq(a.current_health, 5)
	assert_eq(d.current_health, 1)
