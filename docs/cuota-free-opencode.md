# Cuota de los modelos free de OpenCode

Documento de trabajo. Recoge qué se puede y qué no se puede saber sobre la cuota de los modelos gratuitos de OpenCode, con los hallazgos medidos en este equipo.

## Resumen

- **Disponibilidad:** sí se puede consultar en vivo.
- **Precio/gratuidad:** sí, con el campo `cost` del catálogo.
- **Saldo restante:** no existe endpoint ni cabecera que lo exponga.
- **Instante de reinicio:** el error 429 trae `retryAfterMs`, pero en la práctica no es confiable.
- **Consumo propio:** sí, cada llamada queda registrada en la base local.
- **Estimación de margen:** sí, acotando entre lo máximo usado sin bloquear y lo mínimo usado al bloquear.

## Qué sí se puede consultar

### Modelos disponibles y gratuitos

```sh
opencode models | grep free
```

```sh
opencode api get /api/model | jq -r '.data[]
  | select(.cost[0].input==0 and .cost[0].output==0)
  | [.providerID, .id, .status, (.limit.context|tostring)] | @tsv'
```

- `cost.input == 0` y `cost.output == 0` identifica los free.
- `status` puede ser `active`, `deprecated`, `alpha`, etc.
- Si un modelo no aparece, no está disponible para la cuenta (retirado, región bloqueada o `OPENCODE_DISABLE_FREE_MODELS=1`).
- La lista oficial de bloqueos regionales y modelos retirados está en <https://opencode.ai/docs/console/models>.

### Límites de los planes de pago

```sh
opencode api get /api/experimental/usage/limits
```

Devuelve la cuota de OpenCode Go (`rolling`, `weekly`, `monthly`) y los presupuestos de Console. **No incluye los modelos free**: la documentación indica que no consumen presupuesto.

## Qué no se puede saber

- No hay porcentaje ni saldo restante de los modelos free.
- No hay endpoint que diga “te quedan N llamadas”.
- Solo **LongCat 2.5 Free** tiene una cuota numérica publicada: 100 requests/día.

El único aviso es el error en tiempo de uso.

## El error de cuota (429)

Se guarda completo en `session_message`:

```json
{
  "error": {
    "type": "provider.free-limit",
    "message": "Free usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models.",
    "status": 429,
    "response": {
      "body": "{\"type\":\"error\",\"error\":{\"type\":\"FreeUsageLimitError\",\"message\":\"Free usage limit reached...\"}}"
    },
    "retryAfterMs": 66433000
  },
  "model": { "id": "deepseek-v4.1-flash-free", "providerID": "opencode", "variant": "default" },
  "finish": "error"
}
```

Implicaciones:

- El tipo del error en la base es `provider.free-limit`.
- El estado HTTP es **429**.
- `retryAfterMs` da un reinicio teórico, pero **no es fiable**: hubo avisos de 18–20 h con recuperación real en minutos.
- El fallo también aparece como un mensaje `idle` con `outcome: "failed"`.

## Qué se registra por llamada

Cada `session_message` de tipo `assistant` es una llamada al modelo:

| Campo | Contenido |
|---|---|
| `time.created / firstToken / streamed / completed` | marcas de tiempo |
| `model.id / providerID / variant` | modelo y proveedor |
| `tokens.input / output / reasoning` | consumo |
| `tokens.cache.read / write` | caché |
| `cost` | 0 en free |
| `finish` | `stop`, `tool-calls`, `error` |
| `error` | detalle del bloqueo |

## Hallazgos medidos

### Primer bloqueo (18 nov 2026)

Medido desde la primera llamada free hasta el primer 429:

| Dato | Valor |
|---|---|
| Primera llamada | 18 nov 05:33:09 UTC |
| Primer 429 | 18 nov 06:43:30 UTC |
| Duración | 1 h 10 min |
| Sesiones | 9 |
| Prompts de usuario | 21 |
| Llamadas exitosas | 445 |
| Llamadas a herramientas | 497 |
| Ritmo | 6.34 llamadas/min |
| Tokens sin caché | 1,583,681 |
| Tokens de caché leída | 40,928,768 |
| Costo | $0.00 |

Reparto por modelo:

| Modelo | Llamadas | Input | Output | Razonamiento | Caché leída |
|---|---:|---:|---:|---:|---:|
| deepseek-v4.1-flash-free | 260 | 517,858 | 66,736 | 146,523 | 20,933,632 |
| glm-5.3-flash-free | 138 | 423,775 | 42,945 | 55,796 | 10,005,248 |
| hy4-flash-free | 47 | 298,094 | 22,478 | 9,476 | 9,898,888 |

