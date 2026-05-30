class_name HiddenCardStats
extends Resource
## Stats declarados para una carta jugada boca abajo (bluff).

@export var declared_attack: int = 0
@export var declared_health: int = 0
## Habilidades declaradas en el bluff. Untyped (Array) y opaco para el núcleo;
## el contenido lo interpreta la capa-juego (no se acopla a tipos de habilidad).
@export var declared_abilities: Array = []
@export var total_mana_invested: int = 0


static func from_dict(data: Dictionary) -> HiddenCardStats:
	var stats := HiddenCardStats.new()
	stats.declared_attack = int(data.get("declared_attack", 0))
	stats.declared_health = int(data.get("declared_health", 0))
	stats.total_mana_invested = int(data.get("total_mana_invested", 0))
	# declared_abilities es opaco para el núcleo: passthrough crudo. La capa-juego
	# construye los objetos de habilidad concretos si los necesita.
	var decl: Variant = data.get("declared_abilities", [])
	if decl is Array:
		stats.declared_abilities = (decl as Array).duplicate()
	return stats
