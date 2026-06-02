# Card Combat Engine
# Copyright (C) 2026 Javier Islas
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. This program is distributed WITHOUT ANY WARRANTY; see the GNU
# AGPL for details: <https://www.gnu.org/licenses/>.
#
# A commercial license that exempts you from the AGPL is available: see
# LICENSE_COMMERCIAL.md or contact islasjavieralf@gmail.com.

class_name CombatState
## Phases of the alternating-turn combat FSM. Pure enum with no dependencies.

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


static func is_active_action_phase(phase: Phase) -> bool:
	## Phases driven by the ACTIVE side (the one taking its turn).
	return phase in [Phase.PRINCIPAL, Phase.ATAQUE]


static func is_passive_action_phase(phase: Phase) -> bool:
	## Phases driven by the PASSIVE side (the defender declaring blockers).
	return phase == Phase.DEFENSA


static func is_auto_phase(phase: Phase) -> bool:
	return phase in [Phase.INICIO, Phase.PREPARACION, Phase.RESOLVER, Phase.FINAL]
