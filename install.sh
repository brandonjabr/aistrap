#!/usr/bin/env bash
# =============================================================================
#  AIStrap 2.0 (formerly UbuntuDL) - one command to turn a fresh machine into a modern AI/ML box.
#
#    curl -fsSL https://raw.githubusercontent.com/brandonjabr/aistrap/master/install.sh | bash
#
#  Supports: Ubuntu 22.04 / 24.04 / 26.04 (and Debian-family derivatives),
#            WSL2 on Windows, and macOS on Apple Silicon.
#  Windows (native): see install.ps1.   Options: ./install.sh --help
#
#  Nothing is pinned. Every run looks at your hardware and resolves the newest
#  compatible builds: GPU driver, PyTorch wheel variant (CUDA / ROCm / XPU / MPS
#  / CPU), Python, and the rest of the stack. Run it again later to upgrade.
#
#  The original 2017 script (Ubuntu 16.04, CUDA 8, Python 2.7) lives in legacy/.
# =============================================================================
set -Eeuo pipefail

AISTRAP_VERSION="2.0.0"
AISTRAP_REPO_RAW="${AISTRAP_REPO_RAW:-https://raw.githubusercontent.com/brandonjabr/aistrap/master}"
AISTRAP_HOME="${AISTRAP_HOME:-$HOME/.aistrap}"

# ----------------------------------------------------------------------------
# Defaults (an empty value means "use the profile's default")
# ----------------------------------------------------------------------------
ACTION="install"
PROFILE="standard"
PYVER="3.12"
ASSUME_YES=0
DRY_RUN=0
FORCE_BACKEND=""
WANT_SYSTEM=1
WANT_DRIVER=1
WANT_CUDA_TOOLKIT=0
WANT_SYSTEM_UPGRADE=0
WANT_SHELL_CONFIG=1
WANT_DOCKER=""
WANT_OLLAMA=""
WANT_JAX=""
WANT_TF=""
WANT_VLLM=""
WANT_CLAUDE=""
WANT_VSCODE=""
SAVED_ARGS=""

# Detected / derived state
OS="" ; ARCH="" ; IS_WSL=0 ; IN_CONTAINER=0
DISTRO_ID="" ; DISTRO_LIKE="" ; DISTRO_VERSION="" ; DISTRO_CODENAME="" ; DISTRO_NAME=""
GPU_VENDOR="none" ; GPU_NAME="" ; DRIVER_CUDA="" ; DRIVER_VERSION="" ; GPU_CC=""
BACKEND="" ; TORCH_INDEX_URL="" ; TORCH_EXPECTED_VERSION=""
SUDO="" ; SUDO_KEEPALIVE_PID=""
LOG_FILE="/dev/null"
NEED_REBOOT=0 ; NEED_RELOGIN=0
WARNINGS="" ; INSTALLED=""
SCRIPT_DIR="" ; STEP_N=0

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s !!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNINGS="${WARNINGS}  - $*"$'\n'; }
die()   { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step()  { STEP_N=$((STEP_N + 1)); printf '\n%s[%d] %s%s\n' "$C_BOLD$C_CYAN" "$STEP_N" "$*" "$C_RESET"; }
note_installed() { INSTALLED="${INSTALLED}  - $*"$'\n'; }
have()  { command -v "$1" >/dev/null 2>&1; }

# run CMD...      -> executes (or prints in --dry-run)
# run_sh "STRING" -> same, for commands that need a shell (pipes, redirects)
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '%s   [dry-run] %s%s\n' "$C_DIM" "$*" "$C_RESET"; return 0; fi
  printf '%s   $ %s%s\n' "$C_DIM" "$*" "$C_RESET"
  "$@"
}
run_sh() {
  if [ "$DRY_RUN" = 1 ]; then printf '%s   [dry-run] %s%s\n' "$C_DIM" "$1" "$C_RESET"; return 0; fi
  printf '%s   $ %s%s\n' "$C_DIM" "$1" "$C_RESET"
  bash -c "$1"
}

on_error() {
  local code=$? line=$1
  printf '\n%sInstall stopped:%s command failed (exit %s) near line %s.\n' "$C_RED" "$C_RESET" "$code" "$line" >&2
  [ "$LOG_FILE" != /dev/null ] && printf 'Full log: %s\n' "$LOG_FILE" >&2
  printf 'It is safe to re-run the installer; finished steps are skipped or upgraded in place.\n' >&2
}
cleanup() { [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; }
trap 'on_error $LINENO' ERR
trap cleanup EXIT

usage() {
  cat <<EOF
AIStrap ${AISTRAP_VERSION} - one-command AI/ML workstation setup (Linux, WSL2, macOS)

Usage: install.sh [options]

Profiles:
  -p, --profile NAME     minimal | standard (default) | full
                           minimal : GPU driver, PyTorch, scientific Python, JupyterLab
                           standard: + Hugging Face stack, LLM SDKs, experiment tracking,
                                     Ollama, Docker (+ NVIDIA Container Toolkit), hf CLI
                           full    : + JAX and TensorFlow envs, vLLM, Claude Code, extra libs

Components (override the profile):
  --jax / --no-jax               separate JAX environment
  --tensorflow / --no-tensorflow separate TensorFlow + Keras environment
  --vllm / --no-vllm             vLLM inference server (Linux + NVIDIA only)
  --ollama / --no-ollama         local LLM runtime
  --docker / --no-docker         Docker Engine (+ NVIDIA Container Toolkit)
  --claude-code / --no-claude-code   Anthropic's Claude Code CLI
  --vscode                       Visual Studio Code
  --cuda-toolkit                 full CUDA toolkit (nvcc). Not needed for PyTorch/JAX;
                                 only for compiling custom CUDA kernels.

Hardware / system:
  --backend NAME         force the PyTorch build: cpu, mps, xpu, cu130, rocm7.2, ...
  --python X.Y           Python version for the environments (default ${PYVER})
  --no-driver            don't install/upgrade the NVIDIA driver
  --no-system            skip OS packages (apt/Homebrew); only build the Python stack
  --system-upgrade       also run a full apt upgrade first
  --no-shell-config      don't add the 'ai' alias / PATH block to your shell rc
  --home DIR             where envs live (default ~/.aistrap)

Other:
  -y, --yes              don't ask for confirmation
  -n, --dry-run          detect hardware and print the plan + commands, change nothing
  --doctor               run the health check on an existing install
  --uninstall            remove the environments and shell config
  -h, --help             this help
  -V, --version          print version

After install:  ai  (activate env)   aistrap doctor   aistrap lab   aistrap update   aistrap help
EOF
}

need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "Option $1 needs a value"; }

