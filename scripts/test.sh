#!/usr/bin/env bash
# Pruebas locales del estimador y del instalador, sin depender del SO.
# Crea una base SQLite de prueba, apunta HOME/XDG/APPDATA a carpetas falsas y
# simula date de BSD y de GNU. Se puede correr en macOS, Linux y Windows (Git Bash).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUOTA="$ROOT/scripts/free-quota.sh"
INSTALL="$ROOT/install.sh"
TMP="$ROOT/.tmp/tests"
PASSED=0
FAILED=0

ok() { printf 'ok     %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() {
  printf 'FALLA  %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
  FAILED=$((FAILED + 1))
}
# assert_contains <desc> <texto> <patrón>
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "no contiene: $3"; fi
}
assert_exit() {
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, se esperaba $3"; fi
}

rm -rf "$TMP"
mkdir -p "$TMP"
cleanup() {
  rm -rf "$TMP"
  rmdir "$ROOT/.tmp" 2>/dev/null || true
}
trap cleanup EXIT

# --- fecha portable para preparar los datos de prueba -----------------------
if date -u -r 0 '+%s' >/dev/null 2>&1; then
  ts() { date -u -r "$1" "$2"; }
elif date -u -d '@0' '+%s' >/dev/null 2>&1; then
  ts() { date -u -d "@$1" "$2"; }
else
  echo "Este date no soporta marcas de tiempo; no se pueden correr las pruebas." >&2
  exit 2
fi

# --- sintaxis y linter ------------------------------------------------------
for file in "$QUOTA" "$INSTALL" "$ROOT/scripts/test.sh"; do
  if bash -n "$file" 2>/dev/null; then ok "sintaxis $(basename "$file")"; else bad "sintaxis $(basename "$file")"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$QUOTA" "$INSTALL"; then ok "shellcheck"; else bad "shellcheck"; fi
else
  printf 'omite  shellcheck (no está instalado)\n'
fi

