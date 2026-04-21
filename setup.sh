#!/usr/bin/env bash
# =============================================================================
# OCBrain — Production Installer (Auto-Resume + Crash-Proof Dependencies)
# =============================================================================

set -uo pipefail
set -o errtrace

# ── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GRN}✓${NC} $*"; }
warn()  { echo -e "${YLW}⚠${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*"; }
info()  { echo -e "${BLU}→${NC} $*"; }
step()  { echo -e "\n${BOLD}$*${NC}"; }

# ── STATE / LOGGING ──────────────────────────────────────────────────────────
STATE_FILE=".ocbrain_install_state"
LOG_FILE=".ocbrain_install.log"

touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo ""; fail "Crash at line $LINENO"; exit 1' ERR

mark_done() { echo "$1" >> "$STATE_FILE"; }
is_done() { grep -Fxq "$1" "$STATE_FILE" 2>/dev/null; }

run_step() {
    local id="$1"
    local name="$2"
    shift 2

    if is_done "$id"; then
        ok "[RESUME] $name already done"
        return 0
    fi

    step "$name"
    if "$@"; then
        mark_done "$id"
        ok "$name completed"
    else
        fail "$name failed"
        exit 1
    fi
}

# ── RESET OPTION ─────────────────────────────────────────────────────────────
if [[ "${RESET_INSTALL:-}" == "1" ]]; then
    rm -f "$STATE_FILE"
    warn "State reset"
fi

# ── DISTRO DETECTION ─────────────────────────────────────────────────────────
detect_distro() {
    . /etc/os-release 2>/dev/null || true

    if echo "$ID $ID_LIKE" | grep -qiE "ubuntu|debian"; then
        PKG="apt"
    elif echo "$ID $ID_LIKE" | grep -qiE "fedora|rhel"; then
        PKG="dnf"
    elif echo "$ID $ID_LIKE" | grep -qiE "arch"; then
        PKG="pacman"
    else
        PKG="unknown"
    fi

    ok "Distro: ${ID:-unknown} | Package manager: $PKG"
}

sys_install() {
    case "$PKG" in
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y "$@" || true
            sudo apt-get install -f -y || true
            ;;
        dnf) sudo dnf install -y "$@" || true ;;
        pacman) sudo pacman -S --noconfirm "$@" || true ;;
        *) warn "Unknown package manager"; return 1 ;;
    esac
}

# ── ROBUST PIP INSTALL ───────────────────────────────────────────────────────
pip_install() {
    local desc="$1"; shift
    local tries=3

    for ((i=1;i<=tries;i++)); do
        [[ $i -gt 1 ]] && warn "Retry $i/$tries: $desc"

        if "$PIP" install \
            --prefer-binary \
            --no-cache-dir \
            --timeout 120 \
            --retries 5 \
            "$@" ; then
            return 0
        fi

        info "Fixing build tools..."
        "$PIP" install --upgrade pip setuptools wheel cython numpy >/dev/null 2>&1 || true
        sleep 2
    done

    fail "Failed: $desc"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEPS
# ─────────────────────────────────────────────────────────────────────────────

step_0() { detect_distro; }

step_1() {
    info "Installing system dependencies..."
    sys_install build-essential python3 python3-venv python3-dev \
        git curl libssl-dev libffi-dev
}

step_2() {
    if command -v cargo &>/dev/null; then
        ok "Rust already installed"
        return 0
    fi

    info "Installing Rust..."
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    source "$HOME/.cargo/env" || true
    echo 'source $HOME/.cargo/env' >> "$HOME/.bashrc" 2>/dev/null || true
}

step_3() {
    for py in python3.12 python3.11 python3; do
        if command -v "$py" &>/dev/null; then
            VER=$("$py" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            MAJ=${VER%%.*}; MIN=${VER##*.}
            if [[ "$MAJ" -gt 3 || ( "$MAJ" -eq 3 && "$MIN" -ge 11 ) ]]; then
                PYTHON_BIN="$py"
                ok "Using Python $VER"
                return 0
            fi
        fi
    done

    fail "Python 3.11+ required"
    exit 1
}

step_4() {
    [[ -d .venv ]] && rm -rf .venv
    "$PYTHON_BIN" -m venv .venv
    source .venv/bin/activate

    PIP=".venv/bin/pip"
    PYTHON=".venv/bin/python"

    ok "Venv ready: $($PYTHON --version)"
}

step_5() {
    "$PIP" install --upgrade pip setuptools wheel cython numpy
    ok "pip ready: $($PIP --version)"
}

# 🔥 PRE-FIX (CRITICAL)
step_pre_fix() {
    export PIP_NO_CACHE_DIR=1
    export PIP_DEFAULT_TIMEOUT=120
    export TOKENIZERS_PARALLELISM=false
    export OMP_NUM_THREADS=1
    export CHROMADB_SETTINGS='{"chroma_db_impl":"duckdb+parquet"}'

    ok "Pre-install environment hardened"
}

# ✅ SAFE CORE INSTALL
step_6() {
    SAFE_PKGS=(
        "fastapi==0.111.0"
        "uvicorn[standard]==0.30.1"
        "httpx==0.27.0"
        "pydantic==2.7.1"
        "rich==13.7.1"
        "click==8.1.7"
        "requests==2.32.3"
        "aiofiles==23.2.1"
        "PyYAML==6.0.1"
    )

    for pkg in "${SAFE_PKGS[@]}"; do
        info "Installing $pkg"
        pip_install "$pkg" "$pkg" || return 1
    done
}

# ✅ HEAVY DEPENDENCIES (ISOLATED)
step_7() {
    info "Installing chromadb..."
    pip_install "chromadb" "chromadb==0.5.0" || warn "chromadb failed"

    info "Installing torch (CPU)..."
    pip_install "torch" \
        torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu \
        || return 1

    info "Installing sentence-transformers..."
    pip_install "sentence-transformers" "sentence-transformers==3.0.1" \
        || warn "sentence-transformers failed"
}

step_8() {
    pip_install "project" -e .
}

step_9() {
    "$PYTHON" -m spacy download en_core_web_sm || \
    pip_install "spacy model" \
    https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.7.1/en_core_web_sm-3.7.1-py3-none-any.whl \
    || warn "spacy failed"
}

step_10() {
    mkdir -p data modules core
}

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTION (AUTO-RESUME)
# ─────────────────────────────────────────────────────────────────────────────

run_step step_0 "Detect environment" step_0
run_step step_1 "System dependencies" step_1
run_step step_2 "Rust install" step_2
run_step step_3 "Python check" step_3
run_step step_4 "Virtualenv" step_4
run_step step_5 "pip setup" step_5
run_step step_pre_fix "Pre-install fixes" step_pre_fix
run_step step_6 "Core dependencies" step_6
run_step step_7 "Heavy dependencies" step_7
run_step step_8 "Project install" step_8
run_step step_9 "NLP model" step_9
run_step step_10 "Finalize" step_10

# ── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo "======================================"
echo "  OCBrain installation complete"
echo "======================================"
echo ""
echo "Run:"
echo "  source .venv/bin/activate"
echo "  python main.py"
