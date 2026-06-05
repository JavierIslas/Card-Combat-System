extends GutTest
## AbilityLibrary: opt-in keyword interpreter (CHARGE / IMMUNITY / LIFESTEAL / TAUNT /
## THORNS / STEALTH) driven by CardData.metadata["keywords"]. Verifies each keyword's
## effect, that cards without it are untouched, and that the edge cases (PERSISTENT,
## dead session, null instance, unknown keyword) are safe no-ops. Also covers
## compose_restrictions.


var _lib: AbilityLibrary


func before_each() -> void:
	_lib = AbilityLibrary.new()


func _card(kind: CardData.PlayKind, keywords: Array, extra: Dictionary = {}) -> CardData:
	var d := CardData.new()
	d.play_kind = kind
	d.attack = 2
	d.health = 3
	var meta: Dictionary = {"keywords": keywords}
	for k in extra:
		meta[k] = extra[k]
	d.metadata = meta
	return d


func _inst(card: CardData, owner: int = 0) -> CardInstance:
	## Build a live instance wired to the library's handler, so setup() fires ON_SETUP
	## through it (the real on-play path).
	var i := CardInstance.new()
	i.ability_fn = _lib.ability_handler
	i.setup(card, owner)
	return i


func test_charge_permite_atacar_al_entrar() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_CHARGE]))
	assert_true(inst.can_attack_this_turn, "CHARGE limpia el mareo de invocacion")


func test_charge_en_persistent_no_habilita_ataque() -> void:
	# A non-combatant (PERSISTENT) never fights, so CHARGE must not grant it an attack.
	var inst := _inst(_card(CardData.PlayKind.PERSISTENT, [AbilityLibrary.KEYWORD_CHARGE]))
	assert_false(inst.can_attack_this_turn, "CHARGE no aplica a un no-combatiente")


func test_sin_keywords_no_toca_la_instancia() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, []))
	assert_false(inst.can_attack_this_turn, "sin keywords la criatura sigue mareada")
	assert_eq(inst.immunity_hits_remaining, 0, "sin keywords no hay inmunidad")


func test_immunity_por_defecto_absorbe_un_golpe() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_IMMUNITY]))
	assert_eq(inst.immunity_hits_remaining, 1, "IMMUNITY por defecto absorbe 1 golpe")


func test_immunity_lee_la_cantidad_de_metadata() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_IMMUNITY], {"immunity_hits": 3}))
	assert_eq(inst.immunity_hits_remaining, 3, "IMMUNITY respeta immunity_hits")


func test_immunity_negativa_es_permanente() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_IMMUNITY], {"immunity_hits": -1}))
	assert_eq(inst.immunity_hits_remaining, -1, "immunity_hits -1 = inmunidad permanente")


func test_keyword_desconocida_se_ignora() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, ["FLYING", "WHATEVER"]))
	assert_false(inst.can_attack_this_turn, "una keyword no soportada no hace nada")
	assert_eq(inst.immunity_hits_remaining, 0, "una keyword no soportada no toca inmunidad")


func test_on_draw_con_instancia_nula_no_crashea() -> void:
	# Side-level ON_DRAW fires with a null instance; the handler must tolerate it.
	_lib.ability_handler(null, CardInstance.Trigger.ON_DRAW, {"card": null})
	assert_true(true, "ON_DRAW con inst null no lanza error")


func test_lifesteal_cura_al_heroe_del_dueno() -> void:
	var session := CombatSession.new()
	var h0 := Combatant.new()
	h0.max_health = 30
	h0.current_health = 20
	var h1 := Combatant.new()
	h1.max_health = 30
	h1.current_health = 30
	var empty: Array[CardData] = []
	session.setup(h0, empty, h1, empty, 1)
	var lib := AbilityLibrary.new(session)
	var inst := CardInstance.new()
	inst.setup(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_LIFESTEAL]), 0)
	lib.ability_handler(inst, CardInstance.Trigger.ON_DAMAGE_DEALT, {"amount": 5})
	assert_eq(session.heroes[0].current_health, 25, "LIFESTEAL cura al heroe del dueno por el daño infligido")


