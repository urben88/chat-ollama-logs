#!/usr/bin/env bash
# Chat de terminal genérico para CUALQUIER modelo de Ollama (perfil o modelo base).
# Usa /api/generate con el blob "context" que devuelve la propia Ollama para
# mantener la conversación: así el tamaño de contexto que se muestra es el
# dato REAL que reporta la herramienta, no un cálculo hecho por este script.
# En disco: un log JSONL por modelo (logs/<modelo>.log) con TODO lo necesario
# para validar después: prompt, respuesta, posición en la sesión y todas las
# estadísticas de esa salida concreta.
#
# Uso: ./chat.sh [opciones] <modelo>      (./chat.sh --help para ver todo)
# Ejemplos: ./chat.sh daily-qwen   |   ./chat.sh --num-ctx 8192 qwen3.5:4b
#
# Requiere: ollama, curl, jq

set -euo pipefail

uso() {
  cat <<'AYUDA'
chat.sh — chat de terminal para cualquier modelo de Ollama, con log JSONL completo.

USO
  ./chat.sh [opciones] <modelo>

EJEMPLOS
  ./chat.sh daily-qwen
  ./chat.sh --num-ctx 8192 --num-predict 512 qwen3.5:4b
  ./chat.sh --think off --num-ctx 8192 qwen3.5:2b
  ./chat.sh --temperature 0.2 --seed 42 phi4-mini
  ./chat.sh --options '{"top_k":20,"repeat_penalty":1.1}' llama3.1

OPCIONES (se envían a Ollama en la petición; mandan sobre el Modelfile)
  --num-ctx N        Ventana de contexto (tokens). Cambiarla recarga el modelo si ya
                     estaba cargado con otro valor. Sin esto, Ollama usa el del
                     Modelfile o su valor por defecto.
  --num-predict N    Máximo de tokens a generar por respuesta (-1 = sin límite,
                     -2 = hasta llenar el contexto). Con thinking, el razonamiento
                     también cuenta: un valor bajo puede dejar la respuesta vacía.
  --temperature X    Temperatura de muestreo.
  --seed N           Semilla (para repetir una prueba).
  --options JSON     Objeto JSON con cualquier otra opción de Ollama
                     (top_p, top_k, min_p, repeat_penalty, num_batch, stop...).
                     Los flags de arriba tienen prioridad sobre este objeto.
  --think MODO       Razonamiento: on | off | auto | low | medium | high
                     (auto = no se envía, manda el modelo). Se cambia en caliente con /think.
  --keep-alive T     Cuánto queda el modelo cargado tras responder (p. ej. 10m, 0, -1).
  --max-time S       Tope en segundos por respuesta (por defecto, sin límite).
  -h, --help         Muestra esta ayuda y sale.

  Orden de prioridad: flags > variables de entorno > Modelfile > valores de Ollama.

VARIABLES DE ENTORNO (equivalentes a los flags, como alternativa)
  OLLAMA_HOST          Servidor de Ollama (por defecto http://localhost:11434)
  CHAT_OPTIONS         = --options          CHAT_THINK       = --think
  CHAT_KEEP_ALIVE      = --keep-alive       CHAT_MAX_TIME    = --max-time
  CHAT_NUM_CTX         SOLO cambia el num_ctx que se MUESTRA (para modelos donde
                       /api/show falla, p. ej. gemma3n); no lo envía a Ollama.
                       Para cambiar el real usa --num-ctx.
  CHAT_CONTAR_TOKENS=0 No hace llamadas extra al tokenizador (estima el reparto
                       pensamiento/respuesta por caracteres; no altera la caché).

COMANDOS DENTRO DEL CHAT (también con /ayuda)
  <texto> + Enter      Mensaje normal.
  <<<  ...  >>>        Pegar varias líneas: escribe <<<, pega, y termina con >>>.
  /nueva               Sesión limpia: borra el contexto y abre otro bloque en el log.
  /think [modo]        Alterna el razonamiento (on/off) o lo fija: on|off|auto|low|medium|high.
  /ver                 Muestra u oculta el razonamiento en pantalla (el log lo guarda siempre).
  /stats               Detalle completo del último turno.
  /info                Cabecera completa: parámetros, system prompt, fuente del contexto.
  /ps                  Estado de memoria (ollama ps, VRAM/RAM, GPU); queda en el log.
  /nota <texto>        Guarda una anotación tuya en el log.
  /comparar            El siguiente prompt se prueba dos veces: en frío y en caliente.
  /descargar           Saca el modelo de memoria (la próxima respuesta será en frío).
  /salir               Sale del script (también Ctrl+C o Ctrl+D en el prompt).
  Ctrl+C respondiendo  Cancela ese envío (queda en el log como 'cancelled').

  La barra sobre cada prompt muestra: turno · estado de thinking · contexto usado/ventana.

LOG (logs/<modelo>.log, una línea JSON por evento)
  type: session_start · turn · error · cancelled · think_change · ps_snapshot · note · session_end
  Cada turno guarda prompt, respuesta, razonamiento, tokens, tok/s, contexto, memoria
  (ollama ps + GPU + RAM), tiempos, opciones enviadas y señales de fallo (flags).

REQUIERE  ollama (servidor en marcha), curl, jq
AYUDA
}

# --- Argumentos ---
MODELO=""
OPT_NUM_CTX=""; OPT_NUM_PREDICT=""; OPT_TEMPERATURE=""; OPT_SEED=""
OPT_JSON="${CHAT_OPTIONS:-}"
OPT_THINK="${CHAT_THINK:-}"
OPT_KEEP="${CHAT_KEEP_ALIVE:-}"
OPT_MAXTIME="${CHAT_MAX_TIME:-}"
es_entero() { [[ "$1" =~ ^-?[0-9]+$ ]]; }
falta_valor() { echo "Falta el valor de $1 (mira ./chat.sh --help)." >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) uso; exit 0 ;;
    --num-ctx)     [ $# -ge 2 ] || falta_valor "$1"; OPT_NUM_CTX="$2"; shift 2 ;;
    --num-predict) [ $# -ge 2 ] || falta_valor "$1"; OPT_NUM_PREDICT="$2"; shift 2 ;;
    --temperature) [ $# -ge 2 ] || falta_valor "$1"; OPT_TEMPERATURE="$2"; shift 2 ;;
    --seed)        [ $# -ge 2 ] || falta_valor "$1"; OPT_SEED="$2"; shift 2 ;;
    --options)     [ $# -ge 2 ] || falta_valor "$1"; OPT_JSON="$2"; shift 2 ;;
    --think)       [ $# -ge 2 ] || falta_valor "$1"; OPT_THINK="$2"; shift 2 ;;
    --keep-alive)  [ $# -ge 2 ] || falta_valor "$1"; OPT_KEEP="$2"; shift 2 ;;
    --max-time)    [ $# -ge 2 ] || falta_valor "$1"; OPT_MAXTIME="$2"; shift 2 ;;
    --num-ctx=*)     OPT_NUM_CTX="${1#*=}"; shift ;;
    --num-predict=*) OPT_NUM_PREDICT="${1#*=}"; shift ;;
    --temperature=*) OPT_TEMPERATURE="${1#*=}"; shift ;;
    --seed=*)        OPT_SEED="${1#*=}"; shift ;;
    --options=*)     OPT_JSON="${1#*=}"; shift ;;
    --think=*)       OPT_THINK="${1#*=}"; shift ;;
    --keep-alive=*)  OPT_KEEP="${1#*=}"; shift ;;
    --max-time=*)    OPT_MAXTIME="${1#*=}"; shift ;;
    -*) echo "Opción desconocida: $1 (mira ./chat.sh --help)" >&2; exit 1 ;;
    *) if [ -n "$MODELO" ]; then echo "Solo se admite un modelo (recibí '$MODELO' y '$1')." >&2; exit 1; fi
       MODELO="$1"; shift ;;
  esac
done
[ -n "$MODELO" ] || { echo "Falta el modelo. Uso: ./chat.sh [opciones] <modelo>   (./chat.sh --help)" >&2; exit 1; }
if [ -n "$OPT_NUM_CTX" ]; then
  { es_entero "$OPT_NUM_CTX" && [ "$OPT_NUM_CTX" -gt 0 ]; } || { echo "--num-ctx debe ser un entero > 0 (recibí '$OPT_NUM_CTX')." >&2; exit 1; }
fi
if [ -n "$OPT_NUM_PREDICT" ]; then
  { es_entero "$OPT_NUM_PREDICT" && [ "$OPT_NUM_PREDICT" -ge -2 ] && [ "$OPT_NUM_PREDICT" -ne 0 ]; } || { echo "--num-predict debe ser un entero > 0, -1 (sin límite) o -2 (hasta llenar el contexto); recibí '$OPT_NUM_PREDICT'." >&2; exit 1; }
fi
[[ -z "$OPT_TEMPERATURE" || "$OPT_TEMPERATURE" =~ ^[0-9]*\.?[0-9]+$ ]] || { echo "--temperature debe ser un número (recibí '$OPT_TEMPERATURE')." >&2; exit 1; }
[ -z "$OPT_SEED" ] || es_entero "$OPT_SEED" || { echo "--seed debe ser un entero (recibí '$OPT_SEED')." >&2; exit 1; }
[ -z "$OPT_MAXTIME" ] || es_entero "$OPT_MAXTIME" || { echo "--max-time debe ser un entero de segundos (recibí '$OPT_MAXTIME')." >&2; exit 1; }

HOST="${OLLAMA_HOST:-http://localhost:11434}"
# Tope de segundos para esperar una respuesta. Vacío = SIN LÍMITE
# (espera indefinidamente, con el latido cada 5s para saber que sigue vivo).
MAX_TIME="$OPT_MAXTIME"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
# Nombres tipo "cas/eurollm-1.7b-instruct-q8" contienen "/": se cambia por "__"
# solo en el nombre de fichero (el campo "model" del log conserva el nombre real).
MODELO_FICHERO="${MODELO//\//__}"
LOG_FILE="$LOG_DIR/${MODELO_FICHERO}.log"
HISTFILE="$LOG_DIR/.${MODELO_FICHERO}_history"
touch "$HISTFILE"

SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)"
TURN=0

# --- Colores (se desactivan solos si la salida no es una terminal) ---
if [ -t 1 ]; then
  C_RESET='\033[0m';    C_BOLD='\033[1m'
  C_LABEL='\033[1;34m'  # azul  - cabecera/metadatos
  C_USER='\033[1;36m'   # cian  - tu input
  C_MODEL='\033[1;32m'  # verde - marco de la salida del modelo
  C_STATS='\033[2;33m'  # amarillo tenue - línea de métricas
  C_ERR='\033[1;31m'    # rojo  - errores
else
  C_RESET=''; C_BOLD=''; C_LABEL=''; C_USER=''; C_MODEL=''; C_STATS=''; C_ERR=''
fi

# Marcadores de "invisible" para readline (equivalentes a \[ \] de PS1, pero
# válidos dentro de un prompt de `read -e`). Sin esto, readline cuenta los
# códigos de color como caracteres visibles, calcula mal la posición del
# cursor, y el resultado es texto que se duplica y no se puede borrar bien
# con backspace al escribir en el prompt "└❯ ".
RL_S=$'\001'
RL_E=$'\002'