parse_args() {
  local a
  for a in "$@"; do
    case "$a" in -n|--dry-run|--doctor|--uninstall|-h|--help|-V|--version) ;;
      *) SAVED_ARGS="${SAVED_ARGS} $(printf '%q' "$a")" ;;
    esac
  done
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--profile) need_arg "$@"; PROFILE="$2"; shift ;;
      --profile=*) PROFILE="${1#*=}" ;;
      --python) need_arg "$@"; PYVER="$2"; shift ;;
      --python=*) PYVER="${1#*=}" ;;
      --backend) need_arg "$@"; FORCE_BACKEND="$2"; shift ;;
      --backend=*) FORCE_BACKEND="${1#*=}" ;;
      --home) need_arg "$@"; AISTRAP_HOME="$2"; shift ;;
      --home=*) AISTRAP_HOME="${1#*=}" ;;
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --no-driver) WANT_DRIVER=0 ;;
      --no-system) WANT_SYSTEM=0 ;;
      --system-upgrade) WANT_SYSTEM_UPGRADE=1 ;;
      --no-shell-config) WANT_SHELL_CONFIG=0 ;;
      --cuda-toolkit) WANT_CUDA_TOOLKIT=1 ;;
      --docker) WANT_DOCKER=1 ;;           --no-docker) WANT_DOCKER=0 ;;
      --ollama) WANT_OLLAMA=1 ;;           --no-ollama) WANT_OLLAMA=0 ;;
      --jax) WANT_JAX=1 ;;                 --no-jax) WANT_JAX=0 ;;
      --tensorflow|--tf) WANT_TF=1 ;;      --no-tensorflow|--no-tf) WANT_TF=0 ;;
      --vllm) WANT_VLLM=1 ;;               --no-vllm) WANT_VLLM=0 ;;
      --claude-code) WANT_CLAUDE=1 ;;      --no-claude-code) WANT_CLAUDE=0 ;;
      --vscode) WANT_VSCODE=1 ;;           --no-vscode) WANT_VSCODE=0 ;;
      --doctor) ACTION="doctor" ;;
      --uninstall) ACTION="uninstall" ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) echo "AIStrap ${AISTRAP_VERSION}"; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  case "$PROFILE" in minimal|standard|full) ;; *) die "Unknown profile '$PROFILE' (minimal|standard|full)";; esac
  case "$PYVER" in 3.1[1-9]) ;; *) die "Python $PYVER is not supported (PyTorch needs 3.11+)";; esac
}

set_default() { # set_default VAR VALUE  -> only if VAR is empty
  local cur
  eval "cur=\${$1}"
  [ -n "$cur" ] || eval "$1=\$2"
}

apply_profile_defaults() {
  case "$PROFILE" in
    minimal)  set_default WANT_OLLAMA 0; set_default WANT_DOCKER 0; set_default WANT_JAX 0
              set_default WANT_TF 0;     set_default WANT_VLLM 0;   set_default WANT_CLAUDE 0 ;;
    standard) set_default WANT_OLLAMA 1; set_default WANT_DOCKER 1; set_default WANT_JAX 0
              set_default WANT_TF 0;     set_default WANT_VLLM 0;   set_default WANT_CLAUDE 0 ;;
    full)     set_default WANT_OLLAMA 1; set_default WANT_DOCKER 1; set_default WANT_JAX 1
              set_default WANT_TF 1;     set_default WANT_VLLM 1;   set_default WANT_CLAUDE 1 ;;
  esac
  set_default WANT_VSCODE 0
  # Docker Desktop on macOS is a big GUI app with its own licence; only on request or 'full'.
  if [ "$OS" = macos ] && [ "$PROFILE" != full ] && [ "$WANT_DOCKER" = 1 ] && ! printf '%s' "$SAVED_ARGS" | grep -q -- '--docker'; then
    WANT_DOCKER=0
  fi
  # Things that only make sense in some places
  if [ "$IN_CONTAINER" = 1 ]; then WANT_DOCKER=0; WANT_DRIVER=0; fi
  if [ "$IS_WSL" = 1 ]; then WANT_DRIVER=0; fi           # the Windows driver is used inside WSL
  if [ "$WANT_VLLM" = 1 ] && { [ "$OS" != linux ] || [ "$GPU_VENDOR" != nvidia ]; }; then
    [ "$PROFILE" = full ] || warn "vLLM is only installed on Linux with an NVIDIA GPU; skipping."
    WANT_VLLM=0
  fi
  if [ "$WANT_SYSTEM" = 0 ]; then WANT_DRIVER=0; WANT_DOCKER=0; WANT_CUDA_TOOLKIT=0; WANT_VSCODE=0; fi
}

# ----------------------------------------------------------------------------
# Detection
# ----------------------------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) die "On Windows, run install.ps1 in PowerShell (or use WSL2)." ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  ARCH="$(uname -m)"
  case "$ARCH" in amd64) ARCH=x86_64 ;; arm64) [ "$OS" = linux ] && ARCH=aarch64 ;; esac

  if [ "$OS" = linux ]; then
    grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && IS_WSL=1
    { [ -f /.dockerenv ] || grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; } && IN_CONTAINER=1
    if [ -r /etc/os-release ]; then
      # shellcheck disable=SC1091
      DISTRO_ID="$(. /etc/os-release; echo "${ID:-}")"
      DISTRO_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
      DISTRO_VERSION="$(. /etc/os-release; echo "${VERSION_ID:-}")"
      DISTRO_CODENAME="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
      DISTRO_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
    fi
  else
    DISTRO_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
    if [ "$ARCH" != arm64 ]; then
      die "Intel Macs are not supported: PyTorch stopped shipping x86_64 macOS builds after 2.2. Use an Apple Silicon Mac, Linux, or Windows."
    fi
  fi
}

is_debian_family() { [ "$DISTRO_ID" = ubuntu ] || [ "$DISTRO_ID" = debian ] || printf '%s' "$DISTRO_LIKE" | grep -qwE 'ubuntu|debian'; }
is_ubuntu_family() { [ "$DISTRO_ID" = ubuntu ] || printf '%s' "$DISTRO_LIKE" | grep -qw ubuntu; }

pci_display_vendors() { # prints PCI vendor IDs of display-class devices
  local d
  set +f
  for d in /sys/bus/pci/devices/*; do
    [ -r "$d/class" ] || continue
    case "$(cat "$d/class")" in 0x03*) cat "$d/vendor" ;; esac
  done 2>/dev/null | sort -u
  set -f
}

read_nvidia_smi() {
  have nvidia-smi || return 1
  local out
  out="$(nvidia-smi 2>/dev/null)" || return 1
  DRIVER_CUDA="$(printf '%s\n' "$out" | sed -nE 's/.*CUDA Version: *([0-9]+\.[0-9]+).*/\1/p' | head -1)"
  DRIVER_VERSION="$(printf '%s\n' "$out" | sed -nE 's/.*Driver Version: *([0-9.]+).*/\1/p' | head -1)"
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  GPU_CC="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)"
  case "$GPU_CC" in [0-9]*.[0-9]*) ;; *) GPU_CC="" ;; esac
  local n; n="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true)"
  [ "${n:-0}" -gt 1 ] && GPU_NAME="${n}x ${GPU_NAME}"
  return 0
}

detect_gpu() {
  if [ -n "${AISTRAP_SIMULATE_GPU:-}" ]; then   # testing aid: nvidia[:DRIVER_CUDA[:COMPUTE_CAP]] | amd | intel | none
    local IFS=:
    # shellcheck disable=SC2086
    set -- $AISTRAP_SIMULATE_GPU
    GPU_VENDOR="$1"; DRIVER_CUDA="${2:-}"; GPU_CC="${3:-}"
    GPU_NAME="(simulated ${GPU_VENDOR})"; return 0
  fi
  if [ "$OS" = macos ]; then
    GPU_VENDOR=apple
    GPU_NAME="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon') GPU"
    return 0
  fi
  if read_nvidia_smi; then GPU_VENDOR=nvidia; return 0; fi

  local vendors
  vendors="$(pci_display_vendors)"
  if printf '%s' "$vendors" | grep -q 0x10de; then
    GPU_VENDOR=nvidia               # present, but no working driver yet
  elif printf '%s' "$vendors" | grep -q 0x1002; then
    GPU_VENDOR=amd
  elif printf '%s' "$vendors" | grep -q 0x8086 && have lspci && lspci | grep -iE 'vga|display|3d' | grep -qiE 'arc|battlemage|alchemist|DG2'; then
    GPU_VENDOR=intel
  fi
  if [ "$GPU_VENDOR" != none ] && [ -z "$GPU_NAME" ] && have lspci; then
    local pat="$GPU_VENDOR"
    [ "$GPU_VENDOR" = amd ] && pat="amd|ati"
    GPU_NAME="$(lspci | grep -iE 'vga|3d|display' | grep -iE "$pat" | head -1 | sed -E 's/^[^:]*: //' || true)"
  fi
  [ -n "$GPU_NAME" ] || GPU_NAME="$GPU_VENDOR GPU"
  [ "$GPU_VENDOR" = none ] && GPU_NAME="none detected"
  return 0
}