func test_lifesteal_sin_sesion_es_no_op() -> void:
	# A library built without a session (or whose session was collected) must not crash
	# when LIFESTEAL fires.
	var inst := CardInstance.new()
	inst.setup(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_LIFESTEAL]), 0)
	_lib.ability_handler(inst, CardInstance.Trigger.ON_DAMAGE_DEALT, {"amount": 5})
	assert_true(true, "LIFESTEAL sin sesion es un no-op seguro")


func test_taunt_restriction_devuelve_los_taunts_vivos() -> void:
	var taunt := CardInstance.new()
	taunt.setup(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_TAUNT]), 1)
	var plain := CardInstance.new()
	plain.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var dead_taunt := CardInstance.new()
	dead_taunt.setup(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_TAUNT]), 1)
	dead_taunt.is_dead = true
	var required: Array = _lib.taunt_restriction(null, [taunt, plain, dead_taunt])
	assert_eq(required, [taunt], "solo el taunt vivo restringe el ataque")


func test_taunt_restriction_vacia_sin_taunts() -> void:
	var plain := CardInstance.new()
	plain.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var required: Array = _lib.taunt_restriction(null, [plain])
	assert_true(required.is_empty(), "sin taunts no hay restriccion")


func test_thorns_refleja_dano_a_la_fuente() -> void:
	# THORNS hits back at whoever dealt the damage (the source carried in the context).
	var atacante := CardInstance.new()
	atacante.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_THORNS]))
	_lib.ability_handler(inst, CardInstance.Trigger.ON_DAMAGE_TAKEN, {"amount": 2, "source": atacante})
	assert_eq(atacante.current_health, 2, "THORNS devuelve 1 por defecto a la fuente (3-1)")


func test_thorns_lee_la_cantidad_de_metadata() -> void:
	var atacante := CardInstance.new()
	atacante.setup(_card(CardData.PlayKind.UNIT, []), 1)
	atacante.current_health = 10
	atacante.current_max_health = 10
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_THORNS], {"thorns": 3}))
	_lib.ability_handler(inst, CardInstance.Trigger.ON_DAMAGE_TAKEN, {"amount": 1, "source": atacante})
	assert_eq(atacante.current_health, 7, "THORNS respeta metadata.thorns (10-3)")


func test_thorns_sin_fuente_es_no_op() -> void:
	# Spell / fatigue damage carries source = null; THORNS must not crash or reflect.
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_THORNS]))
	_lib.ability_handler(inst, CardInstance.Trigger.ON_DAMAGE_TAKEN, {"amount": 3, "source": null})
	assert_true(true, "THORNS con source null es un no-op seguro")


func test_thorns_no_refleja_a_fuente_muerta() -> void:
	var atacante := CardInstance.new()
	atacante.setup(_card(CardData.PlayKind.UNIT, []), 1)
	atacante.is_dead = true
	var vida := atacante.current_health
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_THORNS]))
	_lib.ability_handler(inst, CardInstance.Trigger.ON_DAMAGE_TAKEN, {"amount": 2, "source": atacante})
	assert_eq(atacante.current_health, vida, "THORNS no golpea a una fuente ya muerta")


# --- compose_restrictions ---

func test_compositor_sin_fns_retorna_vacio() -> void:
	var composed := AbilityLibrary.compose_restrictions([])
	var attacker := CardInstance.new()
	attacker.setup(_card(CardData.PlayKind.UNIT, []), 0)
	var plain := CardInstance.new()
	plain.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var result: Array = composed.call(attacker, [plain])
	assert_true(result.is_empty(), "sin fns el compositor no restringe")


func test_compositor_fn_unica_equivale_a_directa() -> void:
	var taunt := CardInstance.new()
	taunt.setup(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_TAUNT]), 1)
	var plain := CardInstance.new()
	plain.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var attacker := CardInstance.new()
	attacker.setup(_card(CardData.PlayKind.UNIT, []), 0)
	var composed := AbilityLibrary.compose_restrictions([_lib.taunt_restriction])
	var direct: Array = _lib.taunt_restriction(attacker, [taunt, plain])
	var via_compositor: Array = composed.call(attacker, [taunt, plain])
	assert_eq(via_compositor, direct, "compositor con una fn produce el mismo resultado que llamarla directa")