# --- datos de prueba --------------------------------------------------------
NOW=$(date -u +%s)
FREE_RESET_UTC=$(ts $((NOW - 43200)) '+%H:%M:%S')
IFS=: read -r ah am as <<< "$FREE_RESET_UTC"
ANCHOR=$((10#$ah * 3600 + 10#$am * 60 + 10#$as))
WS=$(( (NOW - NOW % 86400) + ANCHOR ))
[ "$WS" -gt "$NOW" ] && WS=$((WS - 86400))

CALLS=25

# make_db <ruta> <llamadas> <con_bloqueo 0|1>
make_db() {
  local db="$1" calls="$2" block="$3" i t
  sqlite3 "$db" "create table session_message (type text, time_created integer, data text);"
  for ((i = 0; i < calls; i++)); do
    t=$((WS + 600 + i * 60))
    sqlite3 "$db" "insert into session_message values ('assistant', $((t * 1000)), '{\"model\":{\"id\":\"deepseek-v4.1-flash-free\"},\"tokens\":{\"input\":100,\"output\":50,\"reasoning\":10,\"cache\":{\"read\":5}}}');"
  done
  if [ "$block" = 1 ]; then
    t=$((WS + 2600))
    sqlite3 "$db" "insert into session_message values ('assistant', $((t * 1000)), '{\"model\":{\"id\":\"deepseek-v4.1-flash-free\"},\"error\":{\"type\":\"provider.free-limit\",\"retryAfterMs\":86400000}}');"
  fi
}

mkdir -p "$TMP/data/opencode"
DB="$TMP/data/opencode/opencode.db"
make_db "$DB" "$CALLS" 1

# Corre el estimador con un entorno mínimo y controlado.
run_quota() {
  local home="$1"
  shift
  env -i PATH="$PATH" HOME="$home" FREE_RESET_UTC="$FREE_RESET_UTC" "$@" \
    bash "$QUOTA" --json
}

# --- búsqueda de la base ----------------------------------------------------
out=$(run_quota "$TMP/nohome" XDG_DATA_HOME="$TMP/data"); code=$?
assert_exit "encuentra la base en XDG_DATA_HOME" "$code" 0
assert_contains "cuenta llamadas de la ventana" "$out" '"calls": 25,'
assert_contains "suma tokens sin caché" "$out" '"tokens": 4000,'
assert_contains "suma caché leída" "$out" '"cache_read": 125'
assert_contains "registra el bloqueo de la ventana" "$out" '"blocks_in_window": 1,'

ref=$(printf '%s' "$out" | sed -n '/"reference": {/,/}/p')
assert_contains "el bloqueo duro fija el techo de llamadas" "$ref" '"calls": 25,'
assert_contains "el bloqueo duro fija el techo de tokens" "$ref" '"tokens": 4000,'
assert_contains "el bloqueo no es transitorio" "$ref" '"transient": false'

mkdir -p "$TMP/win/opencode"
cp "$DB" "$TMP/win/opencode/opencode.db"
out=$(run_quota "$TMP/nohome" LOCALAPPDATA="$TMP/win"); code=$?
assert_exit "encuentra la base en LOCALAPPDATA (Windows)" "$code" 0
assert_contains "lee la base de Windows" "$out" '"calls": 25,'

mkdir -p "$TMP/appdata/opencode"
cp "$DB" "$TMP/appdata/opencode/opencode.db"
out=$(run_quota "$TMP/nohome" APPDATA="$TMP/appdata"); code=$?
assert_exit "encuentra la base en APPDATA (Windows)" "$code" 0

out=$(run_quota "$TMP/nohome" OPENCODE_DB="$DB"); code=$?
assert_exit "respeta OPENCODE_DB" "$code" 0

out=$(run_quota "$TMP/nohome" OPENCODE_DB="$TMP/no-existe.db" 2>&1); code=$?
assert_exit "falla si OPENCODE_DB no se puede leer" "$code" 1
assert_contains "avisa de la ruta inválida" "$out" "No se puede leer OPENCODE_DB"

out=$(run_quota "$TMP/vacio" 2>&1); code=$?
assert_exit "falla si no hay base" "$code" 1
assert_contains "explica cómo indicar la ruta" "$out" "OPENCODE_DB=/ruta/a/opencode.db"

# --- sin bloqueos: la referencia queda vacía --------------------------------
mkdir -p "$TMP/clean/opencode"
make_db "$TMP/clean/opencode/opencode.db" "$CALLS" 0
out=$(run_quota "$TMP/nohome" XDG_DATA_HOME="$TMP/clean"); code=$?
assert_exit "lee una ventana sin bloqueos" "$code" 0
assert_contains "no inventa techo sin bloqueos" "$out" '"calls": null,'
assert_contains "no hay 429 en la ventana" "$out" '"blocks_in_window": 0,'

# --- date de BSD y de GNU ---------------------------------------------------
# El estilo nativo ya quedó probado arriba. Aquí se emula el otro para cubrir
# las dos ramas de detección en cualquier sistema.
mkdir -p "$TMP/shim"
REAL_BSD=0
date -u -r 0 '+%s' >/dev/null 2>&1 && REAL_BSD=1

base=$(run_quota "$TMP/nohome" XDG_DATA_HOME="$TMP/data")
end=$(printf '%s' "$base" | sed -n 's/.*"window_end": "\([^"]*\)".*/\1/p')

if [ "$REAL_BSD" = "1" ]; then
  # macOS: se emula GNU (-d @N sobre un date BSD que solo entiende -r).
  cat > "$TMP/shim/date" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-r" ] && exit 1; done
args=("$@")
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = "-d" ] && [[ "${args[$((i + 1))]}" == @* ]]; then
    args[$i]="-r"
    args[$((i + 1))]="${args[$((i + 1))]#@}"
  fi
done
exec /bin/date "${args[@]}"
SH
  style="GNU"
else
  # Linux: se emula BSD (-r N sobre un date GNU que solo entiende -d @N).
  cat > "$TMP/shim/date" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-d" ] && exit 1; done
args=("$@")
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = "-r" ] && [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" =~ ^[0-9]+$ ]]; then
    args[$i]="-d"
    args[$((i + 1))]="@${args[$((i + 1))]}"
  fi
done
exec /bin/date "${args[@]}"
SH
  style="BSD"
fi
chmod +x "$TMP/shim/date"

out=$(run_quota "$TMP/nohome" XDG_DATA_HOME="$TMP/data" PATH="$TMP/shim:$PATH"); code=$?
assert_exit "funciona con date estilo $style" "$code" 0
assert_contains "misma ventana con $style" "$out" "\"window_end\": \"$end\""

# --- instalador -------------------------------------------------------------
cfg="$TMP/cfg"
mkdir -p "$cfg/statusline"
cp "$ROOT/tui/statusline/tui.tsx" "$cfg/statusline/tui.tsx"
cp "$QUOTA" "$cfg/statusline/free-quota.sh"
printf '{"plugins": ["./statusline"]}\n' > "$cfg/cli.json"

OPENCODE_CONFIG_DIR="$cfg" bash "$INSTALL" --check >/dev/null 2>&1; code=$?
assert_exit "install --check acepta una copia al día" "$code" 0

printf '\n' >> "$cfg/statusline/tui.tsx"
OPENCODE_CONFIG_DIR="$cfg" bash "$INSTALL" --check >/dev/null 2>&1; code=$?
assert_exit "install --check detecta una copia distinta" "$code" 1

fresh="$TMP/cfg-fresh"
OPENCODE_CONFIG_DIR="$fresh" bash "$INSTALL" >/dev/null 2>&1; code=$?
assert_exit "install copia en un directorio nuevo" "$code" 0
[ -f "$fresh/statusline/tui.tsx" ] && ok "queda tui.tsx instalado" || bad "queda tui.tsx instalado"
[ -x "$fresh/statusline/free-quota.sh" ] && ok "queda free-quota.sh ejecutable" || bad "queda free-quota.sh ejecutable"
if command -v python3 >/dev/null 2>&1; then
  grep -q '"./statusline"' "$fresh/cli.json" && ok "cli.json registra el plugin" || bad "cli.json registra el plugin"
else
  printf 'omite  cli.json (sin python3)\n'
fi

# --- resultado --------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
  echo "Todo bien: $PASSED pruebas."
  exit 0
fi
echo "$FAILED fallas de $((PASSED + FAILED)) pruebas."
exit 1