# Desactiva el "bracketed paste" de readline y del propio terminal. Este script
# usa su PROPIO protocolo explícito para pegar bloques (<<< ... >>>) mezclando
# `read -e` con `read` normales; si el bracketed paste del terminal queda
# activo, un simple Enter puede "reproducir" texto pegado porque los bucles de
# lectura normal no saben interpretar sus marcadores ESC[200~/ESC[201~.
bind 'set enable-bracketed-paste off' 2>/dev/null || true
printf '\e[?2004l' 2>/dev/null || true

# Historial persistente de inputs por modelo (flechas ↑/↓ entre sesiones)
history -r "$HISTFILE" 2>/dev/null || true

# Versión del esquema de log: sube cuando se AÑADEN campos (los antiguos no cambian).
LOG_SCHEMA=2

# Opciones de la petición (flags --num-ctx, --num-predict, --temperature, --seed, --options,
# --think, --keep-alive o sus variables CHAT_*). Se registran SIEMPRE en el log para saber
# con qué condiciones se generó cada turno.
REQ_OPTIONS="$OPT_JSON"
if [ -n "$REQ_OPTIONS" ] && ! echo "$REQ_OPTIONS" | jq -e 'type=="object"' >/dev/null 2>&1; then
  echo "--options / CHAT_OPTIONS no es un objeto JSON válido: $REQ_OPTIONS" >&2
  exit 1
fi
REQ_OPTIONS="$( [ -n "$REQ_OPTIONS" ] && echo "$REQ_OPTIONS" | jq -c . || echo '{}' )"
# Los flags (--num-ctx, --num-predict, --temperature, --seed) mandan sobre --options
REQ_OPTIONS="$(echo "$REQ_OPTIONS" | jq -c \
  --arg nc "$OPT_NUM_CTX" --arg np "$OPT_NUM_PREDICT" --arg t "$OPT_TEMPERATURE" --arg sd "$OPT_SEED" '
    . + (if $nc != "" then {num_ctx: ($nc|tonumber)} else {} end)
      + (if $np != "" then {num_predict: ($np|tonumber)} else {} end)
      + (if $t  != "" then {temperature: ($t|tonumber)} else {} end)
      + (if $sd != "" then {seed: ($sd|tonumber)} else {} end)')"
# num_ctx pedido por el usuario (por flag o dentro de --options), si lo hay
NUM_CTX_PEDIDO="$(echo "$REQ_OPTIONS" | jq -r '.num_ctx // empty')"
KEEP_ALIVE="$OPT_KEEP"

# --- Comprobación de que Ollama responde (sin esto, curl fallaba en silencio) ---
OLLAMA_VERSION="$(curl -s --max-time 5 "$HOST/api/version" | jq -r '.version // empty' 2>/dev/null || true)"
if [ -z "$OLLAMA_VERSION" ]; then
  echo "✖ Ollama no responde en $HOST (¿está arrancado? prueba 'ollama serve' o revisa OLLAMA_HOST)." >&2
  exit 1
fi

# --- Metadatos del modelo, una vez al arrancar (vía API, sirve para cualquier modelo) ---
SHOW_INFO="$(curl -s "$HOST/api/show" -d "$(jq -n --arg m "$MODELO" '{model:$m}')" || true)"
SHOW_ERROR="$(echo "$SHOW_INFO" | jq -r '.error // empty' 2>/dev/null || true)"
if [ -n "$SHOW_ERROR" ]; then
  echo "✖ Ollama no puede mostrar '$MODELO': $SHOW_ERROR" >&2
  exit 1
fi
# Body vacío = bug conocido de /api/show con algunos modelos (gemma3n): se sigue, sin metadatos.
SHOW_JSON="$(echo "$SHOW_INFO" | jq -c . 2>/dev/null || true)"
[ -n "$SHOW_JSON" ] || SHOW_JSON='{}'
SHOW_VACIO=false; [ "$SHOW_JSON" = '{}' ] && SHOW_VACIO=true
PARAMETERS="$(echo "$SHOW_JSON" | jq -r '.parameters // ""')"
SYSTEM_PROMPT="$(echo "$SHOW_JSON" | jq -r '.system // ""')"
CAPABILITIES="$(echo "$SHOW_JSON" | jq -c '.capabilities // []')"
MODEL_DETAILS="$(echo "$SHOW_JSON" | jq -c '.details // {}')"
MODELFILE_TXT="$(echo "$SHOW_JSON" | jq -r '.modelfile // ""')"
TEMPLATE_TXT="$(echo "$SHOW_JSON" | jq -r '.template // ""')"
# Identidad exacta del modelo (digest) para saber, al comparar logs, si es el mismo binario.
MODEL_TAG_INFO="$(curl -s "$HOST/api/tags" 2>/dev/null | jq -c --arg m "$MODELO" '
  [(.models // [])[] | select(.name==$m or .model==$m or .name==($m+":latest") or .model==($m+":latest"))][0]
  | {digest: (.digest // null), modified_at: (.modified_at // null), size_bytes: (.size // null)}' 2>/dev/null || true)"
[ -n "$MODEL_TAG_INFO" ] || MODEL_TAG_INFO='{}'

# Entorno del equipo (una vez): útil para explicar diferencias de rendimiento entre sesiones.
GPU_STATIC="null"
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_STATIC="$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null \
    | head -n1 | jq -R -c 'split(", ") | {name:.[0], driver:.[1], vram_total_mib:(.[2]|tonumber? // null)}' 2>/dev/null || true)"
  [ -n "$GPU_STATIC" ] || GPU_STATIC="null"
fi
HOST_INFO="$(jq -nc --arg h "$(hostname 2>/dev/null || echo ?)" --arg os "$(uname -srm 2>/dev/null || echo ?)" \
  --arg cpu "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || true)" \
  --argjson gpu "$GPU_STATIC" '{hostname:$h, os:$os, cpu:$cpu, gpu:$gpu}')"

# Estado de la conversación
CONTEXT='[]'
CONTEXT_LEN=0
LAST_STATS=""
MOSTRAR_RAZONAMIENTO=true
CTX_PS_ACTUAL=""
COMPARAR_SIGUIENTE=false
# Modo thinking: auto = no se envía el campo (manda el modelo), on/off = think:true/false,
# low|medium|high = nivel de esfuerzo (modelos que lo admiten, p. ej. gpt-oss)
THINK_MODE="${OPT_THINK:-auto}"
case "$THINK_MODE" in on|off|auto|low|medium|high) ;; *) echo "--think / CHAT_THINK inválido: $THINK_MODE (usa on|off|auto|low|medium|high)" >&2; exit 1 ;; esac
MODEL_STATE=""

# Contadores de la sesión (para el registro session_end)
SES_ERRORES=0; SES_CANCELADOS=0; SES_TURNOS_OK=0
SES_EVAL_TOK=0; SES_PROMPT_TOK=0; SES_EVAL_SEG=0; SES_WALL_SEG=0
SES_FIN_LOGUEADO=true   # se pone a false al abrir la primera sesión
SES_FLAGS_LIST=""; SES_INICIO_EPOCH=0
SALIDA_MOTIVO="exit"

al_salir() {
  history -w "$HISTFILE" 2>/dev/null || true
  loguear_fin_sesion "$SALIDA_MOTIVO" 2>/dev/null || true
}
trap al_salir EXIT

# Detección de num_ctx con prioridad: -1) el pedido con --num-ctx, 0) override manual (CHAT_NUM_CTX),
# 1) PARAMETER num_ctx explícito del Modelfile, 2) context_length del modelo
# base (model_info), 3) 4096 como último recurso. Se guarda de dónde sale el
# número (NUM_CTX_FUENTE) para poder ver en la cabecera si alguna vez cae al
# valor por defecto en vez de detectar el real.
#
# El override manual existe porque hay modelos (p. ej. los basados en
# gemma3n, como writer-gemma) donde /api/show devuelve el body VACÍO por un
# bug de Ollama al serializar un valor -Inf de sus metadatos — para esos
# casos la detección automática nunca puede funcionar, así que si ya sabes
# el num_ctx real (por tu Modelfile o por "ollama ps"), pásaselo a mano:
#   CHAT_NUM_CTX=16384 ./chat.sh writer-gemma
NUM_CTX_PARAM="$(echo "$PARAMETERS" | awk 'tolower($1)=="num_ctx"{print $2; exit}')"
NUM_CTX_MODEL="$(echo "$SHOW_JSON" | jq -r '(.model_info // {}) | to_entries[] | select(.key | test("context_length$")) | .value' | head -n1)"
if [ -n "$NUM_CTX_PEDIDO" ]; then
  NUM_CTX="$NUM_CTX_PEDIDO"
  NUM_CTX_FUENTE="pedido al arrancar (--num-ctx / --options; se envía a Ollama)"
elif [ -n "${CHAT_NUM_CTX:-}" ]; then
  NUM_CTX="$CHAT_NUM_CTX"
  NUM_CTX_FUENTE="override manual (CHAT_NUM_CTX=$CHAT_NUM_CTX)"
elif [ -n "$NUM_CTX_PARAM" ]; then
  NUM_CTX="$NUM_CTX_PARAM"
  NUM_CTX_FUENTE="PARAMETER num_ctx del Modelfile"
elif [ -n "$NUM_CTX_MODEL" ]; then
  NUM_CTX="$NUM_CTX_MODEL"
  NUM_CTX_FUENTE="context_length del modelo base (model_info)"
else
  NUM_CTX=4096
  NUM_CTX_FUENTE="valor por defecto — NO se pudo detectar, revisa /api/show"
fi

# Consulta /api/ps (modelos actualmente cargados en Ollama) para saber, ANTES
# de mandar ningún mensaje, si $MODELO ya está en memoria o si el primer turno
# tendrá que cargarlo (cold start). Deja el resultado en ESTADO_INICIAL_TXT.
verificar_estado_modelo() {
  local ps_info cargado
  ps_info="$(curl -s "$HOST/api/ps" 2>/dev/null || echo '{}')"
  cargado="$(echo "$ps_info" | jq -r --arg m "$MODELO" '
    (.models // [])[]? | select(.name==$m or .name==($m+":latest") or .model==$m or .model==($m+":latest")) | .name
  ' 2>/dev/null | head -n1)"
  if [ -n "$cargado" ]; then
    # num_ctx REAL con el que Ollama ha cargado el modelo (lo mismo que 'ollama ps').
    # context_length de /api/show es solo el MÁXIMO del modelo, no el efectivo.
    local ctx_ps
    CTX_PS_ACTUAL=""
    ctx_ps="$(echo "$ps_info" | jq -r --arg m "$MODELO" '
      [(.models // [])[]? | select(.name==$m or .name==($m+":latest") or .model==$m or .model==($m+":latest"))][0].context_length // empty
    ' 2>/dev/null)"
    CTX_PS_ACTUAL="$ctx_ps"
    if [ -n "$ctx_ps" ] && [ "$ctx_ps" != "$NUM_CTX" ]; then
      NUM_CTX="$ctx_ps"
      NUM_CTX_FUENTE="api/ps (num_ctx real con el que está cargado, = ollama ps)"
    elif [ -n "$ctx_ps" ]; then
      NUM_CTX_FUENTE="api/ps (num_ctx real con el que está cargado, = ollama ps)"
    fi
    ESTADO_INICIAL="loaded"
    ESTADO_INICIAL_TXT="🔥 en memoria"
  else
    CTX_PS_ACTUAL=""
    ESTADO_INICIAL="not_loaded"
    ESTADO_INICIAL_TXT="🧊 sin cargar (el 1.er mensaje hará carga en frío)"
  fi
}

# Muestra los parámetros más importantes tal cual salen del Modelfile del modelo
# (campo .parameters de /api/show, que incluye los heredados del modelo base).
# Nada se inventa: si un parámetro no está definido se dice explícitamente, y
# entonces Ollama aplica su valor interno por defecto. Los parámetros que no
# están en la lista de importantes se muestran aparte en "otros".
mostrar_parametros() {
  local IMPORTANTES="temperature top_p top_k min_p repeat_penalty repeat_last_n presence_penalty frequency_penalty num_ctx num_predict num_batch seed stop"
  local k v otros
  for k in $IMPORTANTES; do
    v="$(printf '%s\n' "$PARAMETERS" | awk -v k="$k" 'tolower($1)==k{ $1=""; sub(/^ +/,""); printf "%s%s", (n++?" | ":""), $0 }')"
    if [ -n "$v" ]; then
      printf '  %-18s %s\n' "$k" "$v"
    elif [ "$k" = "num_ctx" ]; then
      printf '  %-18s %s\n' "$k" "no definido en el Modelfile (efectivo: $NUM_CTX · fuente: $NUM_CTX_FUENTE)"
    else
      printf '  %-18s %s\n' "$k" "no definido"
    fi
  done
  otros="$(printf '%s\n' "$PARAMETERS" | awk -v l="$IMPORTANTES" 'BEGIN{n=split(l,a," "); for(i=1;i<=n;i++) m[a[i]]=1} NF && !(tolower($1) in m){print "  " $0}')"
  [ -n "$otros" ] && { echo "  — otros —"; echo "$otros"; }
  if [ -z "$PARAMETERS" ]; then
    echo "  (el Modelfile no define ningún PARAMETER: Ollama usa sus valores internos por defecto)"
  fi
  return 0
}

# Texto del estado de thinking para mostrar junto al turno
think_txt() {
  case "$THINK_MODE" in
    on)  echo "ON" ;;
    off) echo "OFF" ;;
    low|medium|high) echo "nivel $THINK_MODE" ;;
    *)   echo "auto" ;;
  esac
}

