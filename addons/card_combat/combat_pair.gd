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

class_name CombatPair
extends RefCounted
## Par atacante-defensor para resolucion de combate.

var attacker: CardInstance
var defender: Variant  # CardInstance or null (direct attack to hero)


func _init(p_attacker: CardInstance, p_defender: Variant = null) -> void:
	attacker = p_attacker
	defender = p_defender
