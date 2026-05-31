extends Control
## Minimal runnable demo for the Card Combat Engine.
##
## Builds two plain CardData decks, wires a CombatSession with the reference
## DummyAI on both sides, runs a full combat headless via auto_resolve() and
## renders the combat log live from the engine signals. There is no
## game-specific code here: this is the engine driving itself end to end.
##
## Run it from the editor (F5 with this scene) and press "Run combat" to play
## another match. Note: the DummyAI is seeded (deterministic), but CombatDeck
## shuffles via the global RNG, so each run still differs. When run headless it
## prints the log and exits, so it doubles as a smoke check.

@onready var _log_label: RichTextLabel = %CombatLog
@onready var _run_button: Button = %RunButton

# Each run derives its AI seeds from this index. The deck shuffle is not seeded
# (see header), so runs are not bit-for-bit reproducible.
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

	# Enemy AI is the seeded DummyAI created inside setup(); the player AI is the
	# one we build and inject.
	var player_ai := DummyAI.new()
	player_ai.setup(_run_index)
	session.setup(hero, _starter_deck(), enemy, _starter_deck(), _run_index + 100)
	session.auto_resolve(player_ai)

	_log_result(session.get_result())
	_flush_log()


func _connect_signals(session: CombatSession) -> void:
	session.phase_changed.connect(_on_phase_changed)
	session.creature_died.connect(_on_creature_died)
	session.hero_damaged.connect(func(amount: int) -> void: _push("Player hero takes %d" % amount))
	session.enemy_damaged.connect(func(amount: int) -> void: _push("Enemy hero takes %d" % amount))
	session.combat_ended.connect(func(player_won: bool) -> void: _push("Combat ended — player_won=%s" % player_won))


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
	card.card_type = CardData.CardType.CRIATURA
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
	_push("Result: player_won=%s  turns=%d  hero_hp=%d  enemy_hp=%d" % [
		result["player_won"], result["turn_number"], result["hero_hp"], result["enemy_hp"],
	])


func _flush_log() -> void:
	var text: String = "\n".join(_log_lines)
	_log_label.text = text
	print(text)
