#!/usr/bin/env bash
# =============================================================================
#  OCBrain — Self-Healing Setup Script
#  Handles 16 known Linux failure modes automatically.
#  Usage:
#    bash setup.sh                    # interactive
#    TRAIN=y VOICE=n bash setup.sh    # non-interactive / CI
# =============================================================================

set -uo pipefail  # Note: no -e — we handle errors manually for self-healing

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GRN}  ✓${NC}  $*"; }
warn()  { echo -e "${YLW}  ⚠${NC}  $*"; }
info()  { echo -e "${BLU}  →${NC}  $*"; }
fix()   { echo -e "${CYN}  ⚙${NC}  $*"; }
fail()  { echo -e "${RED}  ✗${NC}  $*"; }
die()   { echo -e "\n${RED}${BOLD}  FATAL:${NC} $*\n"; exit 1; }
step()  { echo -e "\n${BOLD}$*${NC}"; }

banner() {
cat << 'BANNER'

  ╔══════════════════════════════════════════════╗
  ║        OCBrain — Self-Healing Setup          ║
  ║   Automatically fixes common Linux issues    ║
  ╚══════════════════════════════════════════════╝

BANNER
}

# ── Detect Linux distro ───────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
        DISTRO_VER="${VERSION_ID:-0}"
    else
        DISTRO_ID="unknown"
        DISTRO_LIKE=""
        DISTRO_VER="0"
    fi

    if echo "$DISTRO_ID $DISTRO_LIKE" | grep -qiE "ubuntu|debian|mint|pop|elementary|kali|raspbian"; then
        PKG_MANAGER="apt"
    elif echo "$DISTRO_ID $DISTRO_LIKE" | grep -qiE "fedora|rhel|centos|rocky|alma"; then
        PKG_MANAGER="dnf"
    elif echo "$DISTRO_ID $DISTRO_LIKE" | grep -qiE "arch|manjaro|endeavour"; then
        PKG_MANAGER="pacman"
    elif echo "$DISTRO_ID $DISTRO_LIKE" | grep -qiE "opensuse|suse"; then
        PKG_MANAGER="zypper"
    else
        PKG_MANAGER="unknown"
    fi

    ok "Distro: $DISTRO_ID $DISTRO_VER | Package manager: $PKG_MANAGER"
}

# ── Helper: install system packages ──────────────────────────────────────────
sys_install() {
    local pkgs=("$@")
    info "Installing system packages: ${pkgs[*]}"
    case "$PKG_MANAGER" in
        apt)    sudo apt-get install -y --no-install-recommends "${pkgs[@]}" ;;
        dnf)    sudo dnf install -y "${pkgs[@]}" ;;
        pacman) sudo pacman -S --noconfirm "${pkgs[@]}" ;;
        zypper) sudo zypper install -y "${pkgs[@]}" ;;
        *)      warn "Unknown package manager — skipping system package install"
                return 1 ;;
    esac
}