machine_summary() {
  local cpu cores mem disk
  if [ "$OS" = macos ]; then
    cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"; cores="$(sysctl -n hw.ncpu)"
    mem="$(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
  else
    cpu="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || true)"
    [ -n "$cpu" ] || cpu="$(lscpu 2>/dev/null | sed -nE 's/^Model name: *//p' | head -1 || true)"
    cores="$(nproc 2>/dev/null || echo '?')"
    mem="$(awk '/MemTotal/ {printf "%d GB", $2/1048576}' /proc/meminfo 2>/dev/null || true)"
  fi
  disk="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}' || true)"
  printf '  %-10s %s%s%s\n' "OS" "$DISTRO_NAME" "$([ "$IS_WSL" = 1 ] && echo ' (WSL2)')" "$([ "$IN_CONTAINER" = 1 ] && echo ' (container)')"
  printf '  %-10s %s (%s cores, %s)\n' "CPU" "${cpu:-unknown}" "$cores" "$ARCH"
  printf '  %-10s %s\n' "Memory" "${mem:-unknown}"
  printf '  %-10s %s' "GPU" "$GPU_NAME"
  [ -n "$DRIVER_VERSION" ] && printf ' (driver %s, CUDA %s)' "$DRIVER_VERSION" "$DRIVER_CUDA"
  [ -n "$GPU_CC" ] && printf ' [compute %s]' "$GPU_CC"
  printf '\n  %-10s %s GB free in %s\n' "Disk" "${disk:-?}" "$HOME"
  local need=15; [ "$PROFILE" = minimal ] && need=8; [ "$PROFILE" = full ] && need=45
  if [ -n "$disk" ] && [ "$disk" -lt "$need" ]; then
    warn "Only ${disk} GB free; the '${PROFILE}' profile needs roughly ${need} GB."
  fi
}

# ----------------------------------------------------------------------------
# PyTorch backend resolution: query download.pytorch.org live and pick the
# index with the newest torch build that this machine's driver can run.
# ----------------------------------------------------------------------------
semver_num() { # 2.15.0 -> 2015000
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  echo $(( ${1:-0} * 1000000 + ${2:-0} * 1000 + ${3:-0} ))
}
cuda_num() { # "13.0" -> 1300
  local maj="${1%%.*}" min="${1#*.}"; min="${min%%.*}"
  echo $(( 10#$maj * 100 + 10#$min ))
}
cuda_tag_num() { # cu132 -> 1302, cu128 -> 1208
  local n="${1#cu}"
  echo $(( 10#${n:0:2} * 100 + 10#${n:2} ))
}

CP_TAG="" ; WHEEL_PLAT_RE=""
latest_torch_on_index() { # prints newest torch version available for this python/platform on index $1
  local tag="$1" tag_re html
  tag_re="$(printf '%s' "$tag" | sed 's/\./\\./g')"
  html="$(curl -fsSL --max-time 25 "https://download.pytorch.org/whl/${tag}/torch/" 2>/dev/null || true)"
  [ -n "$html" ] || return 0
  printf '%s\n' "$html" \
    | grep -oE "torch-[0-9]+\.[0-9]+\.[0-9]+(%2B|\+)${tag_re}-${CP_TAG}-${CP_TAG}-${WHEEL_PLAT_RE}" \
    | sed -E 's/^torch-([0-9]+\.[0-9]+\.[0-9]+).*/\1/' \
    | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -1 || true
}

BEST_TAG="" ; BEST_VER=""
pick_best_index() { # pick_best_index "cand1 cand2 ..."  (candidates newest-first)
  local tag v best_n=0 n
  BEST_TAG=""; BEST_VER=""
  for tag in $1; do
    v="$(latest_torch_on_index "$tag")"
    [ -n "$v" ] || continue
    printf '%s   %-9s -> torch %s%s\n' "$C_DIM" "$tag" "$v" "$C_RESET"
    n="$(semver_num "$v")"
    if [ "$n" -gt "$best_n" ]; then best_n="$n"; BEST_TAG="$tag"; BEST_VER="$v"; fi
  done
}

select_backend() {
  CP_TAG="cp$(printf '%s' "$PYVER" | tr -d .)"
  WHEEL_PLAT_RE="manylinux[_0-9a-z]*_${ARCH}"

  if [ -n "$FORCE_BACKEND" ]; then
    BACKEND="$FORCE_BACKEND"
    case "$BACKEND" in
      mps|pypi|default) TORCH_INDEX_URL="" ;;
      *) TORCH_INDEX_URL="https://download.pytorch.org/whl/${BACKEND}" ;;
    esac
    return 0
  fi

  case "$GPU_VENDOR" in
    apple)
      BACKEND="mps"; TORCH_INDEX_URL=""   # PyPI macOS wheels ship Metal (MPS) support
      ;;
    nvidia)
      local cap floor=0 cands="" maj min t n
      if [ -n "$DRIVER_CUDA" ]; then cap="$(cuda_num "$DRIVER_CUDA")"
      else
        cap=1300   # driver not loaded yet (fresh install, reboot pending): assume a current (580+) driver
        warn "NVIDIA driver not active yet; assuming it will support CUDA 13.0. 'aistrap update' re-checks after reboot."
      fi
      if [ -n "$GPU_CC" ]; then
        n="$(cuda_num "$GPU_CC")"
        # Blackwell (sm_100/sm_120) kernels exist only in CUDA 12.8+ builds.
        [ "$n" -ge 1000 ] && floor=1208
        # CUDA 13 dropped Maxwell/Pascal/Volta (< sm_75); their last builds are cu126.
        [ "$n" -lt 705 ] && [ "$cap" -gt 1206 ] && cap=1206
      fi
      for maj in 14 13 12; do for min in 9 8 7 6 5 4 3 2 1 0; do
        t="cu${maj}${min}"
        [ "$maj" = 12 ] && [ "$min" -lt 6 ] && continue
        n="$(cuda_tag_num "$t")"
        if [ "$n" -le "$cap" ] && [ "$n" -ge "$floor" ]; then cands="$cands $t"; fi
      done; done
      info "Finding the newest PyTorch build for this GPU (driver CUDA ${DRIVER_CUDA:-unknown}, compute ${GPU_CC:-unknown})..."
      pick_best_index "$cands"
      if [ -z "$BEST_TAG" ] && [ "$cap" -lt 1206 ] && [ "$floor" = 0 ]; then
        warn "Your NVIDIA driver only supports CUDA ${DRIVER_CUDA}; using an older PyTorch build. Update the driver for current releases."
        pick_best_index "cu124 cu121 cu118"
      fi
      if [ -z "$BEST_TAG" ] && [ "$floor" -gt "$cap" ]; then
        warn "This GPU needs a driver with CUDA 12.8+ (570 or newer); yours supports ${DRIVER_CUDA}. Update the driver, then run 'aistrap update'."
      fi
      ;;
    amd)
      info "Finding the newest PyTorch ROCm build..."
      pick_best_index "rocm7.9 rocm7.8 rocm7.7 rocm7.6 rocm7.5 rocm7.4 rocm7.3 rocm7.2 rocm7.1 rocm7.0 rocm6.4"
      ;;
    intel)
      info "Checking PyTorch Intel GPU (XPU) builds..."
      pick_best_index "xpu"
      ;;
    *)
      # CPU-only Linux: use the CPU index so we don't download ~3 GB of CUDA libraries
      pick_best_index "cpu"
      ;;
  esac

  if [ "$GPU_VENDOR" != apple ]; then
    if [ -n "$BEST_TAG" ]; then
      BACKEND="$BEST_TAG"; TORCH_EXPECTED_VERSION="$BEST_VER"
      TORCH_INDEX_URL="https://download.pytorch.org/whl/${BEST_TAG}"
    else
      [ "$GPU_VENDOR" = nvidia ] || warn "Could not find a matching build on download.pytorch.org (offline?); using the default PyPI wheel."
      BACKEND="pypi"; TORCH_INDEX_URL=""
    fi
  fi
}

