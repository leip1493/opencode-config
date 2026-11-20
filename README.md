# opencode-config

Configuración y utilidades para medir el consumo de OpenCode y mostrarlo en la barra lateral.

## Contenido

- [`tui/statusline/`](tui/statusline/) — plugin de la TUI con dos bloques: límites de OpenCode Go y estimación de los modelos free. Incluye instrucciones.
- [`scripts/free-quota.sh`](scripts/free-quota.sh) — estima el consumo de la ventana free en curso y el margen antes del próximo bloqueo.
- [`install.sh`](install.sh) — instala el plugin y el script en `~/.config/opencode/statusline`.
- [`docs/cuota-free-opencode.md`](docs/cuota-free-opencode.md) — qué se puede y qué no saber sobre la cuota de los modelos free, hallazgos medidos y consultas SQL reutilizables.

## Instalación rápida

```sh
./install.sh          # copia el plugin y el script a ~/.config/opencode/statusline
./install.sh --check  # verifica que la copia coincide con el repo
```

Luego reinicia OpenCode. La fila `free` aparece dentro de la lista `Límites`, junto a `5h`, `sem` y `mes`; pasa el mouse por encima (o haz clic) para ver el detalle. `/uso` muestra todo el desglose.

## Uso del estimador por separado

```sh
./scripts/free-quota.sh              # resumen de la ventana en curso
./scripts/free-quota.sh --historico  # una fila por ventana diaria
./scripts/free-quota.sh --json       # salida para otras herramientas
```

Variables opcionales:

- `OPENCODE_DB` — ruta de la base (por defecto `~/.local/share/opencode/opencode.db`).
- `FREE_RESET_UTC` — hora UTC del reinicio diario observado (por defecto `00:26:48`).
- `FREE_TRANSIENT_SECS` — duración máxima de un bloqueo para considerarlo transitorio (por defecto `600`).

## Fuente de datos

Todo se lee **en solo lectura** de la base local de OpenCode. No se escribe ni se modifica nada.

## Reglas

- Sin secretos en el repo: la base contiene credenciales, no se copia aquí.
- Los números son **estimaciones**: el servidor no publica la cuota de los modelos free.
