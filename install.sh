#!/usr/bin/env bash
# Instala el statusline de OpenCode (límites Go + estimación free) desde este repo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Configuración de OpenCode: OPENCODE_CONFIG_DIR manda; si no, se usa la que ya
# exista (XDG, APPDATA en Windows, o ~/.config).
resolve_config_dir() {
  if [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then printf '%s' "$OPENCODE_CONFIG_DIR"; return; fi
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then printf '%s' "$XDG_CONFIG_HOME/opencode"; return; fi
  if [ -n "${APPDATA:-}" ] && [ -d "$APPDATA/opencode" ]; then printf '%s' "$APPDATA/opencode"; return; fi
  if [ -d "$HOME/.config/opencode" ]; then printf '%s' "$HOME/.config/opencode"; return; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      if [ -n "${APPDATA:-}" ]; then printf '%s' "$APPDATA/opencode"; return; fi
      ;;
  esac
  printf '%s' "$HOME/.config/opencode"
}
CONFIG_DIR="$(resolve_config_dir)"
TARGET_DIR="$CONFIG_DIR/statusline"
CLI_JSON="$CONFIG_DIR/cli.json"

SRC_PLUGIN="$REPO_DIR/tui/statusline/tui.tsx"
SRC_QUOTA="$REPO_DIR/scripts/free-quota.sh"

MODE="install"

usage() {
  cat <<'TXT'
Uso: install.sh [--check]

  (sin opción)   Copia tui.tsx y free-quota.sh a la configuración de OpenCode
                 y agrega "./statusline" a cli.json.
  --check        Verifica que la copia instalada coincide con este repo.
  --help         Esta ayuda.

Variables:
  OPENCODE_CONFIG_DIR   Configuración de OpenCode (por defecto la que exista:
                        XDG, APPDATA en Windows, o ~/.config/opencode)

  Requisitos por sistema:
    macOS / Linux   bash, sqlite3, python3 (opcional, para cli.json)
    Windows         Git Bash, sqlite3 en el PATH, python3 (opcional)
TXT
}

for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Opción desconocida: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

[ -f "$SRC_PLUGIN" ] || { echo "Falta $SRC_PLUGIN" >&2; exit 1; }
[ -f "$SRC_QUOTA" ] || { echo "Falta $SRC_QUOTA" >&2; exit 1; }

check_pair() {
  local name="$1" src="$2" dst="$3"
  if [ ! -e "$dst" ]; then
    echo "falta      $name ($dst)"
    return 1
  fi
  if ! cmp -s "$src" "$dst"; then
    echo "distinto   $name ($dst)"
    return 1
  fi
  echo "ok         $name"
  return 0
}

if [ "$MODE" = "check" ]; then
  status=0
  check_pair "tui.tsx" "$SRC_PLUGIN" "$TARGET_DIR/tui.tsx" || status=1
  check_pair "free-quota.sh" "$SRC_QUOTA" "$TARGET_DIR/free-quota.sh" || status=1
  if [ -f "$CLI_JSON" ] && grep -q '"./statusline"' "$CLI_JSON"; then
    echo "ok         cli.json (./statusline)"
  else
    echo "falta      cli.json con \"./statusline\" en plugins"
    status=1
  fi
  [ "$status" -eq 0 ] && echo && echo "Todo al día. Si acabas de instalar, ejecuta: opencode reload"
  exit "$status"
fi

mkdir -p "$TARGET_DIR"

backup() {
  local dst="$1" src="$2"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp "$dst" "$dst.bak-$stamp"
    echo "respaldo   $dst.bak-$stamp"
  fi
}

backup "$TARGET_DIR/tui.tsx" "$SRC_PLUGIN"
backup "$TARGET_DIR/free-quota.sh" "$SRC_QUOTA"

cp "$SRC_PLUGIN" "$TARGET_DIR/tui.tsx"
cp "$SRC_QUOTA" "$TARGET_DIR/free-quota.sh"
chmod +x "$TARGET_DIR/free-quota.sh" 2>/dev/null || true
echo "copiado    $TARGET_DIR/tui.tsx"
echo "copiado    $TARGET_DIR/free-quota.sh"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$CLI_JSON" <<'PY'
import json, os, sys

path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)

plugins = data.setdefault("plugins", [])
if "./statusline" in plugins:
    print("cli.json   ./statusline ya estaba")
else:
    plugins.append("./statusline")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print("cli.json   agregado ./statusline")
PY
else
  echo "aviso      sin python3: agrega \"./statusline\" en plugins de $CLI_JSON"
fi

echo
echo "Listo. Ejecuta: opencode reload   (si la barra no cambia, reinicia OpenCode)"