backend_label() {
  case "$BACKEND" in
    mps) echo "Apple Metal (MPS)" ;;
    cu*) echo "NVIDIA CUDA $(echo "${BACKEND#cu}" | sed -E 's/^([0-9]{2})([0-9]+)$/\1.\2/')" ;;
    rocm*) echo "AMD ROCm ${BACKEND#rocm}" ;;
    xpu) echo "Intel GPU (XPU)" ;;
    cpu) echo "CPU only" ;;
    *) echo "default PyPI build" ;;
  esac
}

expected_accel() { # what doctor.py should find
  case "$BACKEND" in
    mps) echo mps ;; cu*) echo cuda ;; rocm*) echo rocm ;; xpu) echo xpu ;; cpu) echo cpu ;;
    *) if [ "$GPU_VENDOR" = nvidia ] && [ "$OS" = linux ]; then echo cuda; else echo cpu; fi ;;  # PyPI default on Linux is a CUDA build
  esac
}

# ----------------------------------------------------------------------------
# Python package sets
# ----------------------------------------------------------------------------
PKGS_CORE="numpy scipy pandas polars pyarrow scikit-learn matplotlib seaborn plotly
  jupyterlab ipykernel ipywidgets tqdm rich"
PKGS_STANDARD="transformers datasets accelerate peft trl diffusers safetensors tokenizers
  sentence-transformers evaluate timm einops huggingface_hub[cli]
  xgboost lightgbm onnx onnxruntime opencv-python-headless gradio
  anthropic openai mcp ollama
  wandb mlflow tensorboard"
PKGS_FULL="lightning optuna catboost statsmodels duckdb sympy networkx shap"

ai_env_packages() {
  local p="$PKGS_CORE"
  if [ "$PROFILE" != minimal ]; then
    p="$p $PKGS_STANDARD"
    [ "$GPU_VENDOR" = apple ] && p="$p mlx mlx-lm"
    [ "$GPU_VENDOR" = nvidia ] && [ "$OS" = linux ] && p="$p bitsandbytes"
  fi
  [ "$PROFILE" = full ] && p="$p $PKGS_FULL"
  [ "$PROFILE" = full ] && [ "$GPU_VENDOR" = apple ] && p="$p mlx-vlm"
  # shellcheck disable=SC2086
  echo $p   # collapse whitespace (globbing is off: see main)
}

jax_package() {
  if [ "$GPU_VENDOR" = nvidia ] && [ "$OS" = linux ]; then
    if { [ -n "$DRIVER_CUDA" ] && [ "$(cuda_num "$DRIVER_CUDA")" -lt 1300 ]; } || { [ -n "$GPU_CC" ] && [ "$(cuda_num "$GPU_CC")" -lt 705 ]; }; then
      echo "jax[cuda12]"
    else
      echo "jax[cuda13]"
    fi
  else
    echo "jax"
  fi
}
tf_package() {
  if [ "$GPU_VENDOR" = nvidia ] && [ "$OS" = linux ]; then echo "tensorflow[and-cuda]"; else echo "tensorflow"; fi
}

# ----------------------------------------------------------------------------
# Plan + confirmation
# ----------------------------------------------------------------------------
yn() { [ "$1" = 1 ] && echo "yes" || echo "no"; }

show_plan() {
  printf '\n%sThis machine%s\n' "$C_BOLD" "$C_RESET"
  machine_summary
  printf '\n%sPlan (profile: %s)%s\n' "$C_BOLD" "$PROFILE" "$C_RESET"
  if [ "$WANT_SYSTEM" = 1 ]; then
    if [ "$OS" = macos ]; then echo "  - Homebrew + developer tools (git, git-lfs, cmake, ffmpeg, btop, ...)"
    else echo "  - System packages via apt (build tools, git-lfs, ffmpeg, btop/nvtop, ...)"; fi
  fi
  if [ "$GPU_VENDOR" = nvidia ] && [ "$OS" = linux ]; then
    if [ "$IS_WSL" = 1 ]; then echo "  - NVIDIA driver: provided by Windows (nothing to install in WSL)"
    elif [ -n "$DRIVER_VERSION" ]; then echo "  - NVIDIA driver: already working (${DRIVER_VERSION})"
    elif [ "$WANT_DRIVER" = 1 ]; then echo "  - NVIDIA driver: install the recommended driver (reboot needed afterwards)"
    else echo "  - NVIDIA driver: skipped (--no-driver)"; fi
  fi
  [ "$WANT_CUDA_TOOLKIT" = 1 ] && echo "  - CUDA toolkit (nvcc) from NVIDIA's apt repo"
  echo "  - uv + Python ${PYVER} (managed, isolated from the system Python)"
  local blurb="scientific Python + JupyterLab"
  [ "$PROFILE" = standard ] && blurb="Hugging Face, LLM SDKs, tracking, JupyterLab"
  [ "$PROFILE" = full ] && blurb="everything in standard + extras"
  printf '  - env "ai" (in %s/envs): PyTorch %s [%s] + %s\n' "$(printf '%s' "$AISTRAP_HOME" | sed "s|^$HOME|~|")" \
    "${TORCH_EXPECTED_VERSION:-latest}" "$(backend_label)" "$blurb"
  [ "$WANT_JAX" = 1 ] && echo "  - env \"jax\": $(jax_package), Flax, Optax"
  [ "$WANT_TF" = 1 ] && echo "  - env \"tf\": $(tf_package), Keras 3"
  [ "$WANT_VLLM" = 1 ] && echo "  - vLLM server as an isolated tool ('vllm serve <model>')"
  [ "$PROFILE" != minimal ] && echo "  - Hugging Face 'hf' CLI on your PATH"
  [ "$WANT_OLLAMA" = 1 ] && echo "  - Ollama (run local LLMs: 'ollama run <model>')"
  [ "$WANT_DOCKER" = 1 ] && echo "  - Docker$([ "$OS" = macos ] && echo " Desktop")$([ "$GPU_VENDOR" = nvidia ] && [ "$OS" = linux ] && echo ' + NVIDIA Container Toolkit (GPU containers)')"
  [ "$WANT_CLAUDE" = 1 ] && echo "  - Claude Code (AI coding agent CLI)"
  [ "$WANT_VSCODE" = 1 ] && echo "  - Visual Studio Code"
  echo "  - 'aistrap' helper (doctor, lab, update, shell) + 'ai' alias + Jupyter kernels"
  echo
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY_RUN" = 1 ] && return 0
  local ans=""
  if [ -t 0 ]; then
    printf '%sProceed? [Y/n] %s' "$C_BOLD" "$C_RESET"
    read -r ans || ans=""
  elif (: </dev/tty) 2>/dev/null; then      # piped from curl: ask on the terminal
    printf '%sProceed? [Y/n] %s' "$C_BOLD" "$C_RESET"
    read -r ans </dev/tty || ans=""
  else
    info "No terminal to confirm on; continuing (use --dry-run to preview first)."
    return 0
  fi
  case "$ans" in ""|y|Y|yes|YES) return 0 ;; *) echo "Aborted."; exit 0 ;; esac
}

