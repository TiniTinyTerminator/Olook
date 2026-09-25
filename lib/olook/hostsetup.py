"""The parts of an install that live outside the plugin folder.

`omarchy plugin add` clones the repository into the plugins folder and stops
there, which is enough for mail to work. Four things are left that make it
feel installed: the `olook` command on the PATH, the small library that lets
the reading pane render HTML, being the desktop's handler for mailto: links,
and an entry in the app menu. This does all four, from Settings or from
install.sh, and reports what it found either way.

The one step it will not take is editing Hyprland's config: the renderer only
works when the shell starts with the library preloaded, and that line belongs
to the user. It is handed back to be added by hand.
"""

import os
import shutil
import subprocess
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parents[2]
ENGINE = PLUGIN_DIR / "bin" / "olook"
SHIM_SOURCE = PLUGIN_DIR / "lib" / "argcshim.c"
SHIM = PLUGIN_DIR / "lib" / "argcshim.so"

HOME = Path.home()
BIN_LINK = HOME / ".local" / "bin" / "olook"
APPS_DIR = HOME / ".local" / "share" / "applications"
DESKTOP_NAME = "olook-mailto.desktop"
DESKTOP_FILE = APPS_DIR / DESKTOP_NAME
HYPR_CONFIG = HOME / ".config" / "hypr" / "hyprland.lua"
LAUNCHER_FILE = APPS_DIR / "olook.desktop"
ICON_SOURCE = PLUGIN_DIR / "assets" / "olook.svg"
ICON_FILE = HOME / ".local" / "share" / "icons" / "hicolor" / "scalable" / "apps" / "olook.svg"


def _hypr_text():
    try:
        return HYPR_CONFIG.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _mailto_default():
    if not shutil.which("xdg-mime"):
        return ""
    try:
        done = subprocess.run(["xdg-mime", "query", "default", "x-scheme-handler/mailto"],
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip()


def _shell_preload():
    """LD_PRELOAD as the running Omarchy shell has it.

    Read from the shell's own process, not from whoever runs this: from a
    terminal started before a change, or from install.sh, the caller's
    environment says nothing about what the shell loaded.
    """
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if (entry / "comm").read_text().strip() != "quickshell":
                continue
            if (entry / "environ").stat().st_uid != os.getuid():
                continue
            for item in (entry / "environ").read_bytes().split(b"\0"):
                if item.startswith(b"LD_PRELOAD="):
                    return item[len(b"LD_PRELOAD="):].decode("utf-8", "replace")
            return ""
        except OSError:
            continue
    return os.environ.get("LD_PRELOAD", "")


def check():
    """Where each part stands, without changing anything."""
    hypr = _hypr_text()
    line = f'hl.env("LD_PRELOAD", "{SHIM}")'
    preload = _shell_preload()
    return {
        "cli": {
            "ok": BIN_LINK.exists() and BIN_LINK.resolve() == ENGINE.resolve(),
            "path": str(BIN_LINK),
        },
        "renderer": {
            "built": SHIM.exists(),
            "active": str(SHIM) in preload,
            "configured": str(SHIM) in hypr,
            # A line for another copy of the library, left by an earlier
            # install or a renamed plugin.
            "stale": "argcshim.so" in hypr and str(SHIM) not in hypr,
            "line": line,
            "compiler": bool(shutil.which("gcc")),
        },
        "mailto": {
            "ok": _mailto_default() == DESKTOP_NAME,
            "current": _mailto_default(),
        },
        "launcher": {
            "ok": LAUNCHER_FILE.exists() and ICON_FILE.exists(),
        },
    }


def _link_cli():
    BIN_LINK.parent.mkdir(parents=True, exist_ok=True)
    if BIN_LINK.is_symlink() or BIN_LINK.exists():
        BIN_LINK.unlink()
    BIN_LINK.symlink_to(ENGINE)


def _build_shim():
    if not shutil.which("gcc"):
        return "no compiler: install gcc to render mail as HTML"
    done = subprocess.run(["gcc", "-shared", "-fPIC", "-O2", "-o", str(SHIM),
                           str(SHIM_SOURCE), "-ldl"],
                          capture_output=True, text=True, timeout=120)
    if done.returncode != 0:
        return "could not build the renderer library: " + done.stderr.strip()[:200]
    return ""


def _register_mailto():
    APPS_DIR.mkdir(parents=True, exist_ok=True)
    DESKTOP_FILE.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Olook\n"
        "Comment=Write an email in Olook\n"
        f"Exec={ENGINE} mailto %u\n"
        "Icon=mail-message-new\n"
        "Terminal=false\n"
        "NoDisplay=true\n"
        "MimeType=x-scheme-handler/mailto;\n"
        "Categories=Office;Network;Email;\n", encoding="utf-8")
    previous = _mailto_default()
    if shutil.which("xdg-mime") and previous != DESKTOP_NAME:
        subprocess.run(["xdg-mime", "default", DESKTOP_NAME, "x-scheme-handler/mailto"],
                       capture_output=True, timeout=10)
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(APPS_DIR)],
                       capture_output=True, timeout=30)
    return previous if previous != DESKTOP_NAME else ""


def _register_launcher():
    """Olook in the app menu: the window, and a new message from its actions.

    The menu lists desktop entries, and until now the only one was the
    hidden mailto: handler -- so the app could be opened from the bar, a
    keybinding or a terminal, but not found by name.
    """
    APPS_DIR.mkdir(parents=True, exist_ok=True)
    ICON_FILE.parent.mkdir(parents=True, exist_ok=True)
    if ICON_SOURCE.exists():
        ICON_FILE.write_bytes(ICON_SOURCE.read_bytes())
    # omarchy-shell adds the empty payload a three-word summon needs.
    LAUNCHER_FILE.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Olook\n"
        "GenericName=Mail\n"
        "Comment=Mail, calendar and contacts\n"
        "Exec=omarchy-shell shell summon ttt.olook\n"
        "Icon=olook\n"
        "Terminal=false\n"
        "StartupNotify=false\n"
        "Categories=Network;Email;\n"
        "Keywords=mail;email;inbox;calendar;contacts;outlook;\n"
        "Actions=compose;\n"
        "\n"
        "[Desktop Action compose]\n"
        "Name=New message\n"
        "Exec=omarchy-shell ttt.olook-window newMessage\n", encoding="utf-8")
    # Written under the engine's private umask; a menu entry and an icon are
    # not secrets, and other tools read them.
    for path in (LAUNCHER_FILE, ICON_FILE):
        if path.exists():
            os.chmod(path, 0o644)
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(APPS_DIR)],
                       capture_output=True, timeout=30)


def run():
    """Do every step that is ours to do, and report what is left."""
    problems = []
    _link_cli()
    trouble = _build_shim()
    if trouble:
        problems.append(trouble)
    replaced = _register_mailto()
    _register_launcher()
    state = check()
    return {"state": state, "problems": problems, "replacedMailto": replaced}


def remove():
    """Undo what run() put outside the plugin folder."""
    for path in (BIN_LINK, DESKTOP_FILE, LAUNCHER_FILE, ICON_FILE):
        if path.is_symlink() or path.exists():
            path.unlink()
