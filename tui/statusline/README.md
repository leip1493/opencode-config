# Statusline de OpenCode

Plugin de la TUI que agrega una lista de límites a la barra lateral:

- **Go** — filas `5h`, `sem` y `mes` con su barra y reinicio. Sale del endpoint experimental de uso.
- **free** — una fila más, con el mismo formato, que usa la dimensión más exigida (llamadas o tokens) contra su techo estimado. Sale de `free-quota.sh`, que lee en solo lectura la base local de OpenCode.

Al pasar el mouse sobre la fila `free` aparece una tarjeta centrada en la ventana con el detalle: ventana, llamadas y tokens usados contra su techo, caché, último 429 y reinicio. Un clic la fija y otro clic la suelta.

Además, el comando `/uso` (o `statusline.usage` en la paleta) muestra el detalle de ambos.

## Instalación

Desde la raíz del repo:

```sh
./install.sh
```

El instalador:

1. copia `tui.tsx` y `scripts/free-quota.sh` a `~/.config/opencode/statusline/`;
2. agrega `"./statusline"` a `plugins` en `~/.config/opencode/cli.json` (si falta);
3. respalda la versión anterior si era distinta.

Después hay que **reiniciar OpenCode**: los plugins de la TUI se cargan al iniciar.

## Comprobar que está al día

```sh
./install.sh --check
```

Compara la copia instalada con este repo. Si algo cambió, vuelve a ejecutar `./install.sh`.

## Cómo se calcula el bloque free

- **Ventana:** diaria, con reinicio a las `00:26:48 UTC` (20:26 en UTC-4). Se puede cambiar en `scripts/free-quota.sh` con `FREE_RESET_UTC`.
- **Techo:** el menor consumo observado en un bloqueo **duro**, es decir, un 429 sin recuperación antes del reinicio anunciado. Los bloqueos transitorios no cuentan.
- **Barra:** la dimensión más exigida entre llamadas y tokens, contra su techo. El color va de verde a naranja y rojo con paradas en 25%, 50% y 75%.
- **Detalle (hover o clic):** tarjeta centrada con ventana, llamadas usadas/techo, tokens usados/techo, caché, último 429 y reinicio.
- **Referencia vieja:** si una ventana supera el techo en llamadas **y** tokens sin bloquearse, aparece `recalibrando · 429 HH:MM` y el próximo bloqueo duro ajusta el techo.
- La fila free se refresca cada 2 minutos; los límites Go, cada 1.

Detalle del método y de sus límites en [`docs/cuota-free-opencode.md`](../../docs/cuota-free-opencode.md).

## Notas de render (TUI de OpenCode)

Tres cosas comprobadas midiendo la terminal, por si hay que rehacer las filas:

1. **`<span fg>` no colorea.** El runtime dibuja el texto del span pero descarta el color. Para tener varios colores hay que usar un `<text fg={...}>` por tramo.
2. **`content` con `StyledText` no sirve.** Se imprime `[object Object]`: el runtime convierte el objeto a texto. Por eso el color va en textos separados, no en un texto con tramos.
3. **Un `<text>` vacío ocupa una celda.** Si la barra no tiene relleno (0%) o está llena (100%), ese tramo hay que omitirlo con una condición; si no, la barra se corre una columna y la fila deja de alinear.

Para que las filas no se corran, la etiqueta va en una caja de ancho fijo (`width={5}`, `flexShrink={0}`) y cada fila ocupa el ancho disponible (`width="100%"`). Las filas se separan con `gap={1}`.

## Dependencias

- `bash`, `sqlite3`, `date` y `awk` (en macOS vienen de serie).
- La base local de OpenCode en `~/.local/share/opencode/opencode.db`.
- Opcional: `OPENCODE_FREE_QUOTA_SCRIPT` para apuntar a otro `free-quota.sh`.

## Replicar en otra PC

```sh
git clone <este-repo> opencode-config
cd opencode-config
./install.sh
```

Si la configuración de OpenCode vive en otra ruta:

```sh
OPENCODE_CONFIG_DIR="$HOME/.config/opencode" ./install.sh
```