# ----------------------------------------------------------------------------
# Setup helpers
# ----------------------------------------------------------------------------
setup_logging() {
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$AISTRAP_HOME/logs"
  LOG_FILE="$AISTRAP_HOME/logs/install-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

setup_sudo() {
  if [ "$(id -u)" = 0 ]; then SUDO=""; return 0; fi
  have sudo || die "sudo is required for system packages (or re-run with --no-system)."
  SUDO="sudo"
  [ "$DRY_RUN" = 1 ] && return 0
  info "Some steps need administrator rights; you may be asked for your password once."
  sudo -v || die "Could not get sudo rights."
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
}

fetch_asset() { # fetch_asset NAME DEST  (from the local checkout if present, else GitHub)
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$1" ]; then
    run cp "$SCRIPT_DIR/$1" "$2"
  else
    run curl -fsSL "$AISTRAP_REPO_RAW/$1" -o "$2"
  fi
}

# ----------------------------------------------------------------------------
# Linux system layer
# ----------------------------------------------------------------------------
apt_get() { run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }
apt_install() { apt_get install -y --no-install-recommends "$@"; }
apt_install_tolerant() {
  if ! apt_install "$@"; then
    warn "Bulk apt install failed; retrying packages one at a time."
    local p
    for p in "$@"; do apt_install "$p" >/dev/null 2>&1 || warn "apt: could not install '$p' (skipped)"; done
  fi
}

linux_system_packages() {
  if ! is_debian_family || ! have apt-get; then
    warn "Non-Debian distro ($DISTRO_NAME): skipping OS packages. Install build tools, git-lfs and your GPU driver with your package manager."
    return 0
  fi
  step "System packages (apt)"
  apt_get update
  [ "$WANT_SYSTEM_UPGRADE" = 1 ] && apt_get -y upgrade
  local pkgs="build-essential cmake ninja-build pkg-config git git-lfs curl wget ca-certificates
    gnupg unzip zip htop tmux jq ripgrep fd-find ffmpeg pciutils"
  [ "$PROFILE" != minimal ] && pkgs="$pkgs btop"
  case "$GPU_VENDOR" in nvidia|amd|intel) [ "$IS_WSL" = 0 ] && pkgs="$pkgs nvtop" ;; esac
  [ "$GPU_VENDOR" = nvidia ] && is_ubuntu_family && [ "$IS_WSL" = 0 ] && pkgs="$pkgs ubuntu-drivers-common"
  # shellcheck disable=SC2086
  apt_install_tolerant $pkgs
  run git lfs install --skip-repo >/dev/null || true
  note_installed "System packages (build tools, git-lfs, ffmpeg, monitoring tools)"
}

linux_nvidia_driver() {
  [ "$GPU_VENDOR" = nvidia ] || return 0
  if [ "$IS_WSL" = 1 ]; then
    if [ -z "$DRIVER_VERSION" ]; then
      warn "No NVIDIA driver visible inside WSL. Install/update the NVIDIA driver on Windows (NVIDIA App), then run 'aistrap update'."
    fi
    return 0
  fi
  if [ -n "$DRIVER_VERSION" ]; then
    ok "NVIDIA driver ${DRIVER_VERSION} is working (supports CUDA ${DRIVER_CUDA})."
    if [ -n "$DRIVER_CUDA" ] && [ "$(cuda_num "$DRIVER_CUDA")" -lt 1206 ]; then
      warn "Your NVIDIA driver is old (CUDA ${DRIVER_CUDA}). Newer PyTorch builds need 570+; consider 'sudo ubuntu-drivers install'."
    fi
    return 0
  fi
  [ "$WANT_DRIVER" = 1 ] || { warn "NVIDIA GPU found without a driver, and --no-driver was given."; return 0; }
  step "NVIDIA driver"
  if ! is_ubuntu_family || { ! have ubuntu-drivers && [ "$DRY_RUN" = 0 ]; }; then
    warn "Automatic driver install needs Ubuntu's 'ubuntu-drivers'. Install the driver from https://www.nvidia.com/drivers or your distro, then run 'aistrap update'."
    return 0
  fi
  if have mokutil && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    warn "Secure Boot is on: after reboot you'll see a blue 'Enroll MOK' screen. Choose 'Enroll MOK' and enter the password you set during install."
  fi
  info "Installing the recommended NVIDIA driver (open kernel modules on Turing and newer)."
  run $SUDO ubuntu-drivers install || run $SUDO ubuntu-drivers autoinstall
  NEED_REBOOT=1
  note_installed "NVIDIA driver (recommended by ubuntu-drivers)"
}

linux_cuda_toolkit() {
  [ "$WANT_CUDA_TOOLKIT" = 1 ] || return 0
  [ "$GPU_VENDOR" = nvidia ] || { warn "--cuda-toolkit ignored: no NVIDIA GPU."; return 0; }
  is_ubuntu_family || { warn "--cuda-toolkit is automated for Ubuntu only; see https://developer.nvidia.com/cuda-downloads"; return 0; }
  step "CUDA toolkit (nvcc)"
  local ver path arch url tmp
  ver="$(printf '%s' "$DISTRO_VERSION" | tr -d .)"
  [ "$DISTRO_ID" = ubuntu ] || ver="2404"
  arch="x86_64"; [ "$ARCH" = aarch64 ] && arch="sbsa"
  if [ "$IS_WSL" = 1 ]; then path="wsl-ubuntu/x86_64"; else path="ubuntu${ver}/${arch}"; fi
  url="https://developer.download.nvidia.com/compute/cuda/repos/${path}/cuda-keyring_1.1-1_all.deb"
  if ! curl -fsIL --max-time 20 "$url" >/dev/null 2>&1; then
    path="ubuntu2404/${arch}"; url="https://developer.download.nvidia.com/compute/cuda/repos/${path}/cuda-keyring_1.1-1_all.deb"
  fi
  tmp="$(mktemp -d)"
  run curl -fsSL "$url" -o "$tmp/cuda-keyring.deb"
  run $SUDO dpkg -i "$tmp/cuda-keyring.deb"
  apt_get update
  apt_install cuda-toolkit
  note_installed "CUDA toolkit (/usr/local/cuda)"
}

linux_docker() {
  [ "$WANT_DOCKER" = 1 ] || return 0
  if have docker; then
    ok "Docker already installed ($(docker --version 2>/dev/null | head -1))."
  elif ! is_debian_family; then
    warn "Docker: automatic install only on Debian/Ubuntu. See https://docs.docker.com/engine/install/"
    return 0
  else
    step "Docker Engine"
    local repo_os="debian" codename="$DISTRO_CODENAME"
    is_ubuntu_family && repo_os="ubuntu"
    if ! curl -fsIL --max-time 20 "https://download.docker.com/linux/${repo_os}/dists/${codename}/Release" >/dev/null 2>&1; then
      codename="$([ "$repo_os" = ubuntu ] && echo noble || echo bookworm)"
      warn "Docker has no repo for '${DISTRO_CODENAME}' yet; using '${codename}'."
    fi
    run $SUDO install -m 0755 -d /etc/apt/keyrings
    run $SUDO curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o /etc/apt/keyrings/docker.asc
    run $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    run_sh "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_os} ${codename} stable\" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null"
    apt_get update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    if [ -n "$SUDO" ]; then run $SUDO usermod -aG docker "$USER"; NEED_RELOGIN=1; fi
    note_installed "Docker Engine + Compose + Buildx"
  fi

  if [ "$GPU_VENDOR" = nvidia ]; then
    if have nvidia-ctk; then ok "NVIDIA Container Toolkit already installed."; return 0; fi
    is_debian_family || return 0
    step "NVIDIA Container Toolkit (GPU access inside containers)"
    run_sh "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    run_sh "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null"
    apt_get update
    apt_install nvidia-container-toolkit
    run $SUDO nvidia-ctk runtime configure --runtime=docker
    run $SUDO systemctl restart docker || warn "Could not restart Docker; restart it (or reboot) before using --gpus."
    note_installed "NVIDIA Container Toolkit (docker run --gpus all ...)"
  fi
}

