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

class_name CombatEvent
extends RefCounted
## A structured, replay-friendly record of something the combat did. Mirrors the
## CombatSession signals but accumulates into CombatSession.event_log so the game
## layer can consume the run as a stream (animations, replays, networking) instead
## of wiring every signal. Payloads hold only serializable primitives, so a logged
## run round-trips through serialize(); object references stay on the signals.

enum EventType {
	PHASE_CHANGED,
	COMBATANT_DAMAGED,
	CREATURE_DIED,
	COMBAT_ENDED,
	SPELL_FIZZLED,
	CARD_DRAWN,
	CARD_PLAYED,
	MANA_CHANGED,
	DECK_EXHAUSTED,
}

var type: EventType = EventType.PHASE_CHANGED
var payload: Dictionary = {}


func _init(p_type: EventType, p_payload: Dictionary = {}) -> void:
	type = p_type
	payload = p_payload


func serialize() -> Dictionary:
	return {
		"type": EventType.keys()[type],
		"payload": payload.duplicate(true),
	}
