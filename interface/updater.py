"""
interface/updater.py — OCBrain update system.
Update path: git pull → pip install -e . → restart.
Works for any install method (git clone, pip install from GitHub URL).
"""
import asyncio
import logging
import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import requests

log = logging.getLogger("ocbrain")

GITHUB_REPO = "1h0lde4/OCBrain"
PROJECT_ROOT = Path(__file__).parent.parent
VERSION_FILE = PROJECT_ROOT / "version.txt"
ROLLBACK_FILE = PROJECT_ROOT / ".rollback_commit"


# ── Version helpers ───────────────────────────────────────────────────────────

def current_version() -> str:
    """Read from version.txt — never hardcode."""
    try:
        return VERSION_FILE.read_text().strip()
    except FileNotFoundError:
        return "0.0.0"


def current_git_commit() -> Optional[str]:
    """Return the current git commit hash, or None if not a git repo."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=PROJECT_ROOT,
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except Exception:
        return None


def is_git_repo() -> bool:
    return (PROJECT_ROOT / ".git").exists()


def _version_gt(a: str, b: str) -> bool:
    try:
        return (
            tuple(int(x) for x in a.split("."))
            > tuple(int(x) for x in b.split("."))
        )
    except Exception:
        return False


# ── Result dataclasses ────────────────────────────────────────────────────────

@dataclass
class UpdateResult:
    available: bool
    version: str = field(default_factory=current_version)
    current: str = field(default_factory=current_version)
    changelog: str = ""
    download_url: str = ""
    check_failed: bool = False
    check_error: str = ""


@dataclass
class InstallResult:
    success: bool
    message: str
    restart_required: bool = False


# ── Check ─────────────────────────────────────────────────────────────────────

def check() -> UpdateResult:
    """
    Query GitHub Releases API for the latest version.
    Returns UpdateResult with check_failed=True if GitHub is unreachable.
    """
    cv = current_version()
    try:
        resp = requests.get(
            f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest",
            timeout=10,
            headers={"Accept": "application/vnd.github.v3+json"},
        )

        if resp.status_code == 404:
            # No releases published yet — check latest commit on main instead
            return _check_via_commits(cv)

        resp.raise_for_status()
        data    = resp.json()
        latest  = data.get("tag_name", "v0.0.0").lstrip("v")

        if _version_gt(latest, cv):
            return UpdateResult(
                available=True,
                version=latest,
                current=cv,
                changelog=data.get("body", "")[:500],
                download_url=data.get("html_url", ""),
            )
        return UpdateResult(available=False, version=latest, current=cv)

    except requests.RequestException as e:
        return UpdateResult(
            available=False,
            current=cv,
            check_failed=True,
            check_error=f"Could not reach GitHub: {e}",
        )
    except Exception as e:
        return UpdateResult(
            available=False,
            current=cv,
            check_failed=True,
            check_error=str(e),
        )


def _check_via_commits(cv: str) -> UpdateResult:
    """
    Fallback: compare local git commit vs remote main.
    Used when no GitHub Releases exist yet.
    """
    try:
        result = subprocess.run(
            ["git", "fetch", "origin", "main", "--dry-run"],
            cwd=PROJECT_ROOT,
            capture_output=True, text=True, timeout=15,
        )
        local  = current_git_commit() or ""
        remote = subprocess.run(
            ["git", "rev-parse", "origin/main"],
            cwd=PROJECT_ROOT,
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()

        if remote and local != remote:
            return UpdateResult(
                available=True,
                version="latest",
                current=cv,
                changelog="New commits available on main branch.",
                download_url=f"https://github.com/{GITHUB_REPO}/commits/main",
            )
    except Exception:
        pass
    return UpdateResult(available=False, current=cv)


# ── Install (sync — for CLI use) ──────────────────────────────────────────────

def install(version: str) -> InstallResult:
    """
    Update OCBrain via git pull + pip install -e .
    Saves current commit hash for rollback before doing anything.
    """
    if not is_git_repo():
        # Installed via pip URL — use pip upgrade
        return _install_via_pip(version)
    return _install_via_git(version)


def _install_via_git(version: str) -> InstallResult:
    """git fetch → save rollback point → git pull → pip install -e ."""

    # 1. Save current commit for rollback
    commit = current_git_commit()
    if commit:
        ROLLBACK_FILE.write_text(commit)
        log.info(f"[updater] Rollback point saved: {commit[:12]}")

    # 2. git fetch
    log.info("[updater] Fetching from origin...")
    r = subprocess.run(
        ["git", "fetch", "origin"],
        cwd=PROJECT_ROOT, capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        return InstallResult(False, f"git fetch failed:\n{r.stderr}")

    # 3. git pull (or checkout specific tag if version is semver)
    if version and version != "latest" and version[0].isdigit():
        cmd = ["git", "checkout", f"v{version}"]
    else:
        cmd = ["git", "pull", "origin", "main"]

    log.info(f"[updater] Running: {' '.join(cmd)}")
    r = subprocess.run(
        cmd, cwd=PROJECT_ROOT, capture_output=True, text=True, timeout=60,
    )
    if r.returncode != 0:
        return InstallResult(False, f"git pull failed:\n{r.stderr}")

    # 4. pip install -e . to pick up any new dependencies
    pip_bin = _find_pip()
    log.info(f"[updater] Updating dependencies with {pip_bin}...")
    r = subprocess.run(
        [pip_bin, "install", "-e", ".", "--quiet", "--timeout", "120"],
        cwd=PROJECT_ROOT, capture_output=True, text=True, timeout=180,
    )
    if r.returncode != 0:
        log.warning(f"[updater] pip install had issues:\n{r.stderr}")
        # Non-fatal — code updated, deps may be fine

    new_version = current_version()
    return InstallResult(
        success=True,
        message=f"Updated to {new_version}. Restart OCBrain to apply.",
        restart_required=True,
    )


def _install_via_pip(version: str) -> InstallResult:
    """For pip-URL installs: pip install --upgrade from GitHub."""
    pip_bin = _find_pip()
    if version and version != "latest":
        url = f"git+https://github.com/{GITHUB_REPO}.git@v{version}"
    else:
        url = f"git+https://github.com/{GITHUB_REPO}.git"

    log.info(f"[updater] pip install --upgrade {url}")
    r = subprocess.run(
        [pip_bin, "install", "--upgrade", url, "--quiet", "--timeout", "120"],
        cwd=PROJECT_ROOT, capture_output=True, text=True, timeout=300,
    )
    if r.returncode != 0:
        return InstallResult(False, f"pip upgrade failed:\n{r.stderr}")

    return InstallResult(
        success=True,
        message=f"Updated via pip. Restart OCBrain to apply.",
        restart_required=True,
    )


# ── Install (async — for API/background use) ──────────────────────────────────

async def install_async(version: str) -> InstallResult:
    """
    Non-blocking update for FastAPI endpoint.
    Runs git/pip in a subprocess executor so the event loop stays free.
    """
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, install, version)


# ── Rollback ──────────────────────────────────────────────────────────────────

def rollback() -> InstallResult:
    """Revert to the commit that was active before the last update."""
    if not is_git_repo():
        return InstallResult(False, "Rollback only works for git-cloned installs.")

    if not ROLLBACK_FILE.exists():
        return InstallResult(
            False,
            "No rollback point saved. Either no update has been applied yet, "
            "or the rollback file was deleted."
        )

    prev_commit = ROLLBACK_FILE.read_text().strip()
    if not prev_commit:
        return InstallResult(False, "Rollback file is empty.")

    log.info(f"[updater] Rolling back to {prev_commit[:12]}...")
    r = subprocess.run(
        ["git", "checkout", prev_commit],
        cwd=PROJECT_ROOT, capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        return InstallResult(False, f"git checkout failed:\n{r.stderr}")

    # Re-install deps for the rolled-back version
    pip_bin = _find_pip()
    subprocess.run(
        [pip_bin, "install", "-e", ".", "--quiet"],
        cwd=PROJECT_ROOT, timeout=120,
    )

    ROLLBACK_FILE.unlink(missing_ok=True)
    return InstallResult(
        success=True,
        message=f"Rolled back to {prev_commit[:12]}. Restart OCBrain to apply.",
        restart_required=True,
    )


# ── Restart ───────────────────────────────────────────────────────────────────

def restart():
    """
    Re-exec the current process with the same arguments.
    Applies updated code without requiring manual restart.
    """
    log.info("[updater] Restarting OCBrain...")
    os.execv(sys.executable, [sys.executable] + sys.argv)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _find_pip() -> str:
    """
    Find the correct pip: prefer the venv pip, fall back to sys.executable -m pip.
    Never use a system pip that might install into the wrong environment.
    """
    # If running inside a venv, use its pip
    venv_pip = PROJECT_ROOT / ".venv" / "bin" / "pip"
    if venv_pip.exists():
        return str(venv_pip)

    # If sys.executable is inside a venv
    bin_pip = Path(sys.executable).parent / "pip"
    if bin_pip.exists():
        return str(bin_pip)

    # Fallback: use current Python's -m pip
    return f"{sys.executable} -m pip"