# ─────────────────────────── Helpers de log ───────────────────────────
ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Añade una línea al log con la cabecera común (type, session, model, turn,
# timestamp, schema) + los campos extra que llegan como JSON por stdin.
# Los datos van por stdin y NO por argv: los textos largos (prompts de 10k tokens,
# respuestas degeneradas de 80k caracteres) superarían el límite de 128KB por argumento.
log_evento() {
  local tipo="$1"
  jq -c --arg type "$tipo" --arg session "$SESSION_ID" --arg model "$MODELO" \
    --argjson turn "$TURN" --arg ts "$(ts_now)" --argjson schema "$LOG_SCHEMA" \
    '{type:$type, session:$session, model:$model, turn:$turn, timestamp:$ts, schema:$schema} + .' >> "$LOG_FILE"
}

# Foto del modelo en /api/ps (lo mismo que 'ollama ps'): memoria total, parte en
# VRAM (el resto está en RAM/CPU = offload), contexto REAL cargado, cuándo caduca,
# y qué OTROS modelos hay cargados compitiendo por la memoria. "null" si no está cargado.
ps_snapshot() {
  local out
  out="$(curl -s --max-time 5 "$HOST/api/ps" 2>/dev/null | jq -c --arg m "$MODELO" '
    def esm: (.name==$m or .name==($m+":latest") or .model==$m or .model==($m+":latest"));
    (.models // []) as $all
    | ([$all[] | select(esm)][0]) as $me
    | if $me == null then null else {
        size_bytes: ($me.size // null),
        size_vram_bytes: ($me.size_vram // null),
        vram_pct: (if ($me.size // 0) > 0 then ((($me.size_vram // 0) / $me.size) * 1000 | round / 10) else null end),
        context_length: ($me.context_length // null),
        expires_at: ($me.expires_at // null),
        digest: ($me.digest // null),
        otros_modelos_cargados: [$all[] | select(esm | not) | .name]
      } end' 2>/dev/null || true)"
  echo "${out:-null}"
}

# Foto de la GPU NVIDIA (si hay): VRAM usada, carga, temperatura, potencia y reloj.
# Temperatura/reloj/potencia permiten detectar throttling térmico entre turnos.
gpu_snapshot() {
  command -v nvidia-smi >/dev/null 2>&1 || { echo null; return 0; }
  local out
  out="$(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw,clocks.sm \
    --format=csv,noheader,nounits 2>/dev/null | head -n1 \
    | jq -R -c 'split(", ") | map(tonumber? // null)
        | {vram_used_mib:.[0], vram_total_mib:.[1], gpu_util_pct:.[2], temp_c:.[3], power_w:.[4], sm_clock_mhz:.[5]}' 2>/dev/null || true)"
  echo "${out:-null}"
}

# RAM y swap del equipo (Linux). Un swap creciente o poca RAM libre explica lentitud por offload.
ram_snapshot() {
  [ -r /proc/meminfo ] || { echo null; return 0; }
  awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} /^SwapTotal/{st=$2} /^SwapFree/{sf=$2}
       END{printf "{\"ram_total_mib\":%d,\"ram_available_mib\":%d,\"swap_used_mib\":%d}", t/1024, a/1024, (st-sf)/1024}' /proc/meminfo
}

sha256_txt() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else echo ""; fi
}

# Valor del campo "think" que se envía: true/false, nivel (low|medium|high) o nada (auto)
think_json() {
  case "$THINK_MODE" in
    on) echo true ;;
    off) echo false ;;
    low|medium|high) printf '"%s"' "$THINK_MODE" ;;
    *) echo null ;;
  esac
}

# Formato corto de tokens: 1234 -> 1.2k · 20000 -> 20k
fmt_tok() {
  awk -v n="$1" 'BEGIN{ if (n>=10000) printf "%.0fk", n/1000; else if (n>=1000) printf "%.1fk", n/1000; else printf "%d", n }'
}

# Divide los parámetros importantes en "definidos en el Modelfile" y "sin definir".
# Deja el resultado en PARAMS_DEF y PARAMS_NODEF (num_ctx se muestra aparte).
parametros_resumen() {
  local IMPORTANTES="temperature top_p top_k min_p repeat_penalty repeat_last_n presence_penalty frequency_penalty num_predict num_batch seed stop"
  local k v def="" nodef=""
  for k in $IMPORTANTES; do
    v="$(printf '%s\n' "$PARAMETERS" | awk -v k="$k" 'tolower($1)==k{ $1=""; sub(/^ +/,""); printf "%s%s", (n++?" | ":""), $0 }')"
    if [ -n "$v" ]; then def="${def}${def:+ · }${k}=${v}"; else nodef="${nodef}${nodef:+, }${k}"; fi
  done
  PARAMS_DEF="$def"; PARAMS_NODEF="$nodef"
}

# Línea de contexto para cabeceras: qué num_ctx hay y de dónde sale
contexto_txt() {
  if [ -n "${NUM_CTX_PEDIDO:-}" ] && [ -n "${CTX_PS_ACTUAL:-}" ] && [ "$CTX_PS_ACTUAL" != "$NUM_CTX_PEDIDO" ]; then
    echo "pedido $NUM_CTX_PEDIDO · cargado ahora $CTX_PS_ACTUAL → Ollama recargará el modelo con $NUM_CTX_PEDIDO en el primer mensaje"
  else
    case "$NUM_CTX_FUENTE" in
      "context_length del modelo base"*) echo "máx. del modelo $NUM_CTX (el real se conoce al cargarlo; NO es el efectivo)" ;;
      "pedido al arrancar"*) echo "$NUM_CTX (pedido con --num-ctx)" ;;
      "api/ps"*) echo "$NUM_CTX (real, como 'ollama ps')" ;;
      "PARAMETER num_ctx"*) echo "$NUM_CTX (del Modelfile)" ;;
      *) echo "$NUM_CTX (${NUM_CTX_FUENTE})" ;;
    esac
  fi
}

