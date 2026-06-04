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

extends Control
## Minimal runnable demo for the Card Combat Engine.
##
## Builds two plain CardData decks, wires a CombatSession with the reference
## DummyAI on both sides, runs a full combat headless via auto_resolve() and
## renders the combat log live from the engine signals. There is no
## game-specific code here: this is the engine driving itself end to end.
##
## Run it from the editor (F5 with this scene) and press "Run combat" to play
## another match. The engine is deterministic for a fixed seed (both the DummyAI
## and the deck shuffle are seeded), so each press uses a new seed to vary the
## match while staying reproducible. When run headless it prints the log and
## exits, so it doubles as a smoke check.

@onready var _log_label: RichTextLabel = %CombatLog
@onready var _run_button: Button = %RunButton

# Each run derives its seeds from this index; reusing an index reproduces that
# exact match (the engine is seed-deterministic, deck shuffle included).
var _run_index: int = 0
var _log_lines: PackedStringArray = []


func _ready() -> void:
	_run_button.pressed.connect(_run_combat)
	_run_combat()
	# Headless smoke run (CI / asset validation): the log already printed, exit.
	if DisplayServer.get_name() == "headless":
		get_tree().quit()


func _run_combat() -> void:
	_run_index += 1
	_log_lines.clear()
	_push("=== Combat run #%d ===" % _run_index)

	var session := CombatSession.new()
	_connect_signals(session)

	var hero := _make_hero("Player", 30)
	var enemy := _make_hero("Enemy", 30)

	# Side 1's AI is the seeded DummyAI created inside setup(); inject side 0's AI
	# before setup so it survives (setup only seeds empty ais slots).
	var player_ai := DummyAI.new()
	player_ai.setup(_run_index)
	session.ais[0] = player_ai
	session.setup(hero, _starter_deck(), enemy, _starter_deck(), _run_index + 100)
	session.auto_resolve()

	_log_result(session.get_result())
	_flush_log()


func _connect_signals(session: CombatSession) -> void:
	session.phase_changed.connect(_on_phase_changed)
	session.creature_died.connect(_on_creature_died)
	session.combatant_damaged.connect(func(side: int, amount: int) -> void: _push("Side %d hero takes %d" % [side, amount]))
	session.combat_ended.connect(func(winner_side: int) -> void: _push("Combat ended — winner_side=%d" % winner_side))


func _on_phase_changed(old_phase: int, new_phase: int) -> void:
	_push("%s -> %s" % [CombatState.phase_name(old_phase), CombatState.phase_name(new_phase)])


func _on_creature_died(_card: CardInstance, owner_id: int) -> void:
	_push("Creature died (owner %d)" % owner_id)


func _starter_deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.append(_make_creature("grunt", "Grunt", 1, 2, 1))
	cards.append(_make_creature("scout", "Scout", 1, 1, 2))
	cards.append(_make_creature("knight", "Knight", 2, 2, 3))
	cards.append(_make_creature("ogre", "Ogre", 3, 4, 4))
	cards.append(_make_creature("golem", "Golem", 4, 4, 6))
	cards.append(_make_creature("drake", "Drake", 4, 5, 4))
	return cards


func _make_creature(id: String, display_name: String, cost: int, attack: int, health: int) -> CardData:
	var card := CardData.new()
	card.card_id = id
	card.name = display_name
	card.cost = cost
	card.attack = attack
	card.health = health
	card.play_kind = CardData.PlayKind.UNIT
	return card


func _make_hero(display_name: String, hp: int) -> Combatant:
	var hero := Combatant.new()
	hero.display_name = display_name
	hero.max_health = hp
	hero.current_health = hp
	return hero


func _push(line: String) -> void:
	_log_lines.append(line)


func _log_result(result: Dictionary) -> void:
	_push("")
	# Iterate hp per side instead of assuming two: get_result()["hp"] is sized to the
	# side count, so the demo also reports FFA / team layouts without indexing past it.
	var hp: Array = result["hp"]
	var hp_parts: PackedStringArray = []
	for side in hp.size():
		hp_parts.append("hp%d=%d" % [side, hp[side]])
	_push("Result: winner_side=%d  turns=%d  %s" % [
		result["winner_side"], result["turn_number"], " ".join(hp_parts),
	])


func _flush_log() -> void:
	var text: String = "\n".join(_log_lines)
	_log_label.text = text
	print(text)