linux_gpu_groups() {
  [ "$GPU_VENDOR" = amd ] || [ "$GPU_VENDOR" = intel ] || return 0
  [ -n "$SUDO" ] || return 0
  local g
  for g in render video; do
    if getent group "$g" >/dev/null 2>&1 && ! id -nG "$USER" | grep -qw "$g"; then
      run $SUDO usermod -aG "$g" "$USER"; NEED_RELOGIN=1
    fi
  done
}

linux_vscode() {
  [ "$WANT_VSCODE" = 1 ] || return 0
  have code && { ok "VS Code already installed."; return 0; }
  if have snap; then step "VS Code"; run $SUDO snap install code --classic; note_installed "VS Code"
  else warn "VS Code: install from https://code.visualstudio.com (no snap available)."; fi
}

# ----------------------------------------------------------------------------
# macOS system layer
# ----------------------------------------------------------------------------
BREW=""
macos_homebrew() {
  step "Homebrew + developer tools"
  BREW="$(command -v brew || true)"
  [ -n "$BREW" ] || { [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew; } || true
  if [ -z "$BREW" ]; then
    info "Installing Homebrew (this also installs Apple's Command Line Tools)."
    if [ "$DRY_RUN" = 0 ]; then sudo -v || die "Homebrew needs an administrator account."; fi
    run_sh 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    BREW=/opt/homebrew/bin/brew
  fi
  [ "$DRY_RUN" = 1 ] || eval "$("$BREW" shellenv)"
  local pkgs="git git-lfs cmake ninja pkg-config wget jq ripgrep fd tmux ffmpeg"
  [ "$PROFILE" != minimal ] && pkgs="$pkgs btop llama.cpp"
  [ "$WANT_OLLAMA" = 1 ] && pkgs="$pkgs ollama"
  # shellcheck disable=SC2086
  if ! run "$BREW" install $pkgs; then
    local p; for p in $pkgs; do run "$BREW" install "$p" || warn "brew: could not install '$p'"; done
  fi
  run git lfs install --skip-repo >/dev/null || true
  note_installed "Homebrew tools: $pkgs"
  if [ "$WANT_OLLAMA" = 1 ]; then
    run "$BREW" services start ollama || warn "Could not start the Ollama service; run 'ollama serve' manually."
    note_installed "Ollama (running as a background service)"
  fi
  if [ "$WANT_DOCKER" = 1 ]; then
    run "$BREW" install --cask docker-desktop || warn "Docker Desktop install failed."
    note_installed "Docker Desktop (open it once to finish setup)"
  fi
  if [ "$WANT_VSCODE" = 1 ]; then
    run "$BREW" install --cask visual-studio-code || warn "VS Code install failed."
    note_installed "VS Code"
  fi
}

# ----------------------------------------------------------------------------
# Python layer (uv-managed, one isolated env per framework)
# ----------------------------------------------------------------------------
UV="uv"
install_uv() {
  step "uv (Python + package manager)"
  export PATH="$HOME/.local/bin:$PATH"
  if have uv; then
    run uv self update >/dev/null 2>&1 || true
    ok "$(uv --version 2>/dev/null || echo uv) ready."
  else
    run_sh 'curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh'
    note_installed "uv"
  fi
  UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
}

env_python() { echo "$AISTRAP_HOME/envs/$1/bin/python"; }

make_env() { # make_env NAME   (re-uses a healthy env with the right Python version)
  local dir="$AISTRAP_HOME/envs/$1" py
  py="$(env_python "$1")"
  if [ -x "$py" ] && "$py" -c "import sys; sys.exit(0 if '%d.%d' % sys.version_info[:2] == '$PYVER' else 1)" 2>/dev/null; then
    ok "Re-using env '$1' ($("$py" -V 2>&1)); packages will be upgraded in place."
    return 0
  fi
  [ -d "$dir" ] && run rm -rf "$dir"
  run "$UV" venv "$dir" --python "$PYVER" --python-preference only-managed --prompt "$1"
}

uvpip() { local py; py="$(env_python "$1")"; shift; run "$UV" pip install --python "$py" "$@"; }

register_kernel() { # register_kernel ENV "Display Name"
  run "$(env_python "$1")" -m ipykernel install --user --name "aistrap-$1" --display-name "$2" >/dev/null
}

# Install a package list; if the resolver rejects the whole set, fall back to one
# package at a time so a single incompatible library can't sink the install.
uvpip_resilient() { # uvpip_resilient ENV "pkgs" [extra args...]
  local env="$1" pkgs="$2"; shift 2
  # shellcheck disable=SC2086
  if uvpip "$env" --upgrade "$@" $pkgs; then return 0; fi
  warn "Some packages in env '$env' failed to resolve together; installing one by one."
  local p
  for p in $pkgs; do uvpip "$env" --upgrade "$@" "$p" >/dev/null 2>&1 || warn "env '$env': could not install '$p' (skipped)"; done
}

install_ai_env() {
  step "Environment 'ai': PyTorch [$(backend_label)] + $PROFILE stack"
  make_env ai
  local state="$AISTRAP_HOME/state.env" prev_backend="" reinstall="" idx=""
  [ -f "$state" ] && prev_backend="$(sed -nE "s/^AISTRAP_BACKEND=['\"]?([^'\"]*)['\"]?$/\1/p" "$state" | head -1)"
  if [ -n "$prev_backend" ] && [ "$prev_backend" != "$BACKEND" ]; then
    info "Backend changed (${prev_backend} -> ${BACKEND}); reinstalling PyTorch."
    reinstall="--reinstall-package torch --reinstall-package torchvision"
  fi
  [ -n "$TORCH_INDEX_URL" ] && idx="--index-url $TORCH_INDEX_URL"
  # torchaudio is intentionally omitted: it is in maintenance mode and lags torch releases,
  # which would otherwise force an older torch.
  # shellcheck disable=SC2086
  uvpip ai --upgrade $reinstall torch torchvision $idx

  # Pin the exact torch we just chose so nothing below can swap it for a different build.
  local cons="$AISTRAP_HOME/envs/ai/aistrap-constraints.txt"
  if [ "$DRY_RUN" = 0 ]; then
    "$(env_python ai)" - > "$cons" <<'PY'
from importlib.metadata import version
for p in ("torch", "torchvision"):
    print(f"{p}=={version(p).split('+')[0]}")
PY
    ok "PyTorch $(head -1 "$cons" | cut -d= -f3) installed."
  fi
  uvpip_resilient ai "$(ai_env_packages)" --constraint "$cons"
  register_kernel ai "Python (ai: PyTorch)"
  note_installed "env 'ai': PyTorch [$(backend_label)] + $(ai_env_packages | wc -w | tr -d ' ') libraries"
}

install_jax_env() {
  step "Environment 'jax': $(jax_package)"
  make_env jax || return 1
  uvpip jax --upgrade "$(jax_package)" flax optax orbax-checkpoint chex numpy matplotlib ipykernel || return 1
  register_kernel jax "Python (jax)" || return 1
  [ "$GPU_VENDOR" = apple ] && info "JAX runs on CPU on macOS; MLX (in the 'ai' env) is the Apple-GPU-native option."
  note_installed "env 'jax': JAX + Flax + Optax"
}

install_tf_env() {
  step "Environment 'tf': $(tf_package)"
  make_env tf || return 1
  uvpip tf --upgrade "$(tf_package)" keras numpy matplotlib ipykernel || return 1
  register_kernel tf "Python (tf: TensorFlow)" || return 1
  note_installed "env 'tf': TensorFlow + Keras 3"
}

install_uv_tools() {
  if [ "$PROFILE" != minimal ]; then
    step "Command-line tools (isolated with uv tool)"
    run "$UV" tool install --upgrade --python "$PYVER" "huggingface_hub[cli]" || warn "Could not install the hf CLI."
    note_installed "hf CLI (download models/datasets: hf download <repo>)"
  fi
  if [ "$WANT_VLLM" = 1 ]; then
    info "Installing vLLM (large download)..."
    if run "$UV" tool install --upgrade --python "$PYVER" vllm; then
      note_installed "vLLM ('vllm serve <model>' for an OpenAI-compatible API)"
    else
      warn "vLLM install failed; see the log. Everything else is unaffected."
    fi
  fi
}

# ----------------------------------------------------------------------------
# Apps
# ----------------------------------------------------------------------------
install_ollama_linux() {
  [ "$WANT_OLLAMA" = 1 ] || return 0
  step "Ollama (local LLM runtime)"
  if have ollama; then ok "Ollama already installed ($(ollama --version 2>/dev/null | tail -1))."
  else
    run_sh 'curl -fsSL https://ollama.com/install.sh | sh' || { warn "Ollama install failed."; return 0; }
    note_installed "Ollama (ollama run <model>)"
  fi
}

install_claude_code() {
  [ "$WANT_CLAUDE" = 1 ] || return 0
  step "Claude Code"
  if have claude; then ok "Claude Code already installed."; return 0; fi
  run_sh 'curl -fsSL https://claude.ai/install.sh | bash' || { warn "Claude Code install failed."; return 0; }
  note_installed "Claude Code ('claude' in any project folder)"
}

# ----------------------------------------------------------------------------
# aistrap helper, shell integration, state
# ----------------------------------------------------------------------------
write_helper() {
  local dest="$AISTRAP_HOME/bin/aistrap"
  if [ "$DRY_RUN" = 1 ]; then printf '%s   [dry-run] write %s and link it into ~/.local/bin%s\n' "$C_DIM" "$dest" "$C_RESET"; return 0; fi
  mkdir -p "$AISTRAP_HOME/bin" "$HOME/.local/bin"
  cat > "$dest" <<'HELPER'
#!/usr/bin/env bash
# aistrap - AIStrap helper. Generated by install.sh; safe to delete (use 'aistrap uninstall').
set -euo pipefail
AISTRAP_HOME="${AISTRAP_HOME:-$HOME/.aistrap}"
# shellcheck disable=SC1091
[ -f "$AISTRAP_HOME/state.env" ] && . "$AISTRAP_HOME/state.env"
AISTRAP_REPO_RAW="${AISTRAP_REPO_RAW:-https://raw.githubusercontent.com/brandonjabr/aistrap/master}"

envs() { ls -1 "$AISTRAP_HOME/envs" 2>/dev/null; }
env_dir() { [ -x "$AISTRAP_HOME/envs/$1/bin/python" ] || { echo "No env '$1'. Available: $(envs | tr '\n' ' ')" >&2; exit 1; }; echo "$AISTRAP_HOME/envs/$1"; }

usage() {
  cat <<EOF
aistrap - AIStrap ${AISTRAP_VERSION:-2} helper

  aistrap doctor [env...]      health check: GPU, frameworks, quick benchmark
  aistrap lab [args]           start JupyterLab (all env kernels available)
  aistrap shell [env]          open a shell with an env active (default: ai)
  aistrap run ENV CMD...       run a command inside an env
  aistrap add [-e ENV] PKG...  install extra packages (keeps the PyTorch build pinned)
  aistrap envs                 list environments and framework versions
  aistrap update               re-run the installer: newest drivers/builds/packages
  aistrap uninstall [-y]       remove envs, helper and shell config
  aistrap version
EOF
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
  doctor)
    targets="$*"; [ -n "$targets" ] || targets="$(envs)"
    rc=0
    for e in $targets; do
      "$(env_dir "$e")/bin/python" "$AISTRAP_HOME/doctor.py" --env "$e" --expect "${AISTRAP_ACCEL:-}" || rc=1
    done
    exit $rc ;;
  lab|jupyter) exec "$(env_dir ai)/bin/jupyter" lab "$@" ;;
  shell)
    d="$(env_dir "${1:-ai}")"
    export VIRTUAL_ENV="$d" PATH="$d/bin:$PATH"
    echo "Entered env '${1:-ai}' ($("$d/bin/python" -V)). Type 'exit' to leave."
    exec "${SHELL:-/bin/bash}" -i ;;
  run)
    [ $# -ge 2 ] || { echo "usage: aistrap run ENV CMD..." >&2; exit 2; }
    d="$(env_dir "$1")"; shift
    export VIRTUAL_ENV="$d" PATH="$d/bin:$PATH"
    exec "$@" ;;
  add)
    e=ai; if [ "${1:-}" = "-e" ] || [ "${1:-}" = "--env" ]; then e="$2"; shift 2; fi
    d="$(env_dir "$e")"; extra=""
    [ -f "$d/aistrap-constraints.txt" ] && extra="--constraint $d/aistrap-constraints.txt"
    # shellcheck disable=SC2086
    exec uv pip install --python "$d/bin/python" $extra "$@" ;;
  envs|list)
    for e in $(envs); do
      printf '%-6s ' "$e"
      "$AISTRAP_HOME/envs/$e/bin/python" - <<'PY' 2>/dev/null || echo "(broken)"
