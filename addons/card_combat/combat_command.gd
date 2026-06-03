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

class_name CombatCommand
extends RefCounted
## A driver intention (input) for a CombatSession, the counterpart of CombatEvent
## (output). Where event_log records what the combat DID, command_log records what a
## driver ASKED for. CombatSession.apply_command validates and routes a command to
## the existing methods (play_card / declare_attacker / declare_blocker / end_*),
## so an authoritative server can validate client input deterministically and a
## match can be replayed from input alone.
##
## Payloads hold only serializable primitives. Cards/creatures are referenced by
## index (hand index, board index per side) the same way CombatSession serializes
## attack pairs, so a command round-trips through serialize().

enum CommandType {
	PLAY_CARD,
	DECLARE_ATTACKER,
	DECLARE_BLOCKER,
	END_MAIN,
	END_ATTACK,
	END_DEFENSE,
	ADVANCE,
}

var type: CommandType = CommandType.ADVANCE
## Side issuing the command (0/1). apply_command checks it against active/passive.
var side: int = 0
var payload: Dictionary = {}


func _init(p_type: CommandType, p_side: int = 0, p_payload: Dictionary = {}) -> void:
	type = p_type
	side = p_side
	payload = p_payload


func serialize() -> Dictionary:
	return {
		"type": CommandType.keys()[type],
		"side": side,
		"payload": payload.duplicate(true),
	}


static func deserialize(data: Dictionary) -> CombatCommand:
	var idx: int = CommandType.keys().find(data.get("type", "ADVANCE"))
	var t: CommandType = (idx if idx != -1 else CommandType.ADVANCE) as CommandType
	var payload_in: Variant = data.get("payload", {})
	var payload: Dictionary = (payload_in as Dictionary).duplicate(true) if payload_in is Dictionary else {}
	return CombatCommand.new(t, int(data.get("side", 0)), payload)
