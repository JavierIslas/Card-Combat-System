class_name CombatPair
extends RefCounted
## Par atacante-defensor para resolucion de combate.

var attacker: CardInstance
var defender: Variant  # CardInstance or null (direct attack to hero)


func _init(p_attacker: CardInstance, p_defender: Variant = null) -> void:
	attacker = p_attacker
	defender = p_defender