import sys
from importlib.metadata import version
out = [f"Python {sys.version.split()[0]}"]
for p in ("torch", "jax", "tensorflow", "mlx", "transformers"):
    try: out.append(f"{p} {version(p)}")
    except Exception: pass
print(", ".join(out))
PY
    done ;;
  update|upgrade)
    tmp="$(mktemp)"
    if curl -fsSL "$AISTRAP_REPO_RAW/install.sh" -o "$tmp"; then src="$tmp"; else
      echo "Could not download the latest installer; using the cached copy." >&2; src="$AISTRAP_HOME/install.sh"; fi
    eval "set -- ${AISTRAP_ARGS:-} $*"
    exec bash "$src" "$@" --yes ;;
  uninstall)
    a=""; case "${1:-}" in -y|--yes) a=y ;; esac
    if [ -z "$a" ]; then
      printf 'Remove %s (all envs), the aistrap helper, Jupyter kernels and shell config? [y/N] ' "$AISTRAP_HOME"
      if [ -t 0 ]; then read -r a || a=""; else read -r a </dev/tty 2>/dev/null || a=""; fi
    fi
    case "$a" in y|Y|yes) ;; *) echo "Cancelled."; exit 0 ;; esac
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rc" ] || continue
      awk '/^# >>> aistrap >>>/{s=1} !s{print} /^# <<< aistrap <<</{s=0}' "$rc" > "$rc.aistrap.tmp" && cat "$rc.aistrap.tmp" > "$rc" && rm -f "$rc.aistrap.tmp"
    done
    rm -rf "$HOME/.local/share/jupyter/kernels"/aistrap-* "$HOME/Library/Jupyter/kernels"/aistrap-* 2>/dev/null || true
    if command -v uv >/dev/null 2>&1; then uv tool uninstall vllm >/dev/null 2>&1 || true; uv tool uninstall huggingface-hub >/dev/null 2>&1 || true; fi
    rm -f "$HOME/.local/bin/aistrap"
    rm -rf "$AISTRAP_HOME"
    echo "Removed. Left in place: uv, system packages, GPU driver, Docker, Ollama, Homebrew (remove those with your package manager if you want)." ;;
  version|--version|-V) echo "AIStrap ${AISTRAP_VERSION:-?} (backend ${AISTRAP_BACKEND:-?}, profile ${AISTRAP_PROFILE:-?})" ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command '$cmd'"; usage; exit 2 ;;
esac
HELPER
  chmod +x "$dest"
  ln -sf "$dest" "$HOME/.local/bin/aistrap"
}