# ── Helper: pip install with retry ───────────────────────────────────────────
pip_install() {
    local desc="$1"; shift
    local max_retries=3
    local attempt=0

    while (( attempt < max_retries )); do
        (( attempt++ ))
        if [[ $attempt -gt 1 ]]; then
            warn "Retry $attempt/$max_retries for: $desc"
            sleep 3
        fi
        if "$PIP" install --timeout 120 "$@" 2>/tmp/ocbrain_pip.err; then
            return 0
        fi
    done

    fail "Failed to install: $desc"
    cat /tmp/ocbrain_pip.err
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
banner

# ── Step 0: OS check ─────────────────────────────────────────────────────────
step "[ 0 / 11 ]  Detecting environment"
OSTYPE_DETECTED="${OSTYPE:-linux}"
if [[ "$OSTYPE_DETECTED" == "darwin"* ]]; then
    die "This setup script is for Linux. On macOS run: bash setup.sh (it will work, but is not optimised)"
fi
detect_distro

# ── Step 1: System dependencies ──────────────────────────────────────────────
step "[ 1 / 11 ]  Installing system build dependencies"
info "This ensures compilers and headers are available for packages that build from source."

MISSING_SYS=()

command -v gcc    &>/dev/null || MISSING_SYS+=(gcc)
command -v make   &>/dev/null || MISSING_SYS+=( make)
command -v cargo  &>/dev/null || MISSING_SYS+=(_rust)  # sentinel, handled below

# Check headers
python3 -c "import ctypes.util; ctypes.util.find_library('ssl')" &>/dev/null \
    || MISSING_SYS+=(_ssl_headers)

if [[ ${#MISSING_SYS[@]} -gt 0 ]]; then
    fix "Installing missing build tools..."
    case "$PKG_MANAGER" in
        apt)
            sudo apt-get update -qq
            sys_install \
                build-essential \
                python3-dev \
                libssl-dev \
                libffi-dev \
                libsqlite3-dev \
                zlib1g-dev \
                git \
                curl \
                ca-certificates || warn "Some system packages failed — continuing anyway"
            ;;
        dnf)
            sys_install \
                gcc \
                gcc-c++ \
                python3-devel \
                openssl-devel \
                libffi-devel \
                sqlite-devel \
                zlib-devel \
                git \
                curl || warn "Some system packages failed — continuing anyway"
            ;;
        pacman)
            sys_install \
                base-devel \
                python \
                openssl \
                libffi \
                sqlite \
                zlib \
                git \
                curl || warn "Some system packages failed — continuing anyway"
            ;;
        zypper)
            sys_install \
                gcc \
                gcc-c++ \
                python3-devel \
                libopenssl-devel \
                libffi-devel \
                sqlite3-devel \
                zlib-devel \
                git \
                curl || warn "Some system packages failed — continuing anyway"
            ;;
    esac
else
    ok "Build tools already present"
fi

# ── Step 2: Rust/cargo (needed by tokenizers) ─────────────────────────────────
step "[ 2 / 11 ]  Checking Rust / cargo"
if ! command -v cargo &>/dev/null; then
    fix "Rust not found — installing via rustup (needed for tokenizers package)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path 2>/tmp/ocbrain_rust.err
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env" 2>/dev/null || true
    if command -v cargo &>/dev/null; then
        ok "Rust installed: $(rustc --version)"
    else
        warn "Rust install failed — tokenizers will use pre-built wheel instead"
        warn "If install fails later, run: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    fi
else
    ok "Rust: $(cargo --version)"
fi

# ── Step 3: Python 3.11+ ──────────────────────────────────────────────────────
step "[ 3 / 11 ]  Checking Python version"

# Find the best available python3 binary
PYTHON_BIN=""
for py in python3.13 python3.12 python3.11 python3; do
    if command -v "$py" &>/dev/null; then
        VER=$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        MAJ=$(echo "$VER" | cut -d. -f1)
        MIN=$(echo "$VER" | cut -d. -f2)
        if [[ "$MAJ" -ge 3 && "$MIN" -ge 11 ]]; then
            PYTHON_BIN="$py"
            ok "Found Python $VER at $(command -v $py)"
            break
        fi
    fi
done

