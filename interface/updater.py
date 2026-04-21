"""
interface/updater.py — Cross-platform update checker and installer.
Delegates to OS-native package manager for actual installation.
"""
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import requests

GITHUB_REPO    = "1h0lde4/OCBrain"    # update when repo is published
CURRENT_VERSION = "1.0.0"
VERSIONS_DIR   = Path.home() / ".ocbrain" / "versions"


@dataclass
class UpdateResult:
    available: bool
    version: str = CURRENT_VERSION
    changelog: str = ""
    download_url: str = ""


def check() -> UpdateResult:
    try:
        resp = requests.get(
            f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest",
            timeout=10,
            headers={"Accept": "application/vnd.github.v3+json"},
        )
        data    = resp.json()
        latest  = data.get("tag_name", "v1.0.0").lstrip("v")
        if _version_gt(latest, CURRENT_VERSION):
            return UpdateResult(
                available=True,
                version=latest,
                changelog=data.get("body", "")[:500],
                download_url=data.get("html_url", ""),
            )
    except Exception:
        pass
    return UpdateResult(available=False)


def install(version: str):
    os_name = _detect_os()
    cmds = {
        "linux-deb":  ["sudo", "apt", "install", "-y", "ocbrain"],
        "linux-rpm":  ["sudo", "dnf", "upgrade", "-y", "ocbrain"],
        "linux-arch": ["yay", "-S", "--noconfirm", "ocbrain"],
        "windows":    ["winget", "upgrade", "--id", "OCBrain.OCBrain", "--silent"],
        "macos":      ["brew", "upgrade", "--cask", "ocbrain"],
    }
    cmd = cmds.get(os_name)
    if cmd:
        try:
            subprocess.run(cmd, check=True)
            print(f"[updater] Updated to {version}")
        except subprocess.CalledProcessError as e:
            print(f"[updater] Update failed: {e}")
    else:
        print(f"[updater] Unknown OS: {os_name} — please update manually.")


def rollback():
    prev = VERSIONS_DIR / "previous"
    active = VERSIONS_DIR / "active"
    if not prev.exists():
        print("[updater] No previous version to roll back to.")
        return
    if active.exists():
        shutil.move(str(active), str(VERSIONS_DIR / "rollback_temp"))
    shutil.move(str(prev), str(active))
    if (VERSIONS_DIR / "rollback_temp").exists():
        shutil.move(str(VERSIONS_DIR / "rollback_temp"), str(prev))
    print("[updater] Rolled back to previous version. Please restart OCBrain.")


def _detect_os() -> str:
    system = platform.system()
    if system == "Windows":
        return "windows"
    if system == "Darwin":
        return "macos"
    # Linux: detect distro
    try:
        txt = Path("/etc/os-release").read_text()
        if "arch" in txt.lower() or "manjaro" in txt.lower():
            return "linux-arch"
        if "fedora" in txt.lower() or "rhel" in txt.lower() or "centos" in txt.lower():
            return "linux-rpm"
    except Exception:
        pass
    return "linux-deb"   # default


def _version_gt(a: str, b: str) -> bool:
    """Return True if version a > version b."""
    try:
        return tuple(int(x) for x in a.split(".")) > tuple(int(x) for x in b.split("."))
    except Exception:
        return False
