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

class_name CombatConfig
extends Resource
## Balance parameters for the combat engine. Injectable by the game layer. The
## defaults reproduce a baseline balance; a different game can instance this config
## with other values without touching the engine. Extends Resource (not RefCounted)
## so a game can author a balance preset as a .tres and assign it to
## CombatSession.config before setup().

## Cap on the maximum mana a side can accumulate.
@export var max_mana_cap: int = 10

## How much the maximum mana grows per turn (up to max_mana_cap).
@export var mana_ramp_per_turn: int = 2

## Starting maximum mana of each side at the start of combat.
@export var starting_max_mana: int = 2

## Cards drawn for the initial hand.
@export var initial_hand_size: int = 3

## Turn from which a combat with no resources left is declared a stalemate.
@export var stalemate_turn_limit: int = 50

## Cap on permanent buffs (apply_permanent_buff) per card.
## -1 = unlimited (engine-agnostic). The game sets it (e.g. 3) before setup().
@export var max_permanent_buffs_per_card: int = -1

## Cap on creatures on each side's board.
## -1 = unlimited (engine-agnostic). The game sets it before setup().
@export var max_board_size: int = -1

## Cap on cards in each side's hand. Drawing with a full hand burns the card to the
## graveyard (see discard_fn). -1 = unlimited (engine-agnostic).
@export var max_hand_size: int = -1