if [[ -z "$PYTHON_BIN" ]]; then
    fix "Python 3.11+ not found — attempting automatic installation..."

    case "$PKG_MANAGER" in
        apt)
            # Try standard repo first
            if apt-cache show python3.11 &>/dev/null 2>&1; then
                sys_install python3.11 python3.11-venv python3.11-dev || true
            else
                # Add deadsnakes PPA (Ubuntu) or backports (Debian)
                if [[ "$DISTRO_ID" == "ubuntu" ]]; then
                    fix "Adding deadsnakes PPA for Python 3.11..."
                    sys_install software-properties-common || true
                    sudo add-apt-repository -y ppa:deadsnakes/ppa || true
                    sudo apt-get update -qq
                    sys_install python3.11 python3.11-venv python3.11-dev || true
                elif [[ "$DISTRO_ID" == "debian" ]]; then
                    fix "Installing Python 3.11 from backports..."
                    echo "deb http://deb.debian.org/debian bookworm-backports main" \
                        | sudo tee /etc/apt/sources.list.d/backports.list
                    sudo apt-get update -qq
                    sudo apt-get install -y -t bookworm-backports python3.11 python3.11-venv python3.11-dev || true
                fi
            fi
            ;;
        dnf)
            sys_install python3.11 python3.11-devel || true
            ;;
        pacman)
            sys_install python || true   # Arch ships latest Python
            ;;
    esac

    # Check again after install attempt
    for py in python3.13 python3.12 python3.11 python3; do
        if command -v "$py" &>/dev/null; then
            VER=$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
            MAJ=$(echo "$VER" | cut -d. -f1)
            MIN=$(echo "$VER" | cut -d. -f2)
            if [[ "$MAJ" -ge 3 && "$MIN" -ge 11 ]]; then
                PYTHON_BIN="$py"
                ok "Python $VER installed and ready"
                break
            fi
        fi
    done

    # Last resort: pyenv
    if [[ -z "$PYTHON_BIN" ]]; then
        fix "Trying pyenv as last resort..."
        if ! command -v pyenv &>/dev/null; then
            curl -fsSL https://pyenv.run | bash || true
            export PYENV_ROOT="$HOME/.pyenv"
            export PATH="$PYENV_ROOT/bin:$PATH"
            eval "$(pyenv init -)" 2>/dev/null || true
        fi
        if command -v pyenv &>/dev/null; then
            pyenv install 3.11.9 --skip-existing 2>/tmp/ocbrain_pyenv.err || true
            pyenv local 3.11.9 2>/dev/null || true
            PYTHON_BIN="$HOME/.pyenv/versions/3.11.9/bin/python3.11"
            [[ -x "$PYTHON_BIN" ]] && ok "Python 3.11 installed via pyenv" \
                || PYTHON_BIN=""
        fi
    fi

    if [[ -z "$PYTHON_BIN" ]]; then
        die "Could not install Python 3.11+. Please install it manually:\n\
  Ubuntu/Debian: sudo apt install python3.11 python3.11-venv\n\
  Fedora:        sudo dnf install python3.11\n\
  Any distro:    https://pyenv.run"
    fi
fi

# ── Step 4: python3-venv ─────────────────────────────────────────────────────
step "[ 4 / 11 ]  Ensuring python3-venv is available"

if ! "$PYTHON_BIN" -c "import venv" &>/dev/null; then
    fix "venv module missing — installing..."
    case "$PKG_MANAGER" in
        apt)
            PY_VER=$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            sys_install "python${PY_VER}-venv" || sys_install python3-venv || true
            ;;
        dnf) sys_install python3-virtualenv || true ;;
        pacman) fix "venv should be included with python on Arch" ;;
    esac

    if ! "$PYTHON_BIN" -c "import venv" &>/dev/null; then
        die "python3-venv unavailable. Run:\n  sudo apt install python3.11-venv\nthen re-run setup.sh"
    fi
fi
ok "python3-venv available"

# ── Step 5: Virtual environment ───────────────────────────────────────────────
step "[ 5 / 11 ]  Setting up virtual environment"