write_state() {
  [ "$DRY_RUN" = 1 ] && return 0
  {
    printf 'AISTRAP_VERSION=%q\n' "$AISTRAP_VERSION"
    printf 'AISTRAP_PROFILE=%q\n' "$PROFILE"
    printf 'AISTRAP_BACKEND=%q\n' "$BACKEND"
    printf 'AISTRAP_ACCEL=%q\n' "$(expected_accel)"
    printf 'AISTRAP_PYTHON=%q\n' "$PYVER"
    printf 'AISTRAP_ARGS=%q\n' "$SAVED_ARGS"
    printf 'AISTRAP_REPO_RAW=%q\n' "$AISTRAP_REPO_RAW"
    printf 'AISTRAP_INSTALLED_AT=%q\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$AISTRAP_HOME/state.env"
}

strip_rc_block() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '/^# >>> aistrap >>>/{s=1} !s{print} /^# <<< aistrap <<</{s=0}' "$f" > "$f.aistrap.tmp" && cat "$f.aistrap.tmp" > "$f" && rm -f "$f.aistrap.tmp"
}

write_shell_config() {
  [ "$WANT_SHELL_CONFIG" = 1 ] || return 0
  local home_ref rcs="" rc
  home_ref="$(printf '%s' "$AISTRAP_HOME" | sed "s|^$HOME|\$HOME|")"
  [ -f "$HOME/.bashrc" ] || [ "$OS" = linux ] && rcs="$rcs $HOME/.bashrc"
  [ -f "$HOME/.zshrc" ] || [ "$OS" = macos ] && rcs="$rcs $HOME/.zshrc"
  for rc in $rcs; do
    if [ "$DRY_RUN" = 1 ]; then printf '%s   [dry-run] add aistrap block to %s%s\n' "$C_DIM" "$rc" "$C_RESET"; continue; fi
    strip_rc_block "$rc"
    {
      echo "# >>> aistrap >>>  (managed by AIStrap; 'aistrap uninstall' removes it)"
      echo "export AISTRAP_HOME=\"${home_ref}\""
      echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
      [ "$OS" = macos ] && echo '[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"'
      [ "$WANT_CUDA_TOOLKIT" = 1 ] && echo '[ -d /usr/local/cuda/bin ] && export PATH="/usr/local/cuda/bin:$PATH"'
      echo 'alias ai='"'"'. "$AISTRAP_HOME/envs/ai/bin/activate"'"'"
      echo "# <<< aistrap <<<"
    } >> "$rc"
  done
}

install_helpers() {
  step "aistrap helper, health check and shell integration"
  [ "$DRY_RUN" = 1 ] || mkdir -p "$AISTRAP_HOME"
  fetch_asset doctor.py "$AISTRAP_HOME/doctor.py"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install.sh" ]; then
    run cp "$SCRIPT_DIR/install.sh" "$AISTRAP_HOME/install.sh"
  else
    run curl -fsSL "$AISTRAP_REPO_RAW/install.sh" -o "$AISTRAP_HOME/install.sh" || true
  fi
  write_helper
  write_state
  write_shell_config
}

run_doctor() {
  [ "$DRY_RUN" = 1 ] && return 0
  step "Health check"
  local e
  for e in ai jax tf; do
    [ -x "$(env_python "$e")" ] || continue
    "$(env_python "$e")" "$AISTRAP_HOME/doctor.py" --env "$e" --expect "$(expected_accel)" \
      || warn "Health check for env '$e' reported problems (see above)."
  done
}

final_summary() {
  printf '\n%s============================================================%s\n' "$C_BOLD" "$C_RESET"
  if [ "$DRY_RUN" = 1 ]; then
    printf '%sDry run complete.%s Nothing was changed. Re-run without --dry-run to install.\n' "$C_BOLD" "$C_RESET"
    [ -n "$WARNINGS" ] && printf '\n%sNotes:%s\n%s' "$C_YELLOW" "$C_RESET" "$WARNINGS"
    return 0
  fi
  printf '%s%sAIStrap %s: your AI workstation is ready.%s\n\n' "$C_BOLD" "$C_GREEN" "$AISTRAP_VERSION" "$C_RESET"
  [ -n "$INSTALLED" ] && printf '%sInstalled / updated%s\n%s\n' "$C_BOLD" "$C_RESET" "$INSTALLED"
  [ -n "$WARNINGS" ] && printf '%sNeeds your attention%s\n%s\n' "$C_YELLOW" "$C_RESET" "$WARNINGS"
  printf '%sNext steps%s\n' "$C_BOLD" "$C_RESET"
  [ "$NEED_REBOOT" = 1 ] && printf '  %s* Reboot now to load the NVIDIA driver:  sudo reboot%s\n    then run: aistrap update   (re-detects your GPU and switches to the best PyTorch build)\n' "$C_YELLOW" "$C_RESET"
  [ "$NEED_RELOGIN" = 1 ] && [ "$NEED_REBOOT" = 0 ] && echo "  * Log out and back in so Docker / GPU group membership applies."
  echo "  * Open a new terminal (or: source ~/.$(basename "${SHELL:-bash}")rc)"
  echo "  * ai                      activate the main env (python, jupyter, hf, ...)"
  echo "  * aistrap lab                 JupyterLab with every env as a kernel"
  echo "  * aistrap doctor              re-run the GPU / framework health check"
  [ "$WANT_OLLAMA" = 1 ] && echo "  * ollama run gemma3       chat with a local LLM (any model from ollama.com/library)"
  [ "$WANT_VLLM" = 1 ] && echo "  * vllm serve Qwen/Qwen3-8B   OpenAI-compatible server on :8000"
  echo "  * aistrap update              upgrade everything to the newest compatible versions"
  printf '\nLog: %s\n' "$LOG_FILE"
}

# ----------------------------------------------------------------------------
main() {
  set -f   # no filename globbing: package specs like huggingface_hub[cli] must stay literal
  parse_args "$@"
  local self="${BASH_SOURCE[0]:-}"
  if [ -n "$self" ] && [ -f "$self" ]; then SCRIPT_DIR="$(cd "$(dirname "$self")" && pwd)"; fi

  case "$ACTION" in
    doctor)    [ -x "$HOME/.local/bin/aistrap" ] || die "AIStrap is not installed yet."; exec "$HOME/.local/bin/aistrap" doctor ;;
    uninstall) [ -x "$HOME/.local/bin/aistrap" ] || die "AIStrap is not installed."; exec "$HOME/.local/bin/aistrap" uninstall ;;
  esac

  printf '%s\n' "${C_BOLD}AIStrap ${AISTRAP_VERSION}${C_RESET} ${C_DIM}- modern AI/ML workstation setup${C_RESET}"
  [ "$DRY_RUN" = 1 ] && printf '%s(dry run: nothing will be changed)%s\n' "$C_YELLOW" "$C_RESET"
  have curl || die "curl is required. Install it first (e.g. sudo apt install -y curl)."

  detect_platform
  detect_gpu
  apply_profile_defaults
  select_backend
  show_plan
  confirm
  setup_logging

  if [ "$WANT_SYSTEM" = 1 ]; then
    if [ "$OS" = linux ]; then
      setup_sudo
      linux_system_packages
      linux_nvidia_driver
      linux_cuda_toolkit
      linux_docker
      linux_gpu_groups
      linux_vscode
    else
      macos_homebrew
    fi
  fi

  install_uv
  install_ai_env
  if [ "$WANT_JAX" = 1 ]; then install_jax_env || warn "JAX env failed; the rest of the install is unaffected."; fi
  if [ "$WANT_TF" = 1 ]; then install_tf_env || warn "TensorFlow env failed; the rest of the install is unaffected."; fi
  install_uv_tools
  [ "$OS" = linux ] && install_ollama_linux
  install_claude_code
  install_helpers
  run_doctor
  final_summary
}

# Everything runs from here, so a partially downloaded script can never execute.
[ "${AISTRAP_SOURCE_ONLY:-0}" = 1 ] || main "$@"