### Bloqueos observados

| Bloqueo (UTC) | Modelos | `retryAfterMs` | Vuelta real |
|---|---|---|---|
| 18 nov 06:43 | deepseek, glm | ~18.4 h | 7 min |
| 18 nov 12:55 | deepseek, hy4 | ~11.5 h | 5.7 h |
| 18 nov 16:38–16:49 | deepseek | ~7.7 h | 1.8 h |
| 19 nov 04:12 | hy4 | ~20.2 h | 1.3 min |
| 20 nov 00:01 | deepseek | ~0.4 h | sin recuperación antes del reinicio |

Conclusiones:

- **El cupo es compartido entre todos los free.** En el mismo minuto fallaron modelos distintos con el mismo reinicio: cambiar de modelo no evita el bloqueo.
- **La mayoría de los bloqueos son transitorios** (1 min a 5.7 h): se recuperan antes del reinicio anunciado y no reflejan el cupo. El `retryAfterMs` no es confiable.
- **El único bloqueo duro medido** llegó 25 minutos antes del reinicio diario (20 nov 00:01 → 00:26:48 UTC) y no se recuperó: ese es el que sirve de referencia.
- **El reinicio anunciado cae sobre las 00:26:48 UTC** (20:26 local en UTC-4), lo que confirma una ventana diaria.

### Comparación: referencia vieja vs bloqueo real

| Métrica | Referencia anterior (18 nov 06:43) | Bloqueo real (20 nov 00:01) | Diferencia |
|---|---:|---:|---:|
| Llamadas | 445 | 507 | +62 (+14%) |
| Tokens sin caché | 1,583,681 | 1,352,914 | −230,767 (−15%) |
| Caché leída | 40,928,768 | 44,773,760 | +3.8M |
| Reparto | deepseek 260 · glm 138 · hy4 47 | deepseek 263 · hy4 244 | — |

La referencia de 445 llamadas venía de un bloqueo **transitorio** (volvió a los 7 minutos), no del cupo real. Por eso la sidebar subestimaba las llamadas y marcaba `recalibrando` desde las 445. Con el bloqueo duro, el techo queda en **507 llamadas** y **1.35M tokens**.

Dos matices:

- **No fue un pico de 5 horas:** en las 5 h previas al bloqueo hubo 227 llamadas y 629k tokens, muy por debajo de las 445/1.58M del 18 nov. El corte es diario, no por ráfaga.
- **507/1.35M es una cota, no una pared fija:** el 18 nov la ventana llegó a 532 llamadas y 2.17M tokens sin un bloqueo duro. El peso de cada modelo (hoy `hy4` sumó 244 llamadas frente a 47 el 18 nov) o el uso desde otro equipo pueden consumir cupo que esta base no registra.

## Estimación del margen restante

Datos:

- **Techo (U):** el menor consumo observado en un **bloqueo duro**: un 429 tras el cual no hubo ninguna llamada exitosa antes del reinicio anunciado. Es un límite superior de la cuota.
- **Piso (L):** lo máximo consumido en una ventana que terminó sin bloquearse. Es un límite inferior.
- La cuota real está entre `L` y `U`; el margen restante, entre `0` y `U - consumo`.
- Los bloqueos **transitorios** no tocan la referencia: miden capacidad, no cupo.

Ejemplo (20 nov 2026, con la referencia recalculada):

| Métrica | Usado (L) | Referencia (U) | Margen |
|---|---:|---:|---:|
| Llamadas | 507 | 507 | 0 |
| Tokens sin caché | 1,352,914 | 1,352,914 | 0 |
| Tokens con caché | 44.8M | 44.8M | 0 |

Al empezar la ventana siguiente, el margen vuelve a mostrarse completo: `507 llamadas · 1.35M tokens`.

La referencia se actualiza sola:

- Nuevo bloqueo duro → el techo de llamadas y el de tokens bajan al menor consumo observado en un bloqueo duro.
- Bloqueo transitorio → no cambia la referencia.
- Ventana terminada sin bloqueo → `L = max(L, consumo)`.
- Cuando el consumo alcanza o supera `U`, el margen se muestra como `0`.
- Si una ventana supera `U` en llamadas **y** en tokens sin bloquearse, la referencia se marca **obsoleta** y el script muestra `?` hasta recalibrar con el próximo bloqueo duro. Si solo supera una de las dos dimensiones, la referencia sigue viva: es posible que el cupo se mida por la otra.

## Integración en la sidebar