if [[ -d ".venv" ]]; then
    # Verify the existing venv uses the right Python version
    VENV_PY_VER=$(.venv/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    VENV_MAJ=$(echo "$VENV_PY_VER" | cut -d. -f1)
    VENV_MIN=$(echo "$VENV_PY_VER" | cut -d. -f2)
    if [[ "$VENV_MAJ" -lt 3 || ( "$VENV_MAJ" -eq 3 && "$VENV_MIN" -lt 11 ) ]]; then
        warn "Existing .venv uses Python $VENV_PY_VER (< 3.11) — recreating..."
        rm -rf .venv
    else
        ok "Existing .venv is Python $VENV_PY_VER ✓"
    fi
fi

if [[ ! -d ".venv" ]]; then
    info "Creating virtual environment with $PYTHON_BIN..."
    "$PYTHON_BIN" -m venv .venv 2>/tmp/ocbrain_venv.err \
        || die "Virtual environment creation failed.\n$(cat /tmp/ocbrain_venv.err)"
    ok "Virtual environment created"
fi

# Activate
# shellcheck disable=SC1091
source .venv/bin/activate
PIP=".venv/bin/pip"
PYTHON=".venv/bin/python"
ok "Virtual environment activated (Python $($PYTHON --version))"

# ── Step 6: Upgrade pip / wheel / setuptools ─────────────────────────────────
step "[ 6 / 11 ]  Upgrading pip, wheel, and setuptools"
# Must do this before everything else — many packages fail to build without
# an up-to-date wheel and setuptools inside the venv.

info "Upgrading pip..."
"$PYTHON" -m pip install --upgrade pip setuptools wheel --timeout 120 --quiet \
    2>/tmp/ocbrain_pip_upgrade.err \
    || { warn "pip upgrade had warnings (continuing)"; cat /tmp/ocbrain_pip_upgrade.err; }
ok "pip $(pip --version | cut -d' ' -f2) | setuptools | wheel — ready"

# ── Step 7: Check sqlite3 version (needed by chromadb) ───────────────────────
step "[ 7 / 11 ]  Checking sqlite3 compatibility"

SQLITE_VER=$("$PYTHON" -c "import sqlite3; print(sqlite3.sqlite_version)" 2>/dev/null || echo "0.0.0")
SQLITE_MAJ=$(echo "$SQLITE_VER" | cut -d. -f1)
SQLITE_MIN=$(echo "$SQLITE_VER" | cut -d. -f2)
SQLITE_PAT=$(echo "$SQLITE_VER" | cut -d. -f3)

# chromadb needs >= 3.35.0
if [[ "$SQLITE_MAJ" -lt 3 || ( "$SQLITE_MAJ" -eq 3 && "$SQLITE_MIN" -lt 35 ) ]]; then
    warn "sqlite3 $SQLITE_VER is too old for chromadb (needs ≥ 3.35)"
    fix "Installing pysqlite3-binary as replacement..."
    pip_install "pysqlite3-binary" pysqlite3-binary --quiet \
        && ok "pysqlite3-binary installed — chromadb will use it automatically" \
        || warn "pysqlite3-binary install failed — chromadb may not work on this system"
else
    ok "sqlite3 $SQLITE_VER ✓"
fi

# ── Step 8: Core requirements ─────────────────────────────────────────────────
step "[ 8 / 11 ]  Installing core dependencies"
info "Installing from requirements.txt — this may take 3–10 minutes on first run."

# Ensure version.txt exists before installing the package
[[ -f version.txt ]] || echo "2.1.0" > version.txt

# Install core in two phases:
# Phase A — pure Python / pre-built wheels (fast, rarely fail)
CORE_SAFE=(
    "fastapi>=0.111.0"
    "uvicorn[standard]>=0.30.1"
    "httpx>=0.27.0"
    "aiofiles>=23.2.1"
    "pydantic>=2.7.1"
    "tomli>=2.0.1"
    "tomli-w>=1.0.0"
    "watchdog>=4.0.1"
    "PyYAML>=6.0.1"
    "click>=8.1.7"
    "rich>=13.7.1"
    "requests>=2.32.3"
    "feedparser>=6.0.11"
    "sqlalchemy>=2.0.30"
    "pystray>=0.19.5"
    "Pillow>=10.3.0"
)

info "Phase A: fast packages..."
pip_install "core packages" "${CORE_SAFE[@]}" --quiet \
    || die "Core package install failed. Check your internet connection and retry."
ok "Core packages installed"

# Phase B — packages that sometimes need compilation or are large
CORE_COMPILE=(
    "trafilatura>=1.9.0"
    "datasketch>=1.6.4"
    "spacy>=3.7.4"
)

info "Phase B: packages that may compile from source..."
for pkg in "${CORE_COMPILE[@]}"; do
    info "Installing $pkg..."
    pip_install "$pkg" "$pkg" --quiet \
        && ok "$pkg ✓" \
        || warn "$pkg failed — continuing (non-critical for basic operation)"
done

# Phase C — heavy ML packages (chromadb, sentence-transformers)
info "Phase C: ML packages (chromadb, sentence-transformers)..."

info "Installing chromadb..."
pip_install "chromadb" "chromadb>=0.5.0" --quiet \
    && ok "chromadb ✓" \
    || {
        warn "chromadb install failed. Trying with pysqlite3-binary workaround..."
        pip_install "pysqlite3-binary" pysqlite3-binary --quiet || true
        CHROMADB_SETTINGS='{"chroma_db_impl": "duckdb+parquet"}' \
        pip_install "chromadb (retry)" "chromadb>=0.5.0" --quiet \
            && ok "chromadb ✓ (retry)" \
            || fail "chromadb install failed — knowledge base features will not work"
    }

info "Installing sentence-transformers..."
pip_install "sentence-transformers" "sentence-transformers>=3.0.1" --quiet \
    && ok "sentence-transformers ✓" \
    || fail "sentence-transformers failed — embedding features will not work"

# ── Step 9: Project editable install ─────────────────────────────────────────
step "[ 9 / 11 ]  Installing OCBrain package"
pip_install "ocbrain (editable)" -e . --quiet \
    && ok "OCBrain installed in editable mode" \
    || die "Failed to install OCBrain. Check that pyproject.toml is valid."

# ── Step 10: spaCy model ──────────────────────────────────────────────────────
step "[10 / 11 ]  Downloading spaCy language model"

# Check if already installed
if "$PYTHON" -c "import en_core_web_sm" &>/dev/null 2>&1; then
    ok "spaCy model en_core_web_sm already installed"
else
    info "Downloading en_core_web_sm..."
    if "$PYTHON" -m spacy download en_core_web_sm --quiet 2>/tmp/ocbrain_spacy.err; then
        ok "spaCy model downloaded"
    else
        warn "spacy download command failed — trying direct pip URL..."
        # Fallback: install directly from GitHub release
        SPACY_URL="https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.7.1/en_core_web_sm-3.7.1-py3-none-any.whl"
        pip_install "en_core_web_sm (direct)" "$SPACY_URL" --quiet \
            && ok "spaCy model installed via direct URL" \
            || {
                fail "spaCy model install failed"
                warn "OCBrain will still work but intent classification will use keyword-only mode."
                warn "To fix manually: source .venv/bin/activate && python -m spacy download en_core_web_sm"
            }
    fi
fi

# ── Step 11: Optional dependencies ───────────────────────────────────────────
step "[11 / 11 ]  Optional dependencies"
echo ""

# ── Training (PyTorch + LoRA) ─────────────────────────────────────────────────
TRAIN=${TRAIN:-}
if [[ -z "$TRAIN" ]]; then
    echo -e "${BOLD}  Training dependencies${NC} (PyTorch + LoRA fine-tuning)"
    echo    "  Allows OCBrain to train its own models locally."
    echo -e "  Requires: ~3–6 GB disk, 6 GB+ VRAM recommended\n"
    read -rp "  Install training dependencies? [y/N] " TRAIN
fi

if [[ "$TRAIN" =~ ^[Yy]$ ]]; then
    info "Detecting GPU..."
    HAS_CUDA=false
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        CUDA_VER=$(nvidia-smi | grep -oP 'CUDA Version: \K[\d.]+' | head -1 || echo "unknown")
        ok "NVIDIA GPU detected (CUDA $CUDA_VER)"
        HAS_CUDA=true
    else
        warn "No NVIDIA GPU detected — installing CPU-only PyTorch (~500 MB vs 2.5 GB)"
    fi

    if [[ "$HAS_CUDA" == true ]]; then
        info "Installing PyTorch with CUDA support..."
        pip_install "torch (CUDA)" \
            torch torchvision torchaudio --quiet \
            && ok "PyTorch (CUDA) ✓" \
            || {
                warn "CUDA PyTorch failed — falling back to CPU build"
                pip_install "torch (CPU fallback)" \
                    torch torchvision torchaudio \
                    --index-url https://download.pytorch.org/whl/cpu --quiet \
                    && ok "PyTorch (CPU) ✓" \
                    || fail "PyTorch install failed"
            }
    else
        info "Installing PyTorch CPU build..."
        pip_install "torch (CPU)" \
            torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/cpu --quiet \
            && ok "PyTorch (CPU) ✓" \
            || fail "PyTorch install failed"
    fi

    info "Installing LoRA packages (trl, transformers, peft, datasets)..."
    for pkg in "trl>=0.9.4" "transformers>=4.42.3" "peft>=0.11.1" "datasets>=2.19.2"; do
        pip_install "$pkg" "$pkg" --quiet \
            && ok "$pkg ✓" \
            || warn "$pkg failed — training may be limited"
    done

    # bitsandbytes — CUDA vs CPU version
    info "Installing bitsandbytes..."
    if [[ "$HAS_CUDA" == true ]]; then
        pip_install "bitsandbytes" "bitsandbytes>=0.43.1" --quiet \
            && ok "bitsandbytes ✓" \
            || {
                warn "bitsandbytes CUDA failed — trying CPU version..."
                pip_install "bitsandbytes-cpu" "bitsandbytes" --quiet \
                    || warn "bitsandbytes install failed — 4-bit quantization disabled"
            }
    else
        # CPU systems: bitsandbytes works but quantization is limited
        pip_install "bitsandbytes" "bitsandbytes>=0.43.1" --quiet \
            && ok "bitsandbytes ✓" \
            || warn "bitsandbytes failed — 4-bit quantization disabled (CPU mode not affected)"
    fi

    ok "Training dependencies installed"
else
    warn "Skipping training deps — modules will run on external models only"
fi

# ── Voice ─────────────────────────────────────────────────────────────────────
echo ""
VOICE=${VOICE:-}
if [[ -z "$VOICE" ]]; then
    echo -e "${BOLD}  Voice input${NC} (Whisper STT + pyttsx3 TTS)"
    echo    "  Enables Ctrl+Shift+Space voice queries."
    echo -e "  Requires: ~150 MB disk\n"
    read -rp "  Install voice dependencies? [y/N] " VOICE
fi

if [[ "$VOICE" =~ ^[Yy]$ ]]; then
    # Voice needs portaudio system lib
    info "Installing portaudio system library..."
    case "$PKG_MANAGER" in
        apt)    sys_install portaudio19-dev libespeak-ng1 || true ;;
        dnf)    sys_install portaudio-devel espeak-ng    || true ;;
        pacman) sys_install portaudio espeak-ng          || true ;;
        zypper) sys_install portaudio-devel espeak-ng    || true ;;
    esac

    for pkg in "openai-whisper>=20231117" "pyttsx3>=2.90" "sounddevice>=0.4.6" "soundfile>=0.12.1" "keyboard>=0.13.5"; do
        pip_install "$pkg" "$pkg" --quiet \
            && ok "$pkg ✓" \
            || warn "$pkg failed — voice may be limited"
    done

    ok "Voice dependencies installed"
