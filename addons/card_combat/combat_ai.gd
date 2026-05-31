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


func choose_attackers(_board: Array[CardInstance]) -> Array[CardInstance]:
	## Pick which own creatures declare an attack this turn.
	push_error("CombatAI.choose_attackers not implemented")
	return []


func choose_attack_target(_attacker: CardInstance, _enemy_board: Array[CardInstance]) -> Variant:
	## Pick a defending creature for the attacker, or null to hit the hero.
	push_error("CombatAI.choose_attack_target not implemented")
	return null


func choose_blockers(_attackers: Array[CardInstance], _own_board: Array[CardInstance]) -> Dictionary:
	## Map attacker CardInstance -> blocker CardInstance for incoming attacks.
	push_error("CombatAI.choose_blockers not implemented")
	return {}
