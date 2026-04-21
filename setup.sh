#!/usr/bin/env bash
# setup.sh — First-time setup script for OCBrain
# Usage:
#   bash setup.sh
# Non-interactive (CI / scripted):
#   TRAIN=y VOICE=n bash setup.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[setup]${NC} ✓ $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} ⚠ $*"; }
err()  { echo -e "${RED}[setup]${NC} ✗ $*"; exit 1; }

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   OCBrain — First-Time Setup   ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

# ── 0. Detect OS ──────────────────────────────────────────────
OS="linux"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "${OS:-}" == "Windows_NT" ]] || command -v cmd.exe &>/dev/null 2>&1; then
    OS="windows"
fi
ok "Detected OS: $OS"

# ── 1. Prerequisites ──────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || err "python3 is not installed. Install Python 3.11+ from https://python.org"

# Node.js is NOT required for ocbrain — skip that check.

# ── 2. Python version check ───────────────────────────────────
PY=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
MAJOR=$(echo "$PY" | cut -d. -f1)
MINOR=$(echo "$PY" | cut -d. -f2)
if [[ "$MAJOR" -lt 3 || ( "$MAJOR" -eq 3 && "$MINOR" -lt 11 ) ]]; then
    err "Python 3.11+ required. Found: $PY. Upgrade at https://python.org"
fi
ok "Python $PY"

# ── 3. Virtual environment ────────────────────────────────────
if [[ ! -d ".venv" ]]; then
    ok "Creating virtual environment..."
    python3 -m venv .venv || err "Failed to create virtual environment"
fi

# Activate — path differs on Windows vs Unix
# FIX BUG 3: OS-aware venv activation
if [[ "$OS" == "windows" ]]; then
    ACTIVATE=".venv/Scripts/activate"
else
    ACTIVATE=".venv/bin/activate"
fi

if [[ ! -f "$ACTIVATE" ]]; then
    err "Virtualenv activation script not found at $ACTIVATE"
fi

# shellcheck disable=SC1090
source "$ACTIVATE"
ok "Virtual environment activated"

# ── 4. Ensure version.txt exists ─────────────────────────────
# FIX BUG 4: brain_version.py reads this at startup
if [[ ! -f "version.txt" ]]; then
    echo "2.0.0" > version.txt
    ok "Created version.txt (2.0.0)"
else
    ok "version.txt: $(cat version.txt)"
fi

# ── 5. Install core dependencies ──────────────────────────────
ok "Upgrading pip..."
python -m pip install --upgrade pip --quiet || err "Failed to upgrade pip"

ok "Installing core dependencies (this may take a few minutes)..."
pip install -r requirements.txt --quiet || err "Failed to install requirements.txt"
ok "Core dependencies installed"

# ── 6. Install the project in editable mode ───────────────────
ok "Installing OCBrain package..."
# FIX: use -e . (editable local install) — NOT 'pip install ocbrain'
# which would try PyPI and fail before the package is published there.
pip install -e . --quiet || err "Failed to install OCBrain package"
ok "OCBrain installed (editable)"

# ── 7. spaCy language model ───────────────────────────────────
ok "Downloading spaCy language model..."
python -m spacy download en_core_web_sm --quiet || err "spaCy model download failed"
ok "spaCy model ready"

# ── 8. Optional: training dependencies ───────────────────────
echo ""
TRAIN=${TRAIN:-}
if [[ -z "$TRAIN" ]]; then
    read -rp "Install training dependencies (PyTorch + LoRA, ~3 GB)? [y/N] " TRAIN
fi

if [[ "$TRAIN" =~ ^[Yy]$ ]]; then
    ok "Installing training dependencies..."
    # FIX BUG 1: use 'pip install -e ".[training]"' not 'ocbrain[training]'
    pip install -e ".[training]" --quiet || err "Training dependencies installation failed"
    ok "Training dependencies installed"
else
    warn "Skipping training deps — modules will run on external models only"
fi

# ── 9. Optional: voice dependencies ──────────────────────────
VOICE=${VOICE:-}
if [[ -z "$VOICE" ]]; then
    read -rp "Install voice input dependencies (Whisper + pyttsx3)? [y/N] " VOICE
fi

if [[ "$VOICE" =~ ^[Yy]$ ]]; then
    ok "Installing voice dependencies..."
    # FIX BUG 2: use 'pip install -e ".[voice]"' not 'ocbrain[voice]'
    pip install -e ".[voice]" --quiet || err "Voice dependencies installation failed"
    ok "Voice dependencies installed"
else
    warn "Skipping voice dependencies"
fi

# ── 10. Ollama check ──────────────────────────────────────────
echo ""
if command -v ollama >/dev/null 2>&1; then
    ok "Ollama found: $(ollama --version 2>/dev/null || echo 'installed')"
    if ollama list 2>/dev/null | grep -qE '(mistral|codestral|llama|gemma)'; then
        ok "Ollama model(s) found"
    else
        warn "No Ollama models found. Pulling mistral (this may take a while)..."
        ollama pull mistral || err "Failed to pull mistral. Check your internet connection."
        ok "mistral model ready"
    fi
else
    warn "Ollama not installed — required for bootstrap/shadow stages."
    warn "Install from: https://ollama.ai"
    warn "Then run:     ollama pull mistral && ollama pull codestral"
fi

# ── 11. Data directories ──────────────────────────────────────
mkdir -p data/raw data/chunks data/evals data/gaps data/exports \
    || err "Failed to create data directories"
ok "Data directories ready"

# ── 12. Python package structure ─────────────────────────────
for d in core modules modules/coding modules/web_search \
          modules/knowledge modules/system_ctrl modules/_template \
          learning interface; do
    mkdir -p "$d"
    touch "$d/__init__.py"
done
ok "Package structure ready"

# ── 13. Cleanup temp files ────────────────────────────────────
rm -f /tmp/pip_upgrade.err /tmp/req_install.err /tmp/pkg_install.err \
       /tmp/spacy.err /tmp/training.err /tmp/voice.err /tmp/ollama.err \
       2>/dev/null || true

echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Setup complete!                         ║"
echo "  ║                                           ║"
echo "  ║   Start OCBrain:                   ║"
if [[ "$OS" == "windows" ]]; then
echo "  ║     .venv\\Scripts\\activate               ║"
else
echo "  ║     source .venv/bin/activate             ║"
fi
echo "  ║     python main.py                        ║"
echo "  ║                                           ║"
echo "  ║   Web UI:  http://localhost:7437          ║"
echo "  ║   API:     http://localhost:7437/docs     ║"
echo "  ╚═══════════════════════════════════════════╝"
echo ""
