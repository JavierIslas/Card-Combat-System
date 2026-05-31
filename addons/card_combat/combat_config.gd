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
extends RefCounted
## Parámetros de balance del motor de combate. Inyectable por la capa de juego.
## Los defaults reproducen un balance base; un juego distinto puede instanciar
## este config con otros valores sin tocar el motor.

## Tope de maná máximo que un lado puede acumular.
var max_mana_cap: int = 10

## Cuánto crece el maná máximo por turno (hasta max_mana_cap).
var mana_ramp_per_turn: int = 2

## Maná máximo inicial de cada lado al empezar el combate.
var starting_max_mana: int = 2

## Cartas robadas en la mano inicial.
var initial_hand_size: int = 3

## Turno a partir del cual un combate sin recursos se declara tablas.
var stalemate_turn_limit: int = 50

## Tope de mejoras permanentes (apply_permanent_buff) por carta.
## -1 = ilimitado (motor agnóstico). El juego lo fija (p.ej. 3) antes de setup().
var max_permanent_buffs_per_card: int = -1
