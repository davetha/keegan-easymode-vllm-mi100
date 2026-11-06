#!/usr/bin/env bash
# gen-env.sh -- hardware-aware .env generator for the int8-vllm docker-compose setup
# (Qwen3.8-27B INT8 + DFlash2 draft on AMD Instinct MI100).
#
# Run it from this repo's folder (next to docker-compose.yml), with the
# curvedinf/int8-vllm clone sitting next to it (default ../int8-vllm):
#     bash gen-env.sh
# It inspects the machine, does the VRAM math, and writes a recommended .env
# (an existing .env is backed up to .env.bak-<timestamp>, never overwritten silently).
#
# Manual overrides (if detection can't see the hardware):
#     GPU_COUNT=2 VRAM_GIB=32 bash gen-env.sh
#     OUT=- bash gen-env.sh        # print .env to stdout instead of writing

set -euo pipefail

ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }

# ---------- model constants (GiB) -- from the repo's recipe docs ----------
TARGET_GIB=31        # Qwen3.8-27B GPTQ-INT8 weights (HF repo is 31.8 GB)
DRAFT_GIB=2.3        # DFlash2 speculative draft model
OVERHEAD_GIB=2.5     # activations + cuda graphs + runtime, per GPU
UTIL=0.92            # --gpu-memory-utilization (recipe default)
KV_KB_PER_TOKEN_TP4=11.86   # calibrated: repo measures 19 GiB/GPU -> 1.605M tokens at TP4
NS=6                 # speculative tokens (recipe default)

# ---------- GPU count: env override > sysfs AMD cards > rocm-smi ----------
detect_gpus() {
  local n=0 d v
  for d in /sys/class/drm/card*/device; do
    [[ -r "$d/vendor" ]] || continue
    read -r v < "$d/vendor"
    [[ "$v" == "0x1002" ]] && n=$((n+1))
  done
  if (( n == 0 )) && command -v rocm-smi >/dev/null 2>&1; then
    n=$(rocm-smi --showproductname --json 2>/dev/null | grep -o '"card[0-9]*"' | sort -u | wc -l || true)
  fi
  echo "$n"
}

# ---------- VRAM per GPU: env override, else MI100's 32 GB ----------
VRAM="${VRAM_GIB:-32}"

echo "== int8-vllm .env generator (Qwen3.8-27B INT8, AMD MI100) =="
echo ""

echo "-- hardware checks --"
[[ -e /dev/kfd ]] && ok "/dev/kfd present (AMD compute driver loaded)" \
                   || warn "/dev/kfd missing - AMD kernel driver not loaded; Docker GPU access will fail"
[[ -d /dev/dri ]] && ok "/dev/dri present" || warn "/dev/dri missing - no AMD render nodes"
id -nG 2>/dev/null | grep -qw video  && ok "user in 'video' group"  || warn "user NOT in 'video' group (sudo usermod -aG video,render \$USER; then log out/in)"
id -nG 2>/dev/null | grep -qw render && ok "user in 'render' group" || true
if command -v docker >/dev/null 2>&1; then
  ok "docker found"
  docker compose version >/dev/null 2>&1 && ok "docker compose plugin found" || warn "'docker compose' subcommand missing"
else
  warn "docker not found in PATH"
fi
RAM_GIB=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
if   (( RAM_GIB >= 64 )); then ok "RAM: ${RAM_GIB} GiB"
elif (( RAM_GIB >= 32 )); then warn "RAM: ${RAM_GIB} GiB (64+ recommended; the one-time image build is memory-hungry)"
else warn "RAM: ${RAM_GIB} GiB (low - PyTorch image build may OOM; use --build-arg MAX_JOBS=8)"; fi
HOME_FREE_GIB=$(df -PBG "$HOME" 2>/dev/null | awk 'NR==2{gsub(/[^0-9]/,"",$4); print $4+0}')
(( HOME_FREE_GIB >= 200 )) && ok "disk free under \$HOME: ${HOME_FREE_GIB} GiB" \
                            || warn "disk free under \$HOME only ${HOME_FREE_GIB} GiB (~200+ GB wanted: ~80 GB images, ~35 GB models, caches)"
[[ -f docker-compose.yml ]] || warn "docker-compose.yml not found in current dir - run this from the repo root"
if command -v rocm-smi >/dev/null 2>&1; then
  rocm-smi --showtopo 2>/dev/null | grep -qi xgmi \
    && ok "XGMI (Infinity Fabric) link detected between GPUs" \
    || warn "no XGMI link detected - GPUs are PCIe-attached; some fast paths will not engage"
fi

echo ""
echo "-- GPU detection --"
N="${GPU_COUNT:-$(detect_gpus)}"
if (( N == 0 )); then
  fail "No AMD GPUs detected. If this is wrong: GPU_COUNT=2 VRAM_GIB=32 bash gen-env.sh"
  exit 1
fi
ok "GPUs detected: ${N}"
[[ -n "${VRAM_GIB:-}" ]] || warn "VRAM assumed 32 GiB per GPU (MI100). Override with VRAM_GIB=<n> if different."
[[ "${VRAM}" == "32" ]] || warn "This project's Dockerfiles target MI100 (gfx908); other AMD GPUs are untested."

