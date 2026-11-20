# opencode-config

Configuración y utilidades para medir el consumo de OpenCode y mostrarlo en la barra lateral. La fila `free` mide solo los modelos gratuitos con cuota diaria (proveedor `opencode`, los que pueden dar 429); los free de `opencode-go` van dentro de la cuota Go y se muestran aparte como información.

## Contenido

- [`tui/statusline/`](tui/statusline/) — plugin de la TUI con los límites de OpenCode Go, la estimación de los free de Console (cuota diaria) y una fila informativa de los free incluidos en Go. Incluye instrucciones.
- [`scripts/free-quota.sh`](scripts/free-quota.sh) — estima el consumo de la ventana free en curso y el margen antes del próximo bloqueo.
- [`install.sh`](install.sh) — instala el plugin y el script en `~/.config/opencode/statusline`.
- [`docs/cuota-free-opencode.md`](docs/cuota-free-opencode.md) — qué se puede y qué no saber sobre la cuota de los modelos free, hallazgos medidos y consultas SQL reutilizables.

## Instalación rápida

```sh
./install.sh          # copia el plugin y el script a ~/.config/opencode/statusline
./install.sh --check  # verifica que la copia coincide con el repo
```

Luego ejecuta `opencode reload` (o reinicia OpenCode si no reacciona). La fila `free` aparece dentro de la lista `Límites`, junto a `5h`, `sem` y `mes`, y va seguida de una fila `go-free` informativa; pasa el mouse por encima de `free` (o haz clic) para ver el detalle. `/uso` muestra todo el desglose.

## Pruebas

```sh
./scripts/test.sh
```

Corre sin red ni datos reales: crea una base SQLite de prueba, apunta `HOME`, `XDG_DATA_HOME`, `LOCALAPPDATA` y `APPDATA` a carpetas temporales, simula `date` de BSD y de GNU, y verifica la búsqueda de la base, el techo de los bloqueos duros, el respaldo de rutas de Windows y el instalador.

No cubre el dibujo de la TUI ni diferencias reales de Windows (permisos, rutas nativas). Para eso hace falta un CI con matriz macOS/Linux/Windows. Si `shellcheck` está instalado, también lo ejecuta.

## Requisitos por sistema

| Sistema | Qué hace falta |
|---|---|
| **macOS** | Nada extra: `bash`, `sqlite3` y `date` vienen de serie. |
| **Linux** | `bash` y `sqlite3` (con JSON1, estándar desde SQLite 3.24). |
| **Windows** | [Git Bash](https://git-scm.com/download/win) y `sqlite3` en el `PATH` (`scoop install sqlite` o `choco install sqlite`). |

El plugin detecta solo dónde está bash y dónde vive la configuración/base de OpenCode (XDG, APPDATA, `~/.config`, `~/.local/share`, `%LOCALAPPDATA%`). Si tu instalación es distinta:

- `OPENCODE_BASH` — ruta al bash a usar.
- `OPENCODE_DB` — ruta de `opencode.db`.
- `OPENCODE_CONFIG_DIR` — directorio de configuración de OpenCode.

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

## Licencia

MIT. Ver [LICENSE](LICENSE).
