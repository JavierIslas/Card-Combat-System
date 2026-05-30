class_name CombatState
## Fases de la FSM de combate PVE. Enum puro sin dependencias.

enum Phase {
	INICIO,
	PREPARACION,
	PRINCIPAL,
	ATAQUE,
	DEFENSA,
	RESOLVER,
	FINAL,
}


static func phase_name(phase: Phase) -> String:
	return Phase.keys()[phase]


static func is_player_action_phase(phase: Phase) -> bool:
	return phase in [Phase.PRINCIPAL, Phase.ATAQUE]


static func is_auto_phase(phase: Phase) -> bool:
	return phase in [Phase.INICIO, Phase.PREPARACION, Phase.RESOLVER, Phase.FINAL]
