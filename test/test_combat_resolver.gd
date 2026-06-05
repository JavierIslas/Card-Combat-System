extends GutTest
## Caracterización de CombatDamageResolver: daño simultáneo y muertes.

var _resolver: CombatDamageResolver


func before_each() -> void:
	_resolver = CombatDamageResolver.new()


func _hero_damage(result: Dictionary) -> int:
	# Real source of truth for hero damage (the resolver no longer accumulates it):
	# sum attacker_damage_dealt over pairs that hit a hero (defender == null), exactly
	# as CombatSession._resolve_active_attacks aggregates it per target_side.
	var total: int = 0
	for pr in result["pairs_result"]:
		if pr["defender"] == null:
			total += pr["attacker_damage_dealt"]
	return total


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


func test_damage_fn_inyectada_reemplaza_la_formula() -> void:
	# Chunk E: con damage_fn inyectada, calculate_damage delega en el hook, que
	# puede considerar al defensor (la formula default lo ignora).
	var atacante := _make_creature(5, 5)
	var defensor := _make_creature(2, 5)
	_resolver.damage_fn = func(a: CardInstance, d: CardInstance) -> int:
		return a.current_attack - d.current_attack
	assert_eq(_resolver.calculate_damage(atacante, defensor), 3, "5 - 2 segun el hook")


func test_combate_expone_el_oponente_como_fuente() -> void:
	# In a creature trade each side's ON_DAMAGE_TAKEN must name the opponent as the
	# damage source, so a reflect/thorns ability can hit back.
	var captured: Dictionary = {}
	var tag := func(inst: CardInstance, who: String) -> void:
		inst.ability_fn = func(_i: CardInstance, trigger: int, ctx: Dictionary) -> void:
			if trigger == CardInstance.Trigger.ON_DAMAGE_TAKEN:
				captured[who] = ctx.get("source", null)
	var a := _make_creature(3, 5)
	var d := _make_creature(2, 5)
	tag.call(a, "attacker")
	tag.call(d, "defender")
	_resolver.resolve_combat([CombatPair.new(a, d)])
	assert_eq(captured.get("defender"), a, "el defensor ve al atacante como fuente")
	assert_eq(captured.get("attacker"), d, "el atacante ve al defensor como fuente")


func test_trade_mutuo_ambos_mueren() -> void:
	var a := _make_creature(3, 3)
	var d := _make_creature(3, 3)
	var pair := CombatPair.new(a, d)
	var result := _resolver.resolve_combat([pair])
	var pr: Dictionary = result["pairs_result"][0]
	assert_true(pr["attacker_died"], "atacante muere")
	assert_true(pr["defender_died"], "defensor muere")
	assert_eq(_hero_damage(result), 0, "sin daño al héroe en trade entre criaturas")


func test_dano_simultaneo_intercambio_completo() -> void:
	# El daño se aplica en una fase posterior: ambos pegan con sus stats originales.
	var a := _make_creature(5, 2)
	var d := _make_creature(2, 4)
	var pair := CombatPair.new(a, d)
	_resolver.resolve_combat([pair])
	assert_eq(a.current_health, 0, "atacante recibe 2 (muere, vida 2)")
	assert_eq(d.current_health, 0, "defensor recibe 5 sobre 4 de vida → muere")


func test_ataque_directo_al_heroe() -> void:
	var a := _make_creature(4, 3)
	var pair := CombatPair.new(a, null)
	var result := _resolver.resolve_combat([pair])
	assert_eq(_hero_damage(result), 4, "daño directo al héroe")
	var pr: Dictionary = result["pairs_result"][0]
	assert_null(pr["defender"])
	assert_false(pr["attacker_died"], "atacante no muere en ataque directo")


func test_ninguno_muere_si_ambos_sobreviven() -> void:
	var a := _make_creature(1, 10)  # pega 1, recibe 5 → vive con 5
	var d := _make_creature(5, 2)   # pega 5, recibe 1 → vive con 1
	var pair := CombatPair.new(a, d)
	var result := _resolver.resolve_combat([pair])
	var pr: Dictionary = result["pairs_result"][0]
	assert_false(pr["attacker_died"], "atacante sobrevive (10-5=5)")
	assert_false(pr["defender_died"], "defensor sobrevive (2-1=1)")
	assert_eq(a.current_health, 5)
	assert_eq(d.current_health, 1)


func test_dos_atacantes_mismo_bloqueador() -> void:
	# Dos atacantes contra el mismo defensor: recibe el dano combinado de ambos.
	var a1 := _make_creature(2, 5)
	var a2 := _make_creature(2, 5)
	var d := _make_creature(1, 3)
	var result := _resolver.resolve_combat([CombatPair.new(a1, d), CombatPair.new(a2, d)])
	assert_true(d.is_dead, "el defensor muere por el dano combinado (2+2 sobre 3)")
	assert_eq(a1.current_health, 4, "cada atacante recibe el ataque del defensor (1)")
	assert_eq(a2.current_health, 4)
	assert_eq(_hero_damage(result), 0, "ambos atacantes fueron bloqueados, sin dano al heroe")
