#!/usr/bin/env bash
# Estima el consumo de la ventana free en curso y el margen antes del próximo bloqueo.
# Lee en solo lectura la base local de OpenCode. No modifica nada.
set -euo pipefail

# Ruta de la base: OPENCODE_DB manda. Si no, se busca en las ubicaciones
# típicas de macOS, Linux y Windows (Git Bash).
DB_OVERRIDE="${OPENCODE_DB:-}"
FREE_RESET_UTC="${FREE_RESET_UTC:-00:26:48}"
TRANSIENT_SECS="${FREE_TRANSIENT_SECS:-600}"
MODE="resumen"

usage() {
  cat <<'TXT'
Uso: free-quota.sh [opción]

  (sin opción)   Resumen de la ventana en curso
  --historico    Una fila por ventana diaria
  --json         Salida JSON
  --help         Esta ayuda

Variables:
  OPENCODE_DB            Base de OpenCode (por defecto ~/.local/share/opencode/opencode.db)
  FREE_RESET_UTC         Hora UTC del reinicio diario observado (por defecto 00:26:48)
  FREE_TRANSIENT_SECS    Segundos para considerar transitorio un bloqueo (por defecto 600)

Lea docs/cuota-free-opencode.md para el detalle del método y sus límites.
TXT
}

case "${1:-}" in
  "" ) MODE="resumen" ;;
  --historico|-h ) MODE="historico" ;;
  --json ) MODE="json" ;;
  --help|help ) usage; exit 0 ;;
  * ) echo "Opción desconocida: $1" >&2; usage >&2; exit 1 ;;
esac

command -v sqlite3 >/dev/null 2>&1 || {
  echo "Falta sqlite3 en el PATH." >&2
  echo "  macOS/Linux: suele venir instalado." >&2
  echo "  Windows: instálalo con 'scoop install sqlite', 'choco install sqlite' o desde sqlite.org." >&2
  exit 1
}

# En Git Bash las rutas nativas y POSIX no son intercambiables; cygpath las traduce.
if command -v cygpath >/dev/null 2>&1; then
  to_posix() { cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; }
  to_native() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
else
  to_posix() { printf '%s' "$1"; }
  to_native() { printf '%s' "$1"; }
fi

probe_db() {
  [ -n "${1:-}" ] || return 1
  sqlite3 -readonly "$1" "select 1" >/dev/null 2>&1
}

usable_db() {
  local candidate="$1" alt
  if probe_db "$candidate"; then printf '%s' "$candidate"; return 0; fi
  alt="$(to_posix "$candidate")"
  if [ "$alt" != "$candidate" ] && probe_db "$alt"; then printf '%s' "$alt"; return 0; fi
  alt="$(to_native "$candidate")"
  if [ "$alt" != "$candidate" ] && probe_db "$alt"; then printf '%s' "$alt"; return 0; fi
  return 1
}

find_db() {
  local candidates=() candidate
  [ -n "${XDG_DATA_HOME:-}" ] && candidates+=("$XDG_DATA_HOME/opencode/opencode.db")
  [ -n "${HOME:-}" ] && candidates+=("$HOME/.local/share/opencode/opencode.db")
  [ -n "${LOCALAPPDATA:-}" ] && candidates+=("$LOCALAPPDATA/opencode/opencode.db")
  [ -n "${APPDATA:-}" ] && candidates+=("$APPDATA/opencode/opencode.db")
  [ -n "${HOME:-}" ] && candidates+=("$HOME/Library/Application Support/opencode/opencode.db")
  [ -n "${HOME:-}" ] && candidates+=("$HOME/AppData/Local/opencode/opencode.db")
  for candidate in "${candidates[@]}"; do
    if usable_db "$candidate"; then return 0; fi
  done
  return 1
}

if [ -n "$DB_OVERRIDE" ]; then
  DB="$(usable_db "$DB_OVERRIDE")" || {
    echo "No se puede leer OPENCODE_DB: $DB_OVERRIDE" >&2
    exit 1
  }
else
  DB="$(find_db)" || {
    echo "No se encontró la base de OpenCode." >&2
    echo "  Indica la ruta con: OPENCODE_DB=/ruta/a/opencode.db free-quota.sh" >&2
    exit 1
  }
fi