El plugin vive en [`tui/statusline/tui.tsx`](../tui/statusline/tui.tsx) y se instala con `./install.sh` en `~/.config/opencode/statusline/`. Muestra una sola lista `Límites` con las filas de Go (`5h`, `sem`, `mes`) y una fila `free` con el mismo formato, alimentada por `scripts/free-quota.sh --json`.

- Se refresca cada 2 minutos (los límites de Go, cada 1).
- La fila `free` usa la dimensión más exigida (llamadas o tokens) contra su techo, para que se lea de un vistazo. El color recorre verde → naranja → rojo con paradas en 25%, 50% y 75%.
- Al pasar el mouse por encima aparece una tarjeta centrada en la ventana con el detalle: ventana, llamadas usadas/techo, tokens usados/techo, caché, último 429 y reinicio. Un clic la fija y otro la suelta.
- Si una ventana supera el techo en llamadas **y** tokens sin bloquearse, aparece `recalibrando · 429 HH:MM`: la referencia quedó vieja y se corrige con el próximo bloqueo duro.
- El comando `/uso` (o `statusline.usage` en la paleta) muestra el detalle completo: límites de Go, llamadas usadas, techo, tokens (sin caché y de caché), reinicio y bloqueos de la ventana.
- El script se busca en este orden: `OPENCODE_FREE_QUOTA_SCRIPT`, cada directorio de configuración candidato y la ruta del repo.
- Funciona en macOS, Linux y Windows (Git Bash + `sqlite3`). El plugin busca bash en las rutas típicas y la base en XDG, APPDATA y `~/Library/Application Support`; se puede forzar con `OPENCODE_BASH`, `OPENCODE_CONFIG_DIR` y `OPENCODE_DB`.

Para aplicar cambios en el plugin basta `opencode reload`; si la sidebar no reacciona, reinicia OpenCode. Las limitaciones del runtime al dibujar varias filas con color están anotadas en [`tui/statusline/README.md`](../tui/statusline/README.md#notas-de-render-tui-de-opencode).

## Consultas SQL reutilizables

Abrir siempre en solo lectura:

```sh
sqlite3 -readonly -header -column ~/.local/share/opencode/opencode.db "..."
```

Actividad free por día:

```sql
select date(time_created/1000 - 1608,'unixepoch') dia,
       count(*) llamadas,
       sum(json_extract(data,'$.tokens.input')+json_extract(data,'$.tokens.output')
           +json_extract(data,'$.tokens.reasoning')) tokens_sin_cache,
       sum(json_extract(data,'$.tokens.cache.read')) cache
from session_message
where type='assistant'
  and json_extract(data,'$.model.id') like '%-free'
  and json_extract(data,'$.error.type') is null
group by dia order by dia;
```

Bloqueos con reinicio anunciado:

```sql
select datetime(time_created/1000,'unixepoch') golpe,
       json_extract(data,'$.model.id') modelo,
       round(json_extract(data,'$.error.retryAfterMs')/3600000.0,2) horas,
       datetime((time_created+json_extract(data,'$.error.retryAfterMs'))/1000,'unixepoch') reinicio
from session_message
where json_extract(data,'$.error.type')='provider.free-limit'
  and type='assistant'
order by time_created;
```

Consumo por modelo en una ventana:

```sql
select json_extract(data,'$.model.id') modelo, count(*) llamadas,
       sum(json_extract(data,'$.tokens.input')) input,
       sum(json_extract(data,'$.tokens.output')) output,
       sum(json_extract(data,'$.tokens.reasoning')) razonamiento
from session_message
where type='assistant'
  and json_extract(data,'$.model.id') like '%-free'
  and json_extract(data,'$.error.type') is null
  and time_created >= 1795052808000
group by modelo order by llamadas desc;
```

## Retención de datos

- **Log** (`~/.local/share/opencode/log/opencode.log`): un solo archivo; al pasar **50 MiB** se recorta a los **últimos 25 MiB**, revisando cada hora. No rota por tiempo. A ~220 KB/día puede durar meses.
- **Base de datos** (`~/.local/share/opencode/opencode.db`): no recorta. Conserva los errores históricos, así que es mejor fuente que el log para analizar bloqueos.
- El WAL (`opencode.db-wal`) contiene lo más reciente; el modo `-readonly` lo lee sin problema.

## Limitaciones

- La cuota es por cuenta y **no se sincroniza** entre equipos: el consumo hecho en otra máquina no está en esta base.
- `opencode stats` sí segmenta por modelo, pero no por modelo **y** día a la vez; para eso se consulta la base.
- El `retryAfterMs` y la hora de reinicio son aproximados.
- Todo lo anterior describe el comportamiento observado; no sustituye un dato oficial del servidor, que hoy no existe.
