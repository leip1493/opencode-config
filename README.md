# opencode-config

Notas y utilidades para entender y medir el consumo de OpenCode.

## Contenido

- [`docs/cuota-free-opencode.md`](docs/cuota-free-opencode.md) — qué se puede y qué no saber sobre la cuota de los modelos free, hallazgos medidos y consultas SQL reutilizables.
- [`scripts/free-quota.sh`](scripts/free-quota.sh) — estima el consumo de la ventana en curso y el margen que queda antes del próximo bloqueo.

## Uso rápido

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