# Cabecera COMPLETA (comando /info): parámetros uno a uno, system prompt entero, fuente del num_ctx…
imprimir_info_completa() {
  verificar_estado_modelo
  echo -e "${C_LABEL}${C_BOLD}══════════════════════════════════════${C_RESET}"
  echo -e "${C_LABEL} Modelo:${C_RESET} $MODELO   ${C_LABEL}sesión:${C_RESET} $SESSION_ID   ${C_LABEL}Ollama:${C_RESET} $OLLAMA_VERSION"
  echo -e "${C_LABEL} Log:${C_RESET}    $LOG_FILE"
  echo -e "${C_LABEL} Estado:${C_RESET}  $ESTADO_INICIAL_TXT"
  if [ "$SHOW_VACIO" = true ]; then
    echo -e "${C_ERR} /api/show devolvió el body vacío (bug conocido, p. ej. gemma3n): sin parámetros, capacidades ni detalles del modelo.${C_RESET}"
  else
    echo -e "${C_LABEL} Modelo base:${C_RESET} $(echo "$MODEL_DETAILS" | jq -r '"\(.family // "?") · \(.parameter_size // "?") · cuant. \(.quantization_level // "?")"')   ${C_LABEL}capacidades:${C_RESET} $(echo "$CAPABILITIES" | jq -r 'if length==0 then "no declaradas" else join(", ") end')"
  fi
  echo -e "${C_LABEL} Petición:${C_RESET} think=$(think_txt) · options=$REQ_OPTIONS · keep_alive=${KEEP_ALIVE:-(por defecto de Ollama)}"
  echo -e "${C_LABEL}──── Parámetros (del Modelfile, vía /api/show) ────${C_RESET}"
  mostrar_parametros
  echo -e "${C_LABEL}──── System prompt ────${C_RESET}"
  echo "${SYSTEM_PROMPT:-(sin system prompt)}"
  echo -e "${C_LABEL}Contexto (num_ctx):${C_RESET} $(contexto_txt)   ${C_STATS}(fuente: ${NUM_CTX_FUENTE})${C_RESET}"
  echo -e "${C_LABEL}${C_BOLD}══════════════════════════════════════${C_RESET}"
}

# Cabecera COMPACTA al arrancar y en /nueva: lo esencial en pocas líneas.
imprimir_cabecera_sesion() {
  verificar_estado_modelo
  parametros_resumen
  local modelo_info cap sp
  echo
  echo -e "${C_LABEL}${C_BOLD}━━ ${MODELO} ━━${C_RESET} ${C_STATS}sesión ${SESSION_ID} · Ollama ${OLLAMA_VERSION}${C_RESET}"
  if [ "$SHOW_VACIO" = true ]; then
    echo -e " ${ESTADO_INICIAL_TXT}   ${C_ERR}(sin metadatos: /api/show vacío, bug conocido de algunos modelos)${C_RESET}"
  else
    modelo_info="$(echo "$MODEL_DETAILS" | jq -r '[.family // empty, .parameter_size // empty, .quantization_level // empty] | join(" · ")')"
    cap="$(echo "$CAPABILITIES" | jq -r 'if length==0 then "" else join(", ") end')"
    echo -e " ${ESTADO_INICIAL_TXT} · ${modelo_info}${cap:+ · ${cap}}"
  fi
  echo -e " 📦 contexto: $(contexto_txt)"
  local pet="think ${C_BOLD}$(think_txt)${C_RESET}"
  [ "$REQ_OPTIONS" != "{}" ] && pet="${pet} · opciones ${REQ_OPTIONS}"
  [ -n "$KEEP_ALIVE" ] && pet="${pet} · keep_alive ${KEEP_ALIVE}"
  echo -e " ⚙️  ${pet}"
  if [ -n "$PARAMS_DEF" ]; then
    echo -e " 🎛  Modelfile: ${PARAMS_DEF}"
    [ -n "$PARAMS_NODEF" ] && echo -e "    ${C_STATS}sin definir: ${PARAMS_NODEF}${C_RESET}"
  else
    echo -e " 🎛  Modelfile: ${C_STATS}sin parámetros definidos (Ollama usa sus valores por defecto)${C_RESET}"
  fi
  if [ -n "$SYSTEM_PROMPT" ]; then
    sp="$(printf '%s' "$SYSTEM_PROMPT" | tr '\n' ' ')"
    [ "${#sp}" -gt 110 ] && sp="${sp:0:110}…"
    echo -e " 💬 system: ${sp}"
  else
    echo -e " 💬 system: ${C_STATS}sin system prompt${C_RESET}"
  fi
  echo -e " 📝 log: ${C_STATS}${LOG_FILE#"$SCRIPT_DIR"/}${C_RESET}"
  echo -e "${C_STATS} Escribe /ayuda para ver los comandos · /info para el detalle completo${C_RESET}"
  echo
}

mostrar_ayuda() {
  echo -e "${C_LABEL}${C_BOLD}Comandos${C_RESET}"
  echo "  /nueva           sesión limpia (borra el contexto)"
  echo "  /think [modo]    razonamiento on/off (o auto|low|medium|high)"
  echo "  /ver             mostrar u ocultar el razonamiento en pantalla (siempre se guarda en el log)"
  echo "  /stats           detalle completo del último turno"
  echo "  /info            cabecera completa: parámetros, system prompt, fuente del contexto"
  echo "  /ps              estado de memoria y GPU (queda en el log)"
  echo "  /nota <texto>    anota algo en el log"
  echo "  /comparar        el próximo prompt se prueba en frío y en caliente"
  echo "  /descargar       saca el modelo de memoria"
  echo "  /salir           salir (también Ctrl+C o Ctrl+D en el prompt)"
  echo -e "${C_STATS}  Varias líneas: escribe <<<, pega el bloque y termina con >>>${C_RESET}"
  echo -e "${C_STATS}  Ctrl+C mientras responde: cancela ese envío${C_RESET}"
}

# --- Cabecera de sesión en el log: misma info que se imprime en pantalla,
# guardada una vez al principio de cada sesión (inicial o /nueva) para saber
# en qué condiciones exactas se generaron los turnos que vienen después. ---
loguear_cabecera_sesion() {
  # Contadores de la sesión que empieza
  SES_ERRORES=0; SES_CANCELADOS=0; SES_TURNOS_OK=0
  SES_EVAL_TOK=0; SES_PROMPT_TOK=0; SES_EVAL_SEG=0; SES_WALL_SEG=0
  SES_FLAGS_LIST=""
  SES_INICIO_EPOCH="$(date +%s)"
  SES_FIN_LOGUEADO=false

  local F_MF F_TPL
  F_MF="$(mktemp)"; F_TPL="$(mktemp)"
  printf '%s' "$MODELFILE_TXT" > "$F_MF"; printf '%s' "$TEMPLATE_TXT" > "$F_TPL"
  jq -n \
    --arg parameters "$PARAMETERS" \
    --arg system "$SYSTEM_PROMPT" \
    --arg host "$HOST" \
    --argjson num_ctx "$NUM_CTX" \
    --arg num_ctx_source "$NUM_CTX_FUENTE" \
    --arg ollama_version "$OLLAMA_VERSION" \
    --argjson capabilities "$CAPABILITIES" \
    --argjson details "$MODEL_DETAILS" \
    --argjson tag "$MODEL_TAG_INFO" \
    --argjson host_info "$HOST_INFO" \
    --argjson ps "$(ps_snapshot)" \
    --argjson gpu "$(gpu_snapshot)" \
    --argjson ram "$(ram_snapshot)" \
    --argjson request_options "$REQ_OPTIONS" \
    --arg keep_alive "$KEEP_ALIVE" \
    --arg think_mode "$THINK_MODE" \
    --arg max_time "$MAX_TIME" \
    --arg show_vacio "$SHOW_VACIO" \
    --rawfile modelfile "$F_MF" \
    --rawfile template "$F_TPL" \
    '{
      host: $host,
      parameters: $parameters,
      system_prompt: $system,
      num_ctx: $num_ctx,
      num_ctx_source: $num_ctx_source,
      ollama_version: $ollama_version,
      capabilities: $capabilities,
      model_details: $details,
      model_tag: $tag,
      host_info: $host_info,
      request_defaults: {options: $request_options, keep_alive: $keep_alive, think_mode: $think_mode, max_time: $max_time},
      show_vacio: ($show_vacio == "true"),
      ps_at_start: $ps,
      gpu_at_start: $gpu,
      ram_at_start: $ram,
      modelfile: $modelfile,
      template: $template
    }' | log_evento session_start || true
  rm -f "$F_MF" "$F_TPL"
}

# Cierra la sesión en el log con un resumen: turnos, errores, cancelaciones,
# tokens, velocidad media y qué señales de fallo se detectaron y cuántas veces.
# Se llama al hacer /nueva y al salir del script (EXIT), una sola vez por sesión.
loguear_fin_sesion() {
  [ "$SES_FIN_LOGUEADO" = true ] && return 0
  SES_FIN_LOGUEADO=true
  local dur=$(( $(date +%s) - SES_INICIO_EPOCH ))
  jq -n \
    --arg reason "$1" \
    --argjson dur "$dur" \
    --argjson turnos_ok "$SES_TURNOS_OK" \
    --argjson errores "$SES_ERRORES" \
    --argjson cancelados "$SES_CANCELADOS" \
    --argjson prompt_tok "$SES_PROMPT_TOK" \
    --argjson eval_tok "$SES_EVAL_TOK" \
    --arg eval_seg "$SES_EVAL_SEG" \
    --arg wall_seg "$SES_WALL_SEG" \
    --arg flags "$SES_FLAGS_LIST" \
    --argjson ctx "$(echo "$CONTEXT" | jq -c 'length' 2>/dev/null || echo 0)" \
    --argjson num_ctx "$NUM_CTX" \
    '{
      reason: $reason,
      duration_seconds: $dur,
      turns_ok: $turnos_ok,
      errors: $errores,
      cancelled: $cancelados,
      input_tokens_total: $prompt_tok,
      output_tokens_total: $eval_tok,
      eval_seconds_total: ($eval_seg | tonumber),
      wall_seconds_total: ($wall_seg | tonumber),
      tokens_per_second_output_avg: (if ($eval_seg|tonumber) > 0 then ($eval_tok / ($eval_seg|tonumber) * 10 | round / 10) else null end),
      final_context_tokens: $ctx,
      num_ctx: $num_ctx,
      flags_count: ($flags | split(" ") | map(select(length > 0)) | group_by(.) | map({key: .[0], value: length}) | from_entries)
    }' | log_evento session_end || true
}