else
    warn "Skipping voice dependencies"
fi

# ── Ollama ────────────────────────────────────────────────────────────────────
echo ""
step "  Checking Ollama"
if command -v ollama &>/dev/null; then
    ok "Ollama found: $(ollama --version 2>/dev/null || echo 'installed')"
    if ollama list 2>/dev/null | grep -qE '(mistral|codestral|llama|gemma|phi)'; then
        ok "Ollama model(s) found"
    else
        warn "No Ollama models found."
        info "Pulling mistral (this may take a few minutes — ~4 GB download)..."
        ollama pull mistral \
            && ok "mistral ready" \
            || warn "ollama pull failed — run manually: ollama pull mistral"
    fi
else
    warn "Ollama is not installed."
    echo ""
    echo    "  OCBrain needs Ollama to run in bootstrap/shadow stage."
    echo    "  Install it with:"
    echo -e "    ${BOLD}curl -fsSL https://ollama.ai/install.sh | sh${NC}"
    echo    "  Then pull a model:"
    echo -e "    ${BOLD}ollama pull mistral${NC}"
    echo -e "    ${BOLD}ollama pull codestral${NC}"
    echo ""
    AUTO_OLLAMA=${AUTO_OLLAMA:-}
    if [[ -z "$AUTO_OLLAMA" ]]; then
        read -rp "  Install Ollama now? [y/N] " AUTO_OLLAMA
    fi
    if [[ "$AUTO_OLLAMA" =~ ^[Yy]$ ]]; then
        fix "Installing Ollama..."
        curl -fsSL https://ollama.ai/install.sh | sh \
            && ok "Ollama installed" \
            || warn "Ollama install failed — install manually from https://ollama.ai"
        ollama pull mistral 2>/dev/null \
            && ok "mistral model ready" \
            || warn "Run: ollama pull mistral"
    fi
