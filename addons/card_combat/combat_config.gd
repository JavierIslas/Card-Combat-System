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