# ---------- choose tensor-parallel size ----------
TP=$N
if   (( N == 1 )); then TP=1
elif (( N == 3 )); then TP=2; warn "3 GPUs found: using GPUs 0,1 at TP=2 (GPU 2 left idle; TP=3 is not a safe split for this model)"
elif (( N > 4 ));  then TP=4; warn "more than 4 GPUs: using GPUs 0-3 at TP=4 (recipe maximum)"
fi
GPUS=$(seq -s, 0 $((TP-1)))

# ---------- VRAM math ----------
USABLE=$(awk -v v="$VRAM" -v u="$UTIL" 'BEGIN{printf "%.2f", v*u}')
FIXED=$(awk -v t="$TARGET_GIB" -v d="$DRAFT_GIB" -v o="$OVERHEAD_GIB" -v n="$TP" 'BEGIN{printf "%.2f", (t+d)/n+o}')
KV_GIB=$(awk -v u="$USABLE" -v f="$FIXED" 'BEGIN{printf "%.2f", u-f}')
CAPACITY=$(awk -v kv="$KV_GIB" -v k="$KV_KB_PER_TOKEN_TP4" -v n="$TP" 'BEGIN{printf "%.0f", kv*1048576/(k*4/n)}')

echo ""
echo "-- VRAM plan (per GPU, ${VRAM} GiB assumed) --"
echo "  usable at UTIL=${UTIL}:        ${USABLE} GiB"
echo "  weights+overhead at TP=${TP}:  ${FIXED} GiB   (target ${TARGET_GIB} + draft ${DRAFT_GIB} split /${TP}, +${OVERHEAD_GIB} overhead)"
echo "  left for context (KV):         ${KV_GIB} GiB  (~${CAPACITY} tokens of cache)"

if (( N == 1 )); then
  fail "1 GPU is not enough: the INT8 model needs ~${FIXED} GiB per GPU but only ${USABLE} GiB is usable. Two MI100s minimum."
  exit 1
fi
SMALL=$(awk -v kv="$KV_GIB" 'BEGIN{print (kv < 2) ? 1 : 0}')
if (( SMALL == 1 )); then
  fail "Not enough free VRAM for the KV cache at TP=${TP} (${KV_GIB} GiB left). Check VRAM_GIB override."
  exit 1
fi

# ---------- pick context length + concurrency: largest of 65536/32768/16384/8192 that fits 6 seqs at 25% headroom ----------
MAXLEN=0; SEQ=6
for L in 65536 32768 16384 8192; do
  FITS=$(awk -v c="$CAPACITY" -v l="$L" -v s="$SEQ" 'BEGIN{print (c >= l*s*1.25) ? 1 : 0}')
  if (( FITS == 1 )); then MAXLEN=$L; break; fi
done
if (( MAXLEN == 0 )); then
  SEQ=2
  for L in 16384 8192; do
    FITS=$(awk -v c="$CAPACITY" -v l="$L" -v s="$SEQ" 'BEGIN{print (c >= l*s*1.25) ? 1 : 0}')
    if (( FITS == 1 )); then MAXLEN=$L; break; fi
  done
  warn "tight memory: reduced concurrency to ${SEQ} and context to ${MAXLEN}"
fi

# ---------- port: default 8000, bump if something is listening ----------
PORT=8000
if command -v ss >/dev/null 2>&1; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}\$"; then
      warn "port ${PORT} is in use"; PORT=$((PORT+1))
    else break; fi
  done
fi

echo ""
echo "-- recommendation --"
echo "  TP=${TP} on GPUs ${GPUS}, context ${MAXLEN}, ${SEQ} concurrent requests, port ${PORT}"

# ---------- write .env ----------
OUT="${OUT:-.env}"
CONTENT="# Generated by gen-env.sh $(date '+%Y-%m-%d %H:%M') -- detected: ${N} GPU(s), ${VRAM} GiB assumed each, TP=${TP}
# Free capacity for context cache: ~${CAPACITY} tokens. Edit freely; then: docker compose up -d vllm

# ---- server ----
PORT=${PORT}
# 127.0.0.1 = reachable from this machine only. Set your LAN IP (or 0.0.0.0) to
# open it up -- and then add an API key via EXTRA_ARGS below.
PUBLISH_IP=127.0.0.1

# ---- GPUs ----
GPUS=${GPUS}
TP=${TP}

# ---- capacity ----
MAX_MODEL_LEN=${MAXLEN}
MAX_NUM_SEQS=${SEQ}
GPU_MEM_UTIL=${UTIL}
NS=${NS}

# ---- paths (relative to the folder holding docker-compose.yml) ----
MODELS_DIR=./models
AITER_DIR=./aiter
VLLM_DIR=../int8-vllm   # the curvedinf/int8-vllm clone (image build context)

# ---- optional extra vLLM flags appended to the serve command ----
# e.g. EXTRA_ARGS=--api-key change-me-to-a-long-random-string
EXTRA_ARGS=
"

if [[ "$OUT" == "-" ]]; then
  printf '%s\n' "$CONTENT"
else
  if [[ -f "$OUT" ]]; then
    cp "$OUT" "${OUT}.bak-$(date +%Y%m%d-%H%M%S)"
    echo "(existing ${OUT} backed up)"
  fi
  printf '%s\n' "$CONTENT" > "$OUT"
  ok "wrote ${OUT}"
fi

echo ""
echo "Next:   docker compose up -d vllm   (first boot takes 15-30+ min)"
echo "        docker compose logs -f vllm"
