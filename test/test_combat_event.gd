extends GutTest
## CombatEvent: construcción y serialización round-trip.


func test_init_guarda_tipo_y_payload() -> void:
	var ev := CombatEvent.new(CombatEvent.EventType.COMBATANT_DAMAGED, {"side": 1, "amount": 5})
	assert_eq(ev.type, CombatEvent.EventType.COMBATANT_DAMAGED, "guarda el tipo")
	assert_eq(ev.payload["amount"], 5, "guarda el payload")


func test_payload_default_es_vacio() -> void:
	var ev := CombatEvent.new(CombatEvent.EventType.COMBAT_ENDED)
	assert_eq(ev.payload, {}, "payload por defecto vacío")


func test_serialize_usa_nombre_de_tipo() -> void:
	var ev := CombatEvent.new(CombatEvent.EventType.PHASE_CHANGED, {"old_phase": 0, "new_phase": 1})
	var data := ev.serialize()
	assert_eq(data["type"], "PHASE_CHANGED", "el tipo se serializa como nombre")
	assert_eq(data["payload"]["new_phase"], 1, "el payload se preserva")


func test_serialize_es_copia_independiente() -> void:
	var payload := {"amount": 3}
	var ev := CombatEvent.new(CombatEvent.EventType.COMBATANT_DAMAGED, payload)
	var data := ev.serialize()
	payload["amount"] = 99
	assert_eq(data["payload"]["amount"], 3, "serialize duplica el payload, no lo referencia")
