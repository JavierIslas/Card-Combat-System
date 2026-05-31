# card_combat — Motor de combate de cartas agnóstico

Motor de combate por turnos para un juego de cartas (criaturas + hechizos, maná,
robo, ataque/defensa/bloqueo, resolución de daño e IA). **No depende del juego
concreto**: no conoce el GDD, ni rarezas, ni habilidades específicas, ni
`CardLoader`/`GameManager`. Todo lo específico se inyecta desde la capa-juego.

Mismo patrón y lifecycle que el addon `hex_strategy_map`: vive in-repo bajo
`addons/`, se registra por `class_name` (el `plugin.cfg` es para empaquetado /
export futuro) y es espejable a un repo standalone.

## Clases

| Clase | Rol |
|-------|-----|
| `Combatant` | Participante genérico: `current_health/max_health`, `take_damage`, `heal`, señales. El héroe del jugador lo extiende; el enemigo se instancia directo |
| `CardData` | Núcleo de carta (id/coste/stats/tipo) + `metadata: Dictionary` opaca para campos del juego |
| `CardInstance` | Carta en juego (estado de turno, vida, flags). Dispara triggers de habilidad vía `ability_fn` |
| `HiddenCardStats` | Stats declarados vs. ocultos para el bluff |
| `CombatDeck` | Mano, mazo, tablero y maná de un lado |
| `CombatSession` | FSM del combate: orquesta turnos, mazos, IA y resolución |
| `CombatState` | Enum de fases |
| `CombatPair` | Par atacante/defensor declarado |
| `CombatDamageResolver` | Resuelve daño de los pares de combate |
| `SpellEffect` | Efecto de hechizo (daño/cura/invocación) |
| `CombatConfig` | Parámetros de balance (maná, tope, mano inicial, límite de tablas) |
| `CombatAI` | Contrato base de IA: define las 4 firmas; subclasear para una IA propia |
| `DummyAI` | IA de referencia/por defecto (aleatoria, seed opcional); `extends CombatAI` |

## Puntos de inyección (cómo la capa-juego lo especializa)

1. **`CombatSession.ability_fn: Callable`** — semántica de habilidades. Vacío =
   motor puro. El juego inyecta su `AbilityHandler`. Se propaga a los
   `CardInstance` vía `CombatDeck.setup(..., ability_fn)`.
2. **`SpellEffect.id_fn: Callable`** — resuelve el id de una criatura invocada
   (`id_fn.call(summon_name, index, summon_count)`). Vacío = sin invocación
   dependiente del catálogo del juego.
3. **`CombatSession.config: CombatConfig`** — reasignar antes de `setup()` para
   cambiar el balance sin tocar el motor. Incluye
   `max_permanent_buffs_per_card` (tope de mejoras permanentes por carta;
   `-1` = ilimitado). El motor no conoce reglas como "+1/+1 cap 3": el juego
   fija el tope acá y aplica el delta que quiera con `apply_permanent_buff`.
4. **`Combatant`** — el juego pasa su héroe (subclase) y arma el `Combatant` del
   enemigo desde sus propios templates.

### Mejoras permanentes (genéricas)

`CardInstance.apply_permanent_buff(attack_delta, health_delta, max_buffs := -1)`
aplica un buff permanente de stats. El delta lo decide la capa-juego; el tope
sale de `max_buffs` (override puntual) o de `max_permanent_buffs` (sembrado
desde `CombatConfig`). Sube también `current_max_health`, que es el tope que
respeta `heal()`. Para "+1/+1 con tope 3", el juego hace
`config.max_permanent_buffs_per_card = 3` y llama `inst.apply_permanent_buff(1, 1)`.

## Cableado mínimo

```gdscript
var session := CombatSession.new()
session.ability_fn = my_ability_handler   # opcional
session.config.starting_max_mana = 2      # opcional
session.setup(hero, hero_cards, enemy, enemy_cards)
session.start()
```

## IA

El contrato de IA vive en la clase base `CombatAI`, que define las cuatro firmas:
`choose_card_to_play`, `choose_attackers`, `choose_attack_target`,
`choose_blockers`. Sus stubs devuelven vacío y emiten `push_error`, para que una
subclase incompleta falle ruidosamente. `DummyAI extends CombatAI` es la IA por
defecto y el ejemplo de referencia. Para una IA más fuerte, subclasear `CombatAI`
y sobreescribir esos métodos. Opera sólo sobre `CardData` y `CardInstance`.

## Observabilidad (señales)

El motor no lleva log propio: expone su estado vía señales y la capa-juego decide
qué registrar. Catálogo por clase:

| Clase | Señal | Cuándo |
|-------|-------|--------|
| `CombatSession` | `phase_changed(old, new)` | cada transición de la FSM |
| `CombatSession` | `combat_ended(player_won)` | al entrar a `FINAL` |
| `CombatSession` | `creature_died(card, owner)` | una criatura muere resolviendo combate |
| `CombatSession` | `hero_damaged(amount)` | el héroe del jugador recibe daño |
| `CombatSession` | `enemy_damaged(amount)` | el héroe enemigo recibe daño |
| `CombatDeck` | `card_drawn(card)` | se roba una carta del mazo |
| `CombatDeck` | `deck_exhausted` | robo fallido por mazo vacío (ver hook `exhaust_fn`) |
| `CombatDeck` | `card_played(instance)` | una criatura entra al tablero |
| `CombatDeck` | `mana_changed(new_mana)` | cambia el maná disponible |
| `CardInstance` | `card_died(card)` | la instancia muere |
| `CardInstance` | `card_damaged(card, amount)` | la instancia recibe daño |
| `CardInstance` | `card_revealed(card)` | una carta oculta se revela |
| `Combatant` | `health_changed(new_health)` | cambia la vida del participante |
| `Combatant` | `died` | la vida llega a 0 |

### Historial / replay

El motor es determinista para un seed fijo (`DummyAI` con `p_seed >= 0`, ver
`auto_resolve(player_ai, player_ai_seed)`). Patrón recomendado para la capa-juego:
conectar las señales de arriba a un grabador propio que arme el historial o un log
de replay. Como una misma semilla reproduce la misma partida, basta con persistir
el seed (y las cartas iniciales) para reproducir el combate completo desde las
señales, sin que el motor tenga que guardar estado adicional.

## Qué NO vive acá (capa-juego)

- `CardLoader` / parsing de JSON español, rarezas (`CardRarity`), habilidades.
- `AbilityHandler` (semántica concreta de CARGA/INMUNIDAD/…), `EnemyData`.
- `CombatSerializer` / `BoardState`: serialización **PvP del juego** (dependen
  de `PlayerData` y su estado específico — maná, reputación, sacrificio). Son
  scaffolding del juego, no del motor; por eso quedan en `src/core/`.