# Registra un fallo (sin respuesta, error de la API, JSON inválido, cancelación)
# como un evento aparte en el log: los errores NO cuentan como turno, pero quedan
# guardados con todo el contexto necesario para diagnosticarlos.
#   $1 tipo (error|cancelled)  $2 clase corta  $3 mensaje  $4 http  $5 rc de curl
#   $6 stderr de curl  $7 segundos de pared  $8 fichero con la respuesta cruda (opcional)
registrar_fallo() {
  local tipo="$1" clase="$2" mensaje="$3" http="$4" rc="$5" cerr="$6" wall="$7" rawf="${8:-}"
  local pf head_f
  pf="$(mktemp)"; printf '%s' "$MSG" > "$pf"
  head_f="$(mktemp)"; [ -n "$rawf" ] && [ -f "$rawf" ] && head -c 2000 "$rawf" > "$head_f"
  jq -n \
    --arg kind "$clase" --arg message "$mensaje" --arg http "$http" --arg rc "$rc" \
    --arg curl_error "$cerr" --arg wall "$wall" --arg think_mode "$THINK_MODE" \
    --argjson think_sent "$(think_json)" --argjson request_options "$REQ_OPTIONS" \
    --arg keep_alive "$KEEP_ALIVE" --argjson context_before "$(echo "$CONTEXT" | jq 'length')" \
    --argjson num_ctx "$NUM_CTX" --arg model_state "${MODEL_STATE:-}" \
    --argjson ps "$(ps_snapshot)" --argjson gpu "$(gpu_snapshot)" --argjson ram "$(ram_snapshot)" \
    --arg ollama_version "$OLLAMA_VERSION" \
    --rawfile prompt "$pf" --rawfile response_head "$head_f" '
    def clase_msg($m): ($m | ascii_downcase) as $x
      | if ($x | test("does not support thinking|think value|thinking is not")) then "think_no_soportado"
        elif ($x | test("out of memory|cudamalloc|cuda error|failed to allocate|alloc|oom")) then "memoria_insuficiente"
        elif ($x | test("unexpectedly stopped|runner process|terminated|exit status|segmentation|crash|signal")) then "runner_caido"
        elif ($x | test("not found|no such model|try pulling")) then "modelo_no_encontrado"
        elif ($x | test("context|too long|exceed|truncat")) then "contexto"
        elif ($x | test("timeout|timed out|deadline")) then "timeout"
        elif ($x | test("connection|refused|couldn.t connect|resolve")) then "conexion"
        else "otro" end;
    {
      kind: $kind,
      error_class: clase_msg($message + " " + $curl_error),
      message: $message,
      http_code: ($http | tonumber? // null),
      curl_exit_code: ($rc | tonumber? // null),
      curl_error: $curl_error,
      wall_seconds: ($wall | tonumber? // null),
      model_state: $model_state,
      think_mode: $think_mode,
      request: {think: $think_sent, options: $request_options, keep_alive: $keep_alive},
      context_before_tokens: $context_before,
      num_ctx: $num_ctx,
      prompt: $prompt,
      prompt_chars: ($prompt | length),
      response_head: $response_head,
      model_still_loaded: ($ps != null),
      ps_after: $ps, gpu_after: $gpu, ram_after: $ram,
      ollama_version: $ollama_version
    }' | log_evento "$tipo" || true
  rm -f "$pf" "$head_f"
}

# Cuenta tokens REALES de un texto usando el propio tokenizador del modelo:
# se manda como prompt con raw:true (sin plantilla de chat) y num_predict:0
# (no genera nada, solo tokeniza), y se lee prompt_eval_count de la respuesta.
# Es una llamada barata y rápida a Ollama — evita tener que ADIVINAR el
# reparto de tokens entre pensamiento/respuesta a partir de una proporción de
# caracteres; en su lugar se mide con el modelo real en ese mismo momento.
contar_tokens_real() {
  local texto="$1"
  if [ -z "$texto" ]; then
    echo 0
    return
  fi
  local body bodyfile resp n
  body="$(jq -n --arg model "$MODELO" --arg prompt "$texto" '
    {model:$model, prompt:$prompt, raw:true, stream:false, options:{num_predict:0}}
  ')"
  # Mismo motivo que en procesar_envio: si el texto es largo, pasarlo como
  # argumento literal de curl puede reventar el límite del kernel por
  # argumento (128KB). Con @fichero no hay ese límite.
  bodyfile="$(mktemp)"
  printf '%s' "$body" > "$bodyfile"
  resp="$(curl -s --max-time 30 "$HOST/api/generate" -d @"$bodyfile" 2>/dev/null || echo '{}')"
  rm -f "$bodyfile"
  n="$(echo "$resp" | jq '.prompt_eval_count // 0' 2>/dev/null)"
  echo "${n:-0}"
}

# Envía $MSG usando /api/generate + el blob $CONTEXT que ya te devolvió Ollama
# la vez anterior (si lo hay). $1 (ETIQUETA) es "" para un turno normal, o
# "cold"/"warm" cuando forma parte de una comparativa /comparar. Si ETIQUETA
# no es "cold", al terminar con éxito actualiza $CONTEXT con el nuevo blob que
# devuelve Ollama — esa longitud (CTX_REAL) es el tamaño de contexto REAL,
# reportado por la propia Ollama, no una suma calculada por este script.
# Devuelve 1 si hubo error de la API (y no toca $CONTEXT). Los errores y las
# cancelaciones NO cuentan como turno, pero se guardan en el log (type error/cancelled).
procesar_envio() {
  local ETIQUETA="$1"
  local ETIQUETA_TXT=""
  case "$ETIQUETA" in
    cold) ETIQUETA_TXT=" (🧊 pasada 1/2, en frío)" ;;
    warm) ETIQUETA_TXT=" (🔥 pasada 2/2, en caliente)" ;;
  esac

  # Estado real ANTES de enviar: se pregunta a /api/ps en este mismo instante
  # si el modelo está cargado o no (dato real de Ollama), en vez de inferirlo
  # después mirando cuánto duró la carga (un umbral arbitrario podía fallar).
  verificar_estado_modelo
  if [ "$ESTADO_INICIAL" = "loaded" ]; then
    MODEL_STATE="warm"
    MODEL_STATE_TXT="🔥 modelo ya en memoria"
  else
    MODEL_STATE="cold"
    MODEL_STATE_TXT="🧊 modelo cargado ahora"
  fi

  # Estado del sistema justo antes de enviar (para comparar con el de después)
  local PS_BEFORE GPU_BEFORE CONTEXT_BEFORE
  PS_BEFORE="$(ps_snapshot)"
  GPU_BEFORE="$(gpu_snapshot)"
  CONTEXT_BEFORE="$(echo "$CONTEXT" | jq 'length')"

  # Aviso previo: si el historial + el mensaje ya no caben en la ventana real,
  # Ollama recortará el INICIO de la conversación sin dar error.
  if [ "$ESTADO_INICIAL" = "loaded" ] && [ "$CONTEXT_BEFORE" -ge "$NUM_CTX" ]; then
    echo -e "${C_ERR}⚠ el historial (${CONTEXT_BEFORE} tok) ya llena la ventana (${NUM_CTX}): Ollama descartará el principio de la conversación. Usa /nueva para una prueba limpia.${C_RESET}"
  fi

  [ -n "$ETIQUETA_TXT" ] && echo -e "${C_STATS}${ETIQUETA_TXT# }${C_RESET}"

  local THINK_SENT
  THINK_SENT="$(think_json)"
  local REQ_BODY
  REQ_BODY="$(jq -n --arg model "$MODELO" --arg prompt "$MSG" --argjson context "$CONTEXT" \
      --argjson think "$THINK_SENT" --argjson options "$REQ_OPTIONS" --arg keep "$KEEP_ALIVE" '
    {model:$model, prompt:$prompt, stream:false}
    + (if ($context|length) > 0 then {context:$context} else {} end)
    + (if $think != null then {think:$think} else {} end)
    + (if ($options|length) > 0 then {options:$options} else {} end)
    + (if $keep != "" then {keep_alive:$keep} else {} end)
  ')"

  # curl en segundo plano + "latido" cada 5s. Con stream:false no se ve NADA
  # hasta que termina toda la generación, así que sin esto un turno largo
  # (razonamiento largo, respuesta estructurada, offload a CPU) se siente como
  # colgado aunque esté trabajando. Si CHAT_MAX_TIME está definido, actúa como
  # red de seguridad (corta a los N segundos); si no, espera sin límite.
  local CURL_ARGS=(-sS)
  if [ -n "$MAX_TIME" ]; then
    CURL_ARGS+=(--max-time "$MAX_TIME")
  fi

  # El body se manda desde un fichero (-d @fichero), NUNCA como argumento
  # literal de curl. Con contexto largo (miles de tokens en el array
  # "context") el JSON puede superar fácilmente los 128KB, y el kernel de
  # Linux limita a eso el tamaño de UN SOLO argumento de línea de comandos
  # (MAX_ARG_STRLEN) — pasado ese tamaño, curl falla con "Argument list too
  # long" aunque el propio curl no tenga ningún límite así. Con @fichero no
  # hay límite práctico, porque el contenido no pasa por argv.
  local REQ_FILE TMP_RESP TMP_META TMP_CERR
  REQ_FILE="$(mktemp)"; TMP_RESP="$(mktemp)"; TMP_META="$(mktemp)"; TMP_CERR="$(mktemp)"
  printf '%s' "$REQ_BODY" > "$REQ_FILE"

  local T0 T1 WALL_S
  T0="$(date +%s.%N)"
  # -w deja en TMP_META: código HTTP, tiempo de conexión, tiempo total y bytes recibidos
  curl "${CURL_ARGS[@]}" -o "$TMP_RESP" -w '%{http_code} %{time_connect} %{time_total} %{size_download}' \
    "$HOST/api/generate" -d @"$REQ_FILE" > "$TMP_META" 2> "$TMP_CERR" &
  local CURL_PID=$!
  local ESPERA=0
  local CANCELADO=false

  # Mientras se espera la respuesta (y SOLO mientras tanto), Ctrl+C no cierra
  # el script entero: marca CANCELADO=true para poder matar el curl en curso,
  # descartar la respuesta y volver al prompt sin contar el turno.
  # Fuera de esta ventana (p.ej. en el prompt de entrada) Ctrl+C sigue
  # comportándose como antes (sale del script).
  trap 'CANCELADO=true' INT

  local TTY_OK=false; [ -t 1 ] && TTY_OK=true
  while kill -0 "$CURL_PID" 2>/dev/null; do
    sleep 1
    ESPERA=$((ESPERA + 1))
    if [ "$CANCELADO" = true ]; then
      break
    fi
    if [ "$TTY_OK" = true ]; then
      printf '\r\033[K%b' "${C_STATS}⏳ generando… ${ESPERA}s  (Ctrl+C para cancelar)${C_RESET}"
    elif [ $((ESPERA % 15)) -eq 0 ]; then
      echo "… ${ESPERA}s esperando a ${MODELO}"
    fi
  done
  [ "$TTY_OK" = true ] && printf '\r\033[K'

  trap - INT

  if [ "$CANCELADO" = true ]; then
    kill "$CURL_PID" 2>/dev/null || true
    wait "$CURL_PID" 2>/dev/null || true
    T1="$(date +%s.%N)"
    WALL_S="$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')"
    SES_CANCELADOS=$((SES_CANCELADOS + 1))
    registrar_fallo cancelled cancelado_por_usuario "Envío cancelado con Ctrl+C tras ${WALL_S}s" "" "" "" "$WALL_S"
    rm -f "$TMP_RESP" "$REQ_FILE" "$TMP_META" "$TMP_CERR"
    echo
    echo -e "${C_ERR}${C_BOLD}✖ CANCELADO${C_RESET} ${C_ERR}Envío interrumpido a mano. No cuenta como turno; queda registrado en el log como 'cancelled'.${C_RESET}"
    echo
    return 1
  fi

  local CURL_RC=0
  wait "$CURL_PID" 2>/dev/null || CURL_RC=$?
  T1="$(date +%s.%N)"
  WALL_S="$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')"

  local HTTP_CODE CONNECT_S CURL_TIME_S CURL_ERR_TXT
  read -r HTTP_CODE CONNECT_S CURL_TIME_S _ < "$TMP_META" || true
  HTTP_CODE="${HTTP_CODE:-0}"; CONNECT_S="${CONNECT_S:-0}"
  CURL_ERR_TXT="$(cat "$TMP_CERR")"
  RESPONSE="$(cat "$TMP_RESP")"
  rm -f "$REQ_FILE" "$TMP_META" "$TMP_CERR"

  if [ "$CURL_RC" -ne 0 ] || [ -z "$RESPONSE" ]; then
    local MSG_ERR="Sin respuesta tras ${WALL_S}s (curl rc=${CURL_RC}, HTTP ${HTTP_CODE}). ${CURL_ERR_TXT}"
    registrar_fallo error sin_respuesta "$MSG_ERR" "$HTTP_CODE" "$CURL_RC" "$CURL_ERR_TXT" "$WALL_S" "$TMP_RESP"
    SES_ERRORES=$((SES_ERRORES + 1))
    rm -f "$TMP_RESP"
    echo -e "${C_ERR}${C_BOLD}✖ ERROR${C_RESET} ${C_ERR}${MSG_ERR} Comprueba 'ollama ps' y los logs del servicio (¿se cayó el runner o se agotó la memoria?).${C_RESET}"
    echo
    return 1
  fi

  if ! echo "$RESPONSE" | jq -e . >/dev/null 2>&1; then
    registrar_fallo error json_invalido "La respuesta de Ollama no es JSON válido (${#RESPONSE} bytes, HTTP ${HTTP_CODE})" "$HTTP_CODE" "$CURL_RC" "$CURL_ERR_TXT" "$WALL_S" "$TMP_RESP"
    SES_ERRORES=$((SES_ERRORES + 1))
    rm -f "$TMP_RESP"
    echo -e "${C_ERR}${C_BOLD}✖ ERROR${C_RESET} ${C_ERR}Respuesta no válida de Ollama (${#RESPONSE} bytes, HTTP ${HTTP_CODE}). Guardada en el log como 'json_invalido'.${C_RESET}"
    echo
    return 1
  fi

  REPLY="$(echo "$RESPONSE" | jq -r '.response // ""')"
  ERROR="$(echo "$RESPONSE" | jq -r '.error // ""')"

  if [ -n "$ERROR" ]; then
    registrar_fallo error error_api "$ERROR" "$HTTP_CODE" "$CURL_RC" "$CURL_ERR_TXT" "$WALL_S" "$TMP_RESP"
    SES_ERRORES=$((SES_ERRORES + 1))
    rm -f "$TMP_RESP"
    echo -e "${C_ERR}${C_BOLD}✖ ERROR${C_RESET} ${C_ERR}$ERROR${C_RESET}"
    case "$ERROR" in
      *think*) echo -e "${C_ERR}  Pista: este modelo no admite el campo 'think'. Usa /think auto.${C_RESET}" ;;
    esac
    echo
    return 1
  fi
  if [ "$HTTP_CODE" != "200" ]; then
    registrar_fallo error http_no_200 "HTTP ${HTTP_CODE} sin campo error" "$HTTP_CODE" "$CURL_RC" "$CURL_ERR_TXT" "$WALL_S" "$TMP_RESP"
    SES_ERRORES=$((SES_ERRORES + 1))
    rm -f "$TMP_RESP"
    echo -e "${C_ERR}${C_BOLD}✖ ERROR${C_RESET} ${C_ERR}HTTP ${HTTP_CODE} inesperado.${C_RESET}"
    echo
    return 1
  fi

  # --- Separar el razonamiento ("pensamiento") de la respuesta final ---
  # Caso 1: Ollama ya lo separa de forma nativa en .thinking (modelos con
  #         soporte de "thinking").
  # Caso 2: viene inline como <think>...</think> dentro de .response
  #         (comportamiento por defecto de deepseek-r1 / logic-r1).
  THINKING="$(echo "$RESPONSE" | jq -r '.thinking // ""')"
  FINAL_CONTENT="$REPLY"
  if [ -z "$THINKING" ]; then
    THINKING="$(printf '%s' "$REPLY" | sed -z -n 's/.*<think>\(.*\)<\/think>.*/\1/p')"
    THINKING="$(printf '%s' "$THINKING" | sed -e '1{/^$/d}')"
    if [ -n "$THINKING" ]; then
      FINAL_CONTENT="$(printf '%s' "$REPLY" | sed -z 's/<think>.*<\/think>//' | sed -z 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    fi
  fi

  if [ -n "$THINKING" ] && [ "$MOSTRAR_RAZONAMIENTO" = true ]; then
    echo -e "${C_STATS}${C_BOLD}🧠 razonamiento${C_RESET}"
    echo -e "${C_STATS}${THINKING}${C_RESET}"
    echo -e "${C_STATS}────────────────────────────────────${C_RESET}"
  elif [ -n "$THINKING" ]; then
    echo -e "${C_STATS}🧠 (razonamiento oculto; /ver para mostrarlo)${C_RESET}"
  fi

  echo -e "${C_MODEL}${C_BOLD}╭─ ${MODELO} · turno ${TURN}${C_RESET}"
  if [ -n "$FINAL_CONTENT" ]; then
    echo "$FINAL_CONTENT"
  else
    echo -e "${C_ERR}(respuesta final vacía)${C_RESET}"
  fi

  # --- Estadísticas: todo lo de abajo son campos que devuelve Ollama tal
  # cual (solo se convierten de nanosegundos a segundos y se calculan
  # divisiones simples tok/s; no hay sumas acumulativas propias). ---
  TOTAL_S="$(echo "$RESPONSE" | jq '(.total_duration // 0)/1e9')"
  LOAD_S="$(echo "$RESPONSE" | jq '(.load_duration // 0)/1e9')"
  PROMPT_COUNT="$(echo "$RESPONSE" | jq '.prompt_eval_count // 0')"
  PROMPT_DUR_S="$(echo "$RESPONSE" | jq '(.prompt_eval_duration // 0)/1e9')"
  EVAL_COUNT="$(echo "$RESPONSE" | jq '.eval_count // 0')"
  EVAL_DUR_S="$(echo "$RESPONSE" | jq '(.eval_duration // 0)/1e9')"
  DONE_REASON="$(echo "$RESPONSE" | jq -r '.done_reason // "desconocido"')"

  # Contexto REAL: longitud del array .context que devuelve Ollama tras esta
  # llamada. Este número lo calcula y lo da la propia Ollama — no es una suma
  # que llevemos nosotros. La pasada "cold" de /comparar es una prueba
  # aislada: se muestra su resultado pero NO se guarda como contexto oficial
  # de la sesión (se descarta, no debe continuar la conversación real).
  CTX_REAL="$(echo "$RESPONSE" | jq '(.context // []) | length')"

  # Ya cargado tras esta respuesta: leer el num_ctx real de /api/ps (si el turno
  # fue en frío, hasta ahora NUM_CTX era solo el máximo del modelo).
  verificar_estado_modelo

  # El array .context es el historial que acumula EL CLIENTE: puede ser más largo
  # que la ventana real del modelo (Ollama recorta el inicio al evaluar, sin dar
  # error). Con el num_ctx real de /api/ps NO se "corrige" el techo: se avisa de
  # cuántos tokens quedan fuera de la ventana. Solo si el num_ctx viene de una
  # detección dudosa (no de /api/ps) se ajusta, como antes.
  CTX_FUERA_VENTANA=0
  if [ "$CTX_REAL" -gt "$NUM_CTX" ]; then
    case "$NUM_CTX_FUENTE" in
      "api/ps"*)
        CTX_FUERA_VENTANA=$((CTX_REAL - NUM_CTX)) ;;
      *)
        echo -e "${C_ERR}⚠ num_ctx detectado (${NUM_CTX} · ${NUM_CTX_FUENTE}) era incorrecto: Ollama ya ha usado ${CTX_REAL} tokens de contexto real. Corrigiendo NUM_CTX a ${CTX_REAL} para los cálculos de % desde ahora (si conoces el num_ctx real, relanza con CHAT_NUM_CTX=<valor> ./chat.sh ${MODELO}).${C_RESET}"
        NUM_CTX="$CTX_REAL"
        NUM_CTX_FUENTE="corregido en caliente (la detección inicial falló; valor real reportado por Ollama)" ;;
    esac
  fi

  CTX_REAL_PCT="$(awk -v u="$CTX_REAL" -v n="$NUM_CTX" 'BEGIN{ if (n>0) printf "%.1f", (u/n)*100; else print "0.0" }')"
  if [ "$ETIQUETA" != "cold" ]; then
    CONTEXT="$(echo "$RESPONSE" | jq -c '.context // []')"
    CONTEXT_LEN="$CTX_REAL"
  fi

  TOK_S="$(awk -v c="$EVAL_COUNT" -v d="$EVAL_DUR_S" 'BEGIN{ if (d>0) printf "%.1f", c/d; else print "0.0" }')"
  PROMPT_TOK_S="$(awk -v c="$PROMPT_COUNT" -v d="$PROMPT_DUR_S" 'BEGIN{ if (d>0) printf "%.1f", c/d; else print "0.0" }')"
  TOTAL_TOKENS=$((PROMPT_COUNT + EVAL_COUNT))

  # Lo de aquí abajo (palabras, caracteres, reparto pensamiento/respuesta) NO
  # existe como dato en la API de Ollama — un LLM no reporta "palabras", así
  # que esto se queda calculado localmente por el script.
  WORD_COUNT_FINAL="$(printf '%s' "$FINAL_CONTENT" | wc -w | tr -d ' ')"
  WORD_COUNT_THINKING="$(printf '%s' "$THINKING" | wc -w | tr -d ' ')"
  WORD_COUNT_TOTAL=$((WORD_COUNT_FINAL + WORD_COUNT_THINKING))
  CHAR_COUNT="$(printf '%s' "$REPLY" | wc -m | tr -d ' ')"
  CHARS_POR_TOKEN="$(awk -v ch="$CHAR_COUNT" -v t="$EVAL_COUNT" 'BEGIN{ if (t>0) printf "%.2f", ch/t; else print "0.00" }')"

  # Reparto pensamiento/respuesta: medido con el tokenizador REAL del modelo
  # (una llamada aparte a Ollama por cada trozo, ver contar_tokens_real), no
  # una proporción calculada a partir de caracteres. Puede diferir en 1-2
  # tokens del eval_count total por efectos de frontera del tokenizador al
  # tokenizar cada trozo por separado; el total real y fiable sigue siendo
  # eval_count (mostrado aparte, sin tocar).
  # OJO: esas llamadas de tokenización ocupan el "slot" de Ollama con otro texto,
  # así que el turno siguiente puede tener que re-evaluar el historial (más
  # prompt_eval, no achacable al modelo). CHAT_CONTAR_TOKENS=0 las evita y estima
  # el reparto por proporción de caracteres (se anota el método en el log).
  TOKENS_METODO="tokenizador_real"
  if [ -n "$THINKING" ]; then
    if [ "${CHAT_CONTAR_TOKENS:-1}" = "1" ]; then
      THINKING_TOKENS_EST="$(contar_tokens_real "$THINKING")"
      ANSWER_TOKENS_EST="$(contar_tokens_real "$FINAL_CONTENT")"
    else
      TOKENS_METODO="proporcion_caracteres"
      THINKING_TOKENS_EST="$(awk -v e="$EVAL_COUNT" -v t="${#THINKING}" -v f="${#FINAL_CONTENT}" 'BEGIN{ if (t+f>0) printf "%d", e*t/(t+f); else print 0 }')"
      ANSWER_TOKENS_EST=$((EVAL_COUNT - THINKING_TOKENS_EST))
    fi
  else
    THINKING_TOKENS_EST=0
    ANSWER_TOKENS_EST=$EVAL_COUNT
  fi

  # Estado de memoria/GPU justo después de responder
  local PS_AFTER GPU_AFTER RAM_AFTER
  PS_AFTER="$(ps_snapshot)"
  GPU_AFTER="$(gpu_snapshot)"
  RAM_AFTER="$(ram_snapshot)"

  # Ficheros temporales para el log (prompt/respuestas por --rawfile, no por argv)
  local F_PROMPT F_REPLY F_FINAL F_THINK
  F_PROMPT="$(mktemp)"; F_REPLY="$(mktemp)"; F_FINAL="$(mktemp)"; F_THINK="$(mktemp)"
  printf '%s' "$MSG" > "$F_PROMPT"; printf '%s' "$REPLY" > "$F_REPLY"
  printf '%s' "$FINAL_CONTENT" > "$F_FINAL"; printf '%s' "$THINKING" > "$F_THINK"
  local PROMPT_SHA PROMPT_LINES PASTED
  PROMPT_SHA="$(printf '%s' "$MSG" | sha256_txt)"
  PROMPT_LINES="$(printf '%s\n' "$MSG" | wc -l | tr -d ' ')"
  PASTED=false; [ "$PROMPT_LINES" -gt 1 ] && PASTED=true

  # --- Log completo (una línea JSON por turno, autocontenida) ---
  # Los campos históricos no cambian (los lee html/reporte.py); lo nuevo se AÑADE.
  jq -nc \
    --arg type "turn" \
    --arg session "$SESSION_ID" \
    --arg model "$MODELO" \
    --argjson turn "$TURN" \
    --argjson schema "$LOG_SCHEMA" \
    --arg bench_pass "$ETIQUETA" \
    --arg ts "$(ts_now)" \
    --rawfile prompt "$F_PROMPT" \
    --rawfile response "$F_REPLY" \
    --rawfile final_answer "$F_FINAL" \
    --rawfile thinking "$F_THINK" \
    --arg has_thinking "$([ -n "$THINKING" ] && echo true || echo false)" \
    --arg think_mode "$THINK_MODE" \
    --argjson think_sent "$THINK_SENT" \
    --argjson request_options "$REQ_OPTIONS" \
    --arg keep_alive "$KEEP_ALIVE" \
    --arg model_state "$MODEL_STATE" \
    --arg load_s "$LOAD_S" \
    --argjson ollama_context_tokens "$CTX_REAL" \
    --argjson context_before "$CONTEXT_BEFORE" \
    --argjson context_outside_window "$CTX_FUERA_VENTANA" \
    --arg ollama_context_pct "$CTX_REAL_PCT" \
    --arg parameters "$PARAMETERS" \
    --arg system "$SYSTEM_PROMPT" \
    --argjson num_ctx "$NUM_CTX" \
    --arg num_ctx_source "$NUM_CTX_FUENTE" \
    --arg tok_s "$TOK_S" \
    --arg prompt_tok_s "$PROMPT_TOK_S" \
    --argjson word_count_final "$WORD_COUNT_FINAL" \
    --argjson word_count_thinking "$WORD_COUNT_THINKING" \
    --argjson word_count_total "$WORD_COUNT_TOTAL" \
    --argjson char_count "$CHAR_COUNT" \
    --arg chars_per_token "$CHARS_POR_TOKEN" \
    --argjson input_tokens "$PROMPT_COUNT" \
    --argjson output_tokens "$EVAL_COUNT" \
    --argjson thinking_tokens_est "$THINKING_TOKENS_EST" \
    --argjson answer_tokens_est "$ANSWER_TOKENS_EST" \
    --arg tokens_method "$TOKENS_METODO" \
    --argjson total_tokens "$TOTAL_TOKENS" \
    --arg done_reason "$DONE_REASON" \
    --arg wall "$WALL_S" \
    --arg http_code "$HTTP_CODE" \
    --arg connect_s "$CONNECT_S" \
    --arg prompt_sha "$PROMPT_SHA" \
    --argjson prompt_lines "$PROMPT_LINES" \
    --argjson pasted "$PASTED" \
    --argjson ps_before "$PS_BEFORE" --argjson ps_after "$PS_AFTER" \
    --argjson gpu_before "$GPU_BEFORE" --argjson gpu_after "$GPU_AFTER" \
    --argjson ram_after "$RAM_AFTER" \
    --arg ollama_version "$OLLAMA_VERSION" \
    --slurpfile raw "$TMP_RESP" \
    '
    ($raw[0]) as $r
    | ($final_answer + " " + $thinking | [scan("\\S+")]) as $w
    | (if ($w | length) >= 60
       then ([range(0; ($w | length) - 3) as $i | $w[$i:$i+4] | join(" ")] | ((unique | length) / length))
       else null end) as $uniq4
    | ("[Ѐ-ӿ一-鿿぀-ヿ가-힯؀-ۿ]") as $ajeno
    | ([($final_answer + $thinking) | scan($ajeno)] | length) as $foreign
    | ($prompt | test($ajeno)) as $prompt_foreign
    | ($ollama_context_pct | tonumber) as $pct
    | ($has_thinking == "true") as $ht
    | ($think_mode | IN("on","low","medium","high")) as $think_pedido
    | [
        (if ($final_answer | test("^\\s*$")) and ($output_tokens > 0) then "respuesta_final_vacia" else empty end),
        (if $done_reason == "length" then "cortada_por_length" else empty end),
        (if ($r.done // false) != true then "respuesta_incompleta_sin_done" else empty end),
        (if $context_outside_window > 0 then "historial_fuera_de_ventana"
         elif $pct >= 80 then "contexto_casi_lleno" else empty end),
        (if $uniq4 != null and $uniq4 < 0.5 then "posible_bucle_repeticion" else empty end),
        (if $foreign > 0 and ($prompt_foreign | not) then "caracteres_de_otro_alfabeto" else empty end),
        (if $think_mode == "off" and $ht then "think_off_ignorado" else empty end),
        (if $think_pedido and ($ht | not) then "think_on_sin_razonamiento" else empty end),
        (if ($response | test("<think>")) and (($response | test("</think>")) | not) then "think_sin_cerrar" else empty end),
        (if $model_state == "cold" and (($load_s | tonumber) > 10) then "carga_en_frio_lenta" else empty end),
        (if $ps_after != null and $ps_after.vram_pct != null and $ps_after.vram_pct < 99.5 then "offload_parcial_a_cpu" else empty end)
      ] as $flags
    | {
      type: $type,
      session: $session,
      model: $model,
      turn: $turn,
      schema: $schema,
      bench_pass: $bench_pass,
      timestamp: $ts,
      prompt: $prompt,
      response: $response,
      final_answer: $final_answer,
      thinking: $thinking,
      has_thinking: $ht,
      think_mode: $think_mode,
      model_state: $model_state,
      load_seconds: ($load_s | tonumber),
      ollama_context_tokens: $ollama_context_tokens,
      ollama_context_pct: $pct,
      parameters: $parameters,
      system_prompt: $system,
      num_ctx: $num_ctx,
      num_ctx_source: $num_ctx_source,
      input_tokens: $input_tokens,
      output_tokens: $output_tokens,
      output_tokens_breakdown: {
        thinking_est: $thinking_tokens_est,
        answer_est: $answer_tokens_est,
        method: $tokens_method
      },
      total_tokens: $total_tokens,
      tokens_per_second_output: ($tok_s | tonumber),
      tokens_per_second_input: ($prompt_tok_s | tonumber),
      word_count_breakdown: {
        final_answer: ($final_answer | [scan("\\S+")] | length),
        thinking: ($thinking | [scan("\\S+")] | length),
        total: ($w | length)
      },
      char_count: $char_count,
      chars_per_token: ($chars_per_token | tonumber),
      done_reason: $done_reason,
      raw_stats: {
        total_duration: $r.total_duration,
        load_duration: $r.load_duration,
        prompt_eval_count: $r.prompt_eval_count,
        prompt_eval_duration: $r.prompt_eval_duration,
        eval_count: $r.eval_count,
        eval_duration: $r.eval_duration,
        done_reason: $r.done_reason,
        done: $r.done,
        created_at: $r.created_at,
        context_length: $ollama_context_tokens
      },
      request: {think: $think_sent, options: $request_options, keep_alive: $keep_alive},
      timing: {
        wall_seconds: ($wall | tonumber),
        http_code: ($http_code | tonumber),
        connect_seconds: ($connect_s | tonumber),
        client_overhead_seconds: ((($wall | tonumber) - (($r.total_duration // 0) / 1e9)) * 1000 | round / 1000)
      },
      context: {
        before_tokens: $context_before,
        after_tokens: $ollama_context_tokens,
        num_ctx: $num_ctx,
        outside_window_tokens: $context_outside_window
      },
      prompt_stats: {
        chars: ($prompt | length),
        lines: $prompt_lines,
        words: ($prompt | [scan("\\S+")] | length),
        sha256: $prompt_sha,
        pasted: $pasted
      },
      final_answer_lines: ($final_answer | if . == "" then 0 else split("\n") | length end),
      thinking_share_tokens: (if $output_tokens > 0 then ($thinking_tokens_est / $output_tokens * 1000 | round / 1000) else null end),
      degeneration: {uniq_4gram_ratio: ($uniq4 | if . == null then null else (. * 1000 | round / 1000) end), foreign_script_chars: $foreign},
      memory: {ps_before: $ps_before, ps_after: $ps_after, gpu_before: $gpu_before, gpu_after: $gpu_after, ram_after: $ram_after},
      ollama_version: $ollama_version,
      flags: $flags
    }' >> "$LOG_FILE" || {
      # Si jq falla al armar la fila, se deja constancia mínima en vez de perder el turno
      jq -nc --arg m "fallo al construir la fila del log" '{message:$m}' | log_evento log_error || true
      echo -e "${C_ERR}⚠ No se pudo escribir la fila completa del turno en el log (registrado como 'log_error').${C_RESET}"
    }

  # Señales de fallo de este turno (leídas de la fila que acabamos de escribir)
  local FLAGS_TXT
  FLAGS_TXT="$(tail -n 1 "$LOG_FILE" | jq -r 'select(.type=="turn") | (.flags // []) | join(", ")' 2>/dev/null || true)"

  # Acumular contadores de la sesión
  SES_TURNOS_OK=$((SES_TURNOS_OK + 1))
  SES_EVAL_TOK=$((SES_EVAL_TOK + EVAL_COUNT))
  SES_PROMPT_TOK=$((SES_PROMPT_TOK + PROMPT_COUNT))
  SES_EVAL_SEG="$(awk -v a="$SES_EVAL_SEG" -v b="$EVAL_DUR_S" 'BEGIN{printf "%.3f", a+b}')"
  SES_WALL_SEG="$(awk -v a="$SES_WALL_SEG" -v b="$WALL_S" 'BEGIN{printf "%.3f", a+b}')"
  [ -n "$FLAGS_TXT" ] && SES_FLAGS_LIST="$SES_FLAGS_LIST $(echo "$FLAGS_TXT" | tr -d ',')"

  rm -f "$TMP_RESP" "$F_PROMPT" "$F_REPLY" "$F_FINAL" "$F_THINK"

  # Detalle completo (solo con /stats)
  LAST_STATS="$(
    echo "⏱  ${TOTAL_S}s total (carga ${LOAD_S}s · ${MODEL_STATE_TXT})   🚀 ${TOK_S} tok/s salida   📥 ${PROMPT_TOK_S} tok/s entrada"
    [ -n "$THINKING" ] && echo "🧠 pensamiento: ${THINKING_TOKENS_EST} tok · 💬 respuesta final: ${ANSWER_TOKENS_EST} tok (${TOKENS_METODO})"
    echo "📥 tokens nuevos evaluados (entrada): ${PROMPT_COUNT}   📤 tokens generados (salida): ${EVAL_COUNT} (${CHARS_POR_TOKEN} car/tok)"
    echo "📝 palabras: respuesta ${WORD_COUNT_FINAL} · total ${WORD_COUNT_TOTAL}"
    echo "📦 contexto: ${CTX_REAL}/${NUM_CTX} (${CTX_REAL_PCT}%) · turno ${TURN}"
    [ -n "$FLAGS_TXT" ] && echo "⚑ señales: ${FLAGS_TXT}"
    true
  )"

  # Pie de una línea
  local ctx_txt estado_txt pens_txt
  ctx_txt="📦 $(fmt_tok "$CTX_REAL")/$(fmt_tok "$NUM_CTX") (${CTX_REAL_PCT%.*}%)"
  [ "$ETIQUETA" = "cold" ] && ctx_txt="${ctx_txt} descartado"
  if [ "$MODEL_STATE" = "cold" ]; then estado_txt="🧊 frío (carga $(awk -v t="$LOAD_S" 'BEGIN{printf "%.1f", t}')s)"; else estado_txt="🔥 caliente"; fi
  pens_txt=""; [ -n "$THINKING" ] && pens_txt=" (🧠 ${THINKING_TOKENS_EST})"
  echo -e "${C_MODEL}${C_BOLD}╰─${C_RESET}${C_STATS} ⏱ $(awk -v t="$TOTAL_S" 'BEGIN{printf "%.1f", t}')s · 🚀 ${TOK_S} tok/s · 📤 ${EVAL_COUNT} tok${pens_txt} · ${ctx_txt} · ${estado_txt}${ETIQUETA_TXT}${C_RESET}"

  # Avisos (solo si hay algo que avisar)
  if [ "$ETIQUETA" != "cold" ]; then
    if [ "$CTX_FUERA_VENTANA" -gt 0 ]; then
      echo -e "${C_ERR}⚠ el historial (${CTX_REAL} tok) supera la ventana real (${NUM_CTX}): el modelo ya NO ve ~${CTX_FUERA_VENTANA} tokens del principio (Ollama los descarta sin avisar). Usa /nueva.${C_RESET}"
    elif awk -v p="$CTX_REAL_PCT" 'BEGIN{exit !(p>=80)}'; then
      echo -e "${C_ERR}⚠ contexto al ${CTX_REAL_PCT}% — cerca del límite. Usa /nueva para reiniciar.${C_RESET}"
    fi
  fi
  if [ "$DONE_REASON" != "stop" ]; then
    echo -e "${C_ERR}⚠ respuesta cortada (${DONE_REASON})${C_RESET}"
  fi
  if [ -n "$FLAGS_TXT" ]; then
    echo -e "${C_ERR}⚑ ${FLAGS_TXT}${C_STATS}  (guardado en el log; /stats para más)${C_RESET}"
  fi
  echo

  return 0
}

imprimir_cabecera_sesion
loguear_cabecera_sesion

while true; do
  # Vacía cualquier tecla que haya quedado en el buffer del terminal (p.ej. si el
  # usuario reescribió/reenvió mientras el modelo aún respondía). Evita reenvíos fantasma.
  while read -r -t 0.01 -n 1000 _stale; do :; done 2>/dev/null || true

  # Barra de estado: turno, think y ocupación del contexto (en rojo desde el 80 %)
  PCT_CTX="$(awk -v u="$CONTEXT_LEN" -v n="$NUM_CTX" 'BEGIN{ if (n>0) printf "%d", u*100/n; else print 0 }')"
  BARRA_CTX="📦 $(fmt_tok "$CONTEXT_LEN")/$(fmt_tok "$NUM_CTX") (${PCT_CTX}%)"
  [ "$PCT_CTX" -ge 80 ] && BARRA_CTX="${C_ERR}${BARRA_CTX}${C_USER}"
  echo -e "${C_USER}${C_BOLD}┌─ turno $((TURN + 1)) · 🧠 $(think_txt) · ${BARRA_CTX}${C_RESET}"
  PROMPT_TXT="$(echo -e "${RL_S}${C_USER}${C_BOLD}${RL_E}└❯ ${RL_S}${C_RESET}${RL_E}")"
  read -e -r -p "$PROMPT_TXT" FIRST_LINE
  [ -z "$FIRST_LINE" ] && continue

  if [ "$FIRST_LINE" = "/nueva" ]; then
    # Nueva sesión de prueba independiente, sin salir del script: se vacía el
    # blob de contexto real de Ollama (el modelo "olvida" lo anterior) y se
    # abre un nuevo bloque de sesión en el log para no mezclar resultados.
    loguear_fin_sesion "nueva"
    SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)"
    TURN=0
    CONTEXT='[]'
    CONTEXT_LEN=0
    imprimir_cabecera_sesion
    loguear_cabecera_sesion
    continue
  fi

  if [ "$FIRST_LINE" = "/ayuda" ] || [ "$FIRST_LINE" = "/help" ] || [ "$FIRST_LINE" = "/?" ]; then
    mostrar_ayuda
    continue
  fi

  if [ "$FIRST_LINE" = "/info" ]; then
    imprimir_info_completa
    continue
  fi

  if [ "$FIRST_LINE" = "/stats" ]; then
    if [ -n "$LAST_STATS" ]; then echo -e "${C_STATS}${LAST_STATS}${C_RESET}"; else echo "Aún no hay ningún turno en esta sesión."; fi
    continue
  fi

  if [ "$FIRST_LINE" = "/ver" ]; then
    if [ "$MOSTRAR_RAZONAMIENTO" = true ]; then MOSTRAR_RAZONAMIENTO=false; else MOSTRAR_RAZONAMIENTO=true; fi
    echo -e "${C_STATS}Razonamiento en pantalla: $([ "$MOSTRAR_RAZONAMIENTO" = true ] && echo visible || echo oculto) (el log lo guarda siempre).${C_RESET}"
    continue
  fi

  if [ "$FIRST_LINE" = "/salir" ] || [ "$FIRST_LINE" = "/exit" ] || [ "$FIRST_LINE" = "/q" ]; then
    SALIDA_MOTIVO="salir"
    exit 0
  fi

  if [ "$FIRST_LINE" = "/descargar" ]; then
    # Saca el modelo de memoria con el propio comando de Ollama (equivalente a
    # keep_alive:0, pero usando la herramienta oficial). Útil para forzar y
    # validar a propósito el escenario de carga en frío (🧊) en la siguiente
    # respuesta, en vez de esperar a que expire el keep_alive por defecto.
    echo -e "${C_STATS}Ejecutando: ollama stop ${MODELO}${C_RESET}"
    if ollama stop "$MODELO"; then
      echo -e "${C_STATS}Hecho: ${MODELO} descargado. La próxima respuesta se hará con carga en frío.${C_RESET}"
    else
      echo -e "${C_ERR}No se pudo ejecutar 'ollama stop ${MODELO}' (¿el CLI de ollama está disponible en este equipo?).${C_RESET}"
    fi
    continue
  fi

  if [ "$FIRST_LINE" = "/think" ] || [[ "$FIRST_LINE" == "/think "* ]]; then
    # Alterna el modo de razonamiento enviado a Ollama (campo "think" de la API).
    # Sin argumento: auto→off, off→on, on→off. Con argumento: on | off | auto | low | medium | high.
    ARG_THINK="${FIRST_LINE#/think}"; ARG_THINK="${ARG_THINK# }"
    case "$ARG_THINK" in
      on|off|auto|low|medium|high) THINK_MODE="$ARG_THINK" ;;
      "") if [ "$THINK_MODE" = "off" ]; then THINK_MODE=on; else THINK_MODE=off; fi ;;
      *) echo -e "${C_ERR}Uso: /think [on|off|auto|low|medium|high]${C_RESET}"; continue ;;
    esac
    echo -e "${C_STATS}Thinking: ${THINK_MODE} (se aplica desde el próximo envío).${C_RESET}"
    if [ "$THINK_MODE" != "auto" ] && [ "$(echo "$CAPABILITIES" | jq 'length')" -gt 0 ]        && ! echo "$CAPABILITIES" | jq -e 'index("thinking")' >/dev/null 2>&1; then
      echo -e "${C_ERR}⚠ este modelo NO declara la capacidad 'thinking' (capacidades: $(echo "$CAPABILITIES" | jq -r 'join(", ")')): Ollama puede devolver error o ignorar el valor.${C_RESET}"
    fi
    printf '{"think_mode":"%s"}' "$THINK_MODE" | log_evento think_change || true
    continue
  fi

  if [ "$FIRST_LINE" = "/ps" ]; then
    # Foto del estado real de memoria, también guardada en el log (útil para
    # dejar constancia del reparto GPU/CPU en un momento concreto de la prueba).
    ollama ps 2>/dev/null || echo -e "${C_STATS}(CLI 'ollama' no disponible; se muestra solo la foto de la API)${C_RESET}"
    PS_NOW="$(ps_snapshot)"; GPU_NOW="$(gpu_snapshot)"; RAM_NOW="$(ram_snapshot)"
    echo -e "${C_STATS}/api/ps: ${PS_NOW}${C_RESET}"
    echo -e "${C_STATS}gpu: ${GPU_NOW}${C_RESET}"
    echo -e "${C_STATS}ram: ${RAM_NOW}${C_RESET}"
    jq -nc --argjson ps "$PS_NOW" --argjson gpu "$GPU_NOW" --argjson ram "$RAM_NOW" --argjson ctx "$(echo "$CONTEXT" | jq 'length')"       '{ps:$ps, gpu:$gpu, ram:$ram, context_tokens:$ctx}' | log_evento ps_snapshot || true
    continue
  fi

  if [ "$FIRST_LINE" = "/nota" ] || [[ "$FIRST_LINE" == "/nota "* ]]; then
    # Anotación libre del usuario en el log, asociada al turno actual.
    NOTA_TXT="${FIRST_LINE#/nota}"; NOTA_TXT="${NOTA_TXT# }"
    if [ -z "$NOTA_TXT" ]; then
      echo -e "${C_ERR}Uso: /nota <texto>${C_RESET}"
    else
      jq -nc --arg t "$NOTA_TXT" '{note:$t}' | log_evento note || true
      echo -e "${C_STATS}Nota guardada en el log (turno $TURN).${C_RESET}"
    fi
    continue
  fi

  if [ "$FIRST_LINE" = "/comparar" ]; then
    # Arma una comparativa: el PRÓXIMO prompt que mandes se probará dos veces
    # con el mismo texto exacto: una vez con el modelo descargado de memoria
    # (ollama stop antes de enviarlo) y otra justo después ya en memoria. Solo
    # afecta al siguiente prompt; para el resto de mensajes no se aplica salvo
    # que vuelvas a escribir /comparar.
    COMPARAR_SIGUIENTE=true
    echo -e "${C_STATS}Armado: el PRÓXIMO prompt se probará 2 veces (🧊 frío y 🔥 caliente). Solo aplica una vez.${C_RESET}"
    continue
  fi

  if [[ "$FIRST_LINE" =~ ^/[a-zA-Z?]+$ ]]; then
    echo -e "${C_ERR}Comando desconocido: ${FIRST_LINE}${C_RESET}  (escribe /ayuda)"
    continue
  fi

  if [ "$FIRST_LINE" = "<<<" ]; then
    # Modo pegado explícito: lectura determinista línea a línea (sin readline,
    # sin temporizadores) hasta ver el terminador >>>. Cero ambigüedad con el
    # pegado del terminal, sea cual sea el cliente SSH que uses.
    echo -e "${C_STATS}(pega ahora el bloque; termina con una línea que solo diga >>>)${C_RESET}"
    MSG=""
    while IFS= read -r LINE; do
      [ "$LINE" = ">>>" ] && break
      if [ -z "$MSG" ]; then MSG="$LINE"; else MSG="${MSG}"$'\n'"${LINE}"; fi
    done
    [ -z "$MSG" ] && continue
    LINEAS="$(printf '%s\n' "$MSG" | wc -l)"
    echo -e "${C_STATS}(bloque capturado: ${LINEAS} líneas)${C_RESET}"
  else
    MSG="$FIRST_LINE"
    # Pegado directo (sin <<<): la primera línea ya se ha leído arriba; si el
    # resto del bloque pegado sigue esperando en el buffer (incluidas líneas
    # en blanco), lo unimos al MISMO mensaje en vez de descartarlo o dejar que
    # se dispare como mensajes independientes en la siguiente vuelta.
    while IFS= read -r -t 0.15 EXTRA_LINE; do
      MSG="${MSG}"$'\n'"${EXTRA_LINE}"
    done
    if [[ "$MSG" == *$'\n'* ]]; then
      LINEAS="$(printf '%s\n' "$MSG" | wc -l)"
      echo -e "${C_STATS}(pegado detectado: ${LINEAS} líneas capturadas en un único mensaje)${C_RESET}"
    fi
  fi

  history -s -- "$MSG"
  TURN=$((TURN + 1))

  if [ "$COMPARAR_SIGUIENTE" = true ]; then
    COMPARAR_SIGUIENTE=false
    echo -e "${C_STATS}${C_BOLD}🧪 comparativa frío/caliente para este prompt (turno $TURN)${C_RESET}"

    echo -e "${C_STATS}Ejecutando: ollama stop ${MODELO} (para forzar la pasada en frío)${C_RESET}"
    ollama stop "$MODELO" >/dev/null 2>&1 || true

    if ! procesar_envio "cold"; then
      TURN=$((TURN - 1))
      continue
    fi

    if ! procesar_envio "warm"; then
      TURN=$((TURN - 1))
    fi
    continue
  fi

  if ! procesar_envio ""; then
    TURN=$((TURN - 1))
  fi
done
