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

class_name CombatAI
extends RefCounted
## Base contract for any AI driving a CombatSession. Subclass and override the
## four methods below. The engine stays agnostic: an AI only operates on CardData
## and CardInstance, never on game-specific types. DummyAI is the reference
## implementation (random, optionally seeded).
##
## The default implementations are safe no-ops (empty pick / no action) and emit
## an error, so a partial subclass fails loudly instead of silently misbehaving.


func choose_card_to_play(_hand: Array[CardData], _mana: int) -> CardData:
	## Pick a card to play from hand given available mana, or null to stop.
	push_error("CombatAI.choose_card_to_play not implemented")
	return null


func choose_attackers(_board: Array[CardInstance], _enemy_heroes: Array[Combatant] = []) -> Array[CardInstance]:
	## Pick which own creatures declare an attack this turn. `enemy_heroes` lists the
	## living heroes of every enemy side (one in 1v1, several in FFA / team games), so
	## an AI can reason about lethal; it may be empty in board-only scenarios.
	push_error("CombatAI.choose_attackers not implemented")
	return []


func choose_attack_target(_attacker: CardInstance, _enemy_board: Array[CardInstance], _enemy_heroes: Array[Combatant] = []) -> Variant:
	## Pick a defending creature for the attacker (any enemy side's creature; each
	## carries its owner_id), or null to swing at a hero. When null, the engine sends
	## the hit to the first living enemy side. `enemy_heroes` is the combined enemy
	## hero list, for lethal reasoning.
	push_error("CombatAI.choose_attack_target not implemented")
	return null


func choose_spell_target(_spell: CardData, _own_board: Array[CardInstance], _enemy_board: Array[CardInstance]) -> Variant:
	## Pick a living CardInstance for a single-target spell, or null if none fits.
	## Both boards are the combined ally / enemy creatures across sides (each carries
	## its owner_id). Inspect `_spell.spell_effects` (a DAMAGE wants an enemy, a BUFF
	## an ally) to decide. Returning null makes the spell skip without being cast.
	push_error("CombatAI.choose_spell_target not implemented")
	return null


func choose_blockers(_attackers: Array[CardInstance], _own_board: Array[CardInstance]) -> Dictionary:
	## Map attacker CardInstance -> blocker CardInstance for incoming attacks.
	push_error("CombatAI.choose_blockers not implemented")
	return {}