IFS=: read -r ah am as <<< "$FREE_RESET_UTC"
ANCHOR=$(( 10#$ah * 3600 + 10#$am * 60 + 10#$as ))
NOW=$(date -u +%s)
MID=$(( NOW - NOW % 86400 ))
WS=$(( MID + ANCHOR ))
[ "$WS" -gt "$NOW" ] && WS=$(( WS - 86400 ))
WE=$(( WS + 86400 ))

sql() {
  sqlite3 -readonly -noheader -separator '|' \
    -cmd ".parameter set @ws $WS" \
    -cmd ".parameter set @we $WE" \
    -cmd ".parameter set @now $NOW" \
    -cmd ".parameter set @anchor $ANCHOR" \
    -cmd ".parameter set @transient $TRANSIENT_SECS" \
    "$DB" "$1"
}

FREE="type='assistant' and json_extract(data,'\$.model.id') like '%-free'"

# --- consumo de la ventana en curso ---
IFS='|' read -r USED_CALLS USED_TOK USED_CACHE < <(sql "
  select count(*),
         ifnull(sum(json_extract(data,'\$.tokens.input')+json_extract(data,'\$.tokens.output')+json_extract(data,'\$.tokens.reasoning')),0),
         ifnull(sum(json_extract(data,'\$.tokens.cache.read')),0)
  from session_message
  where $FREE
    and json_extract(data,'\$.error.type') is null
    and time_created >= @ws*1000 and time_created < @we*1000;")

IFS='|' read -r WIN_BLOCKS < <(sql "
  select count(*) from session_message
  where type='assistant'
    and json_extract(data,'\$.error.type')='provider.free-limit'
    and time_created >= @ws*1000 and time_created < @we*1000;")

# --- techo: menor consumo en bloqueos duros (sin recuperación antes del reinicio anunciado) ---
REF=$(sql "
  with b as (
    select time_created t,
      time_created + ifnull(json_extract(data,'\$.error.retryAfterMs'),0) reset,
      (strftime('%s', date(time_created/1000 - @anchor,'unixepoch')) + @anchor) * 1000 ws,
      (select min(s.time_created) from session_message s
        where s.type='assistant' and json_extract(s.data,'\$.model.id') like '%-free'
          and json_extract(s.data,'\$.error.type') is null
          and s.time_created > session_message.time_created) next_ok
    from session_message
    where type='assistant' and json_extract(data,'\$.error.type')='provider.free-limit'
  ), u as (
    select b.t, b.reset, b.next_ok,
      (select count(*) from session_message s
        where s.type='assistant' and json_extract(s.data,'\$.model.id') like '%-free'
          and json_extract(s.data,'\$.error.type') is null
          and s.time_created >= b.ws and s.time_created < b.t) calls,
      (select ifnull(sum(json_extract(s.data,'\$.tokens.input')+json_extract(s.data,'\$.tokens.output')+json_extract(s.data,'\$.tokens.reasoning')),0)
        from session_message s
        where s.type='assistant' and json_extract(s.data,'\$.model.id') like '%-free'
          and json_extract(s.data,'\$.error.type') is null
          and s.time_created >= b.ws and s.time_created < b.t) tokens
    from b
  ), hard as (
    select * from u
    where next_ok is null or next_ok >= reset
  ), mx as (select max(calls) m from hard)
  select
    (select calls  from hard, mx where calls  >= max(20, mx.m/10) order by calls asc,  t asc limit 1),
    (select tokens from hard, mx where calls  >= max(20, mx.m/10) order by tokens asc, t asc limit 1),
    (select t      from hard, mx where calls  >= max(20, mx.m/10) order by t desc limit 1);")

REF_CALLS=""; REF_TOK=""; REF_T=""; REF_TRANSIENT=""
if [ -n "$REF" ]; then
  IFS='|' read -r REF_CALLS REF_TOK REF_T <<< "$REF"
fi

# --- piso: mayor consumo de una ventana sin bloqueos ---
IFS='|' read -r PAST_CLEAN < <(sql "
  with d as (
    select date(time_created/1000 - @anchor,'unixepoch') dia,
           sum(case when json_extract(data,'\$.model.id') like '%-free'
                     and json_extract(data,'\$.error.type') is null then 1 else 0 end) calls,
           sum(case when json_extract(data,'\$.error.type')='provider.free-limit' then 1 else 0 end) blocks
    from session_message where type='assistant' group by dia
  )
  select ifnull(max(calls),0) from d
  where blocks = 0 and dia < date(@now - @anchor,'unixepoch');")

FLOOR_CALLS=$USED_CALLS
[ "${PAST_CLEAN:-0}" -gt "$FLOOR_CALLS" ] 2>/dev/null && FLOOR_CALLS=$PAST_CLEAN

# Si la ventana en curso ya superó el techo sin bloquearse, la referencia quedó obsoleta.
REF_STALE=""
if [ -n "${REF_CALLS:-}" ] && [ -n "${REF_TOK:-}" ] \
   && [ "$USED_CALLS" -gt "$REF_CALLS" ] && [ "$USED_TOK" -gt "$REF_TOK" ]; then
  REF_STALE="1"
fi

# --- último bloqueo y si fue transitorio ---
LAST=$(sql "
  with b as (
    select time_created t from session_message
    where type='assistant' and json_extract(data,'\$.error.type')='provider.free-limit'
    order by time_created desc limit 1
  )
  select b.t,
    (select min(s.time_created) from session_message s
      where s.type='assistant' and json_extract(s.data,'\$.model.id') like '%-free'
        and json_extract(s.data,'\$.error.type') is null
        and s.time_created > b.t)
  from b;")

LAST_T=""; LAST_GAP=""; LAST_TRANSIENT=""
if [ -n "$LAST" ]; then
  IFS='|' read -r LAST_T NEXT_OK <<< "$LAST"
  if [ -n "${NEXT_OK:-}" ]; then
    LAST_GAP=$(( (NEXT_OK - LAST_T) / 1000 ))
    [ "$LAST_GAP" -le "$TRANSIENT_SECS" ] && LAST_TRANSIENT="1"
  fi
fi

# BSD/macOS usa -r; GNU/Linux usa -d @. Se elige una vez según lo que soporte date.
if date -u -r 0 '+%s' >/dev/null 2>&1; then
  fmt_ts() { date -u -r "$1" '+%Y-%m-%d %H:%M:%S'; }
  fmt_local() { date -r "$1" '+%H:%M'; }
elif date -u -d '@0' '+%s' >/dev/null 2>&1; then
  fmt_ts() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'; }
  fmt_local() { date -d "@$1" '+%H:%M'; }
else
  echo "El comando date no soporta marcas de tiempo; instala coreutils." >&2
  exit 1
fi
human() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n>=1e9) printf "%.2fB", n/1e9
    else if (n>=1e6) printf "%.2fM", n/1e6
    else if (n>=1e3) printf "%.1fk", n/1e3
    else printf "%d", n
  }'
}
thousands() {
  awk -v n="${1:-0}" 'BEGIN{ s=sprintf("%d",n); out=""; while (length(s)>3) { out="," substr(s,length(s)-2) out; s=substr(s,1,length(s)-3) } print s out }'
}
remaining_rest() { [ -n "$REF_CALLS" ] && echo "$(( (WE - NOW) / 60 )) min" || echo ""; }

REM_LO=0; REM_HI=0; TOK_LO=0; TOK_HI=0
if [ -n "$REF_CALLS" ]; then
  REM_HI=$(( REF_CALLS - USED_CALLS )); [ "$REM_HI" -lt 0 ] && REM_HI=0
  TOK_HI=$(( REF_TOK - USED_TOK ));    [ "$TOK_HI" -lt 0 ] && TOK_HI=0
  REM_LO=$(( FLOOR_CALLS - USED_CALLS )); [ "$REM_LO" -lt 0 ] && REM_LO=0
fi

if [ "${REF_STALE:-0}" = "1" ]; then
  REM_JSON="null"
else
  REM_JSON="{ \"calls\": [ $REM_LO, $REM_HI ], \"tokens\": [ $TOK_LO, $TOK_HI ] }"
fi

if [ "$MODE" = "json" ]; then
  cat <<JSON
{
  "window_start": "$(fmt_ts "$WS")Z",
  "window_end": "$(fmt_ts "$WE")Z",
  "now": "$(fmt_ts "$NOW")Z",
  "used": { "calls": $USED_CALLS, "tokens": $USED_TOK, "cache_read": $USED_CACHE },
  "reference": {
    "calls": ${REF_CALLS:-null},
    "tokens": ${REF_TOK:-null},
    "at": "$([ -n "$REF_T" ] && echo "$(fmt_ts "$((REF_T/1000))")Z" || echo "")",
    "transient": $([ "${REF_TRANSIENT:-0}" = "1" ] && echo true || echo false)
  },
  "floor_calls": $FLOOR_CALLS,
  "remaining": $REM_JSON,
  "reference_stale": $([ "${REF_STALE:-0}" = "1" ] && echo true || echo false),
  "blocks_in_window": $WIN_BLOCKS,
  "last_block": "$([ -n "$LAST_T" ] && echo "$(fmt_ts "$((LAST_T/1000))")Z" || echo "")",
  "last_block_transient": $([ "${LAST_TRANSIENT:-0}" = "1" ] && echo true || echo false)
}
JSON
  exit 0
fi

if [ "$MODE" = "historico" ]; then
  echo "OpenCode · ventanas free (corte diario ${FREE_RESET_UTC}Z)"
  printf '%-12s %10s %12s %6s %11s\n' "ventana" "llamadas" "tokens" "429" "al bloquear"
  sql "
    with d as (
      select date(time_created/1000 - @anchor,'unixepoch') dia,
             sum(case when json_extract(data,'\$.model.id') like '%-free'
                       and json_extract(data,'\$.error.type') is null then 1 else 0 end) calls,
             sum(case when json_extract(data,'\$.model.id') like '%-free'
                       and json_extract(data,'\$.error.type') is null
                     then json_extract(data,'\$.tokens.input')+json_extract(data,'\$.tokens.output')+json_extract(data,'\$.tokens.reasoning') else 0 end) tokens,
             sum(case when json_extract(data,'\$.error.type')='provider.free-limit' then 1 else 0 end) blocks
      from session_message where type='assistant' group by dia
    )
    select d.dia, d.calls, d.tokens, d.blocks,
      case when d.blocks = 0 then null else
        (select count(*) from session_message s
          where s.type='assistant' and json_extract(s.data,'\$.model.id') like '%-free'
            and json_extract(s.data,'\$.error.type') is null
            and s.time_created >= (strftime('%s', d.dia) + @anchor)*1000
            and s.time_created < (select max(b.time_created) from session_message b
              where b.type='assistant' and json_extract(b.data,'\$.error.type')='provider.free-limit'
                and date(b.time_created/1000 - @anchor,'unixepoch') = d.dia))
      end
    from d order by d.dia;" \
  | while IFS='|' read -r dia calls tokens blocks at_block; do
      printf '%-12s %10s %12s %6s %11s\n' \
        "$dia" "$(thousands "$calls")" "$(human "$tokens")" "$blocks" "${at_block:--}"
    done
  exit 0
fi

# --- resumen ---
echo "OpenCode · modelos free"
echo "ventana   $(fmt_ts "$WS")Z → $(fmt_ts "$WE")Z  (reinicio $(fmt_local "$WE") local)"
echo "ahora     $(fmt_ts "$NOW")Z"
echo
printf 'llamadas  %-10s piso %-10s techo %-10s quedan %s\n' \
  "$(thousands "$USED_CALLS")" "$(thousands "$FLOOR_CALLS")" "$(thousands "${REF_CALLS:-0}")" \
  "$(if [ -z "$REF_CALLS" ] || [ "${REF_STALE:-0}" = "1" ]; then echo "?"; else echo "${REM_LO}–${REM_HI}"; fi)"
printf 'tokens    %-10s piso %-10s techo %-10s quedan %s\n' \
  "$(human "$USED_TOK")" "$(human "$USED_TOK")" "$(human "${REF_TOK:-0}")" \
  "$(if [ -z "$REF_CALLS" ] || [ "${REF_STALE:-0}" = "1" ]; then echo "?"; else echo "$(human "$TOK_LO")–$(human "$TOK_HI")"; fi)"
printf 'caché     %-10s\n' "$(human "$USED_CACHE")"
printf '429       %s en esta ventana' "$WIN_BLOCKS"
if [ -n "$LAST_T" ]; then
  if [ "${LAST_TRANSIENT:-0}" = "1" ]; then
    printf ' · último %s (transitorio, volvió en %s)\n' "$(fmt_ts "$((LAST_T/1000))")" "$LAST_GAP s"
  else
    printf ' · último %s\n' "$(fmt_ts "$((LAST_T/1000))")"
  fi
else
  echo
fi
if [ -n "$REF_CALLS" ]; then
  echo "referencia muestra del $(fmt_ts "$((REF_T/1000))"): $(thousands "$REF_CALLS") llamadas / $(human "$REF_TOK") tokens"
fi
printf 'reinicio  en %s (%s)\n' "$(remaining_rest)" "$(fmt_local "$WE") local"
if [ "${REF_STALE:-0}" = "1" ]; then
  echo
  echo "aviso: la ventana superó la referencia en llamadas y tokens sin bloquearse;"
  echo "       el techo de $(thousands "$REF_CALLS") queda obsoleto y se recalibra con el próximo 429."
fi