func test_compositor_primera_fn_restringe_segunda_no() -> void:
	# fn1 restringe a [taunt], fn2 no restringe nada → resultado [taunt]
	var taunt := CardInstance.new()
	taunt.setup(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_TAUNT]), 1)
	var plain := CardInstance.new()
	plain.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var attacker := CardInstance.new()
	attacker.setup(_card(CardData.PlayKind.UNIT, []), 0)
	var noop_fn := func(_att: CardInstance, _pool: Array) -> Array: return []
	var composed := AbilityLibrary.compose_restrictions([_lib.taunt_restriction, noop_fn])
	var result: Array = composed.call(attacker, [taunt, plain])
	assert_eq(result, [taunt], "segunda fn noop no deshace la restriccion de la primera")


func test_compositor_ambas_restringen_devuelve_interseccion() -> void:
	# fn1 restringe a [a, b], fn2 restringe a [b] → resultado [b]
	var a := CardInstance.new()
	a.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var b := CardInstance.new()
	b.setup(_card(CardData.PlayKind.UNIT, []), 1)
	var attacker := CardInstance.new()
	attacker.setup(_card(CardData.PlayKind.UNIT, []), 0)
	var fn1 := func(_att: CardInstance, _pool: Array) -> Array: return [a, b]
	var fn2 := func(_att: CardInstance, _pool: Array) -> Array: return [b]
	var composed := AbilityLibrary.compose_restrictions([fn1, fn2])
	var result: Array = composed.call(attacker, [a, b])
	assert_eq(result, [b], "composicion de dos restricciones devuelve la interseccion")


# --- STEALTH ---

func test_stealth_impide_ser_objetivo_al_entrar() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_STEALTH]))
	assert_false(inst.can_be_attacked, "STEALTH pone can_be_attacked=false al entrar al tablero")


func test_stealth_se_rompe_al_atacar() -> void:
	var inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_STEALTH]))
	assert_false(inst.can_be_attacked, "sigilo activo antes de atacar")
	_lib.ability_handler(inst, CardInstance.Trigger.ON_ATTACK, {})
	assert_true(inst.can_be_attacked, "STEALTH se rompe cuando la criatura ataca")


func test_stealth_en_persistent_no_aplica() -> void:
	# PERSISTENT no es combatiente; no tiene sentido que tenga sigilo de ataque.
	var inst := _inst(_card(CardData.PlayKind.PERSISTENT, [AbilityLibrary.KEYWORD_STEALTH]))
	assert_true(inst.can_be_attacked, "STEALTH no aplica a un no-combatiente")


func test_stealth_y_taunt_coexisten_via_compositor() -> void:
	# Con compositor: la criatura TAUNT está expuesta, la STEALTH no.
	# El atacante queda forzado al TAUNT (única criatura atacable con restricción).
	var taunt_inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_TAUNT]))
	var stealth_inst := _inst(_card(CardData.PlayKind.UNIT, [AbilityLibrary.KEYWORD_STEALTH]))
	var attacker := CardInstance.new()
	attacker.setup(_card(CardData.PlayKind.UNIT, []), 0)
	# Stealth aplica can_be_attacked=false sobre stealth_inst (ya aplicado en _inst via ON_SETUP).
	# Compositor: taunt_restriction primero filtra taunts vivos; el stealth_inst NO tiene TAUNT
	# y además tiene can_be_attacked=false — el motor lo bloquea en _attack_target_allowed.
	var composed := AbilityLibrary.compose_restrictions([_lib.taunt_restriction])
	var required: Array = composed.call(attacker, [taunt_inst, stealth_inst])
	assert_eq(required, [taunt_inst], "con TAUNT vivo el compositor fuerza al taunt, no al stealth")