fi

# ── Final directory + package structure ──────────────────────────────────────
step "  Finalising project structure"
mkdir -p data/raw data/chunks data/evals data/gaps data/exports
for d in core modules modules/coding modules/web_search \
          modules/knowledge modules/system_ctrl modules/_template \
          learning interface; do
    mkdir -p "$d"
    [[ -f "$d/__init__.py" ]] || touch "$d/__init__.py"
done
[[ -f version.txt ]] || echo "2.1.0" > version.txt
rm -f /tmp/ocbrain_*.err 2>/dev/null || true
ok "Project structure ready"

# ── Verify installation ───────────────────────────────────────────────────────
echo ""
step "  Verifying installation"
VERIFY_PASS=0; VERIFY_FAIL=0

verify() {
    local label="$1"; local module="$2"
    if "$PYTHON" -c "import $module" &>/dev/null 2>&1; then
        ok "$label"
        (( VERIFY_PASS++ ))
    else
        fail "$label (import failed — non-critical if optional)"
        (( VERIFY_FAIL++ ))
    fi
}

verify "fastapi"                fastapi
verify "uvicorn"                uvicorn
verify "httpx"                  httpx
verify "chromadb"               chromadb
verify "pydantic"               pydantic
verify "aiofiles"               aiofiles
verify "watchdog"               watchdog
verify "yaml (PyYAML)"          yaml
verify "click"                  click
verify "rich"                   rich
verify "trafilatura"            trafilatura

echo ""
if [[ $VERIFY_FAIL -eq 0 ]]; then
    ok "All core packages verified"
else
    warn "$VERIFY_FAIL package(s) failed import — OCBrain may have limited functionality"
    info "To fix: source .venv/bin/activate && pip install -r requirements.txt"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
cat << DONE
  ╔═══════════════════════════════════════════════╗
  ║   Setup complete!                             ║
  ║                                               ║
  ║   Start OCBrain:                              ║
  ║     source .venv/bin/activate                 ║
  ║     python main.py                            ║
  ║                                               ║
  ║   Web UI:   http://localhost:7437             ║
  ║   API docs: http://localhost:7437/docs        ║
  ║                                               ║
  ║   CLI:  ocbrain "your question"               ║
  ╚═══════════════════════════════════════════════╝
DONE
