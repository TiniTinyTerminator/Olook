#!/usr/bin/env bash
# Install Olook into the running Omarchy shell.
#
#   ./install.sh          copy this checkout into ~/.config/omarchy/plugins
#   ./install.sh --link   symlink it instead (see the note below)
#   ./install.sh --uninstall
#
# Copy is the default because the shell's file watcher only reloads plugin code
# it can see change on disk: a symlinked plugin directory means edits land on
# the checkout's inode, the watcher never fires, and the shell keeps serving
# the QML it compiled at startup until you restart it. Re-run this script after
# editing and the change is live without restarting anything.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="ttt.olook"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BIN_DIR="$HOME/.local/bin"
MODE="copy"

for arg in "$@"; do
  case "$arg" in
    --copy) MODE="copy" ;;
    --link) MODE="link" ;;
    --uninstall) MODE="uninstall" ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

reload_shell() {
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
}

# The reading pane renders mail with QtWebEngine, which refuses to start when
# QCoreApplication has no arguments -- and Quickshell gives it none. lib/argcshim.c
# explains the whole story; this builds it. Without it the pane falls back to
# Qt's rich text, so a machine with no compiler still gets a working client.
build_shim() {
  local source="$PLUGIN_DIR/lib/argcshim.c"
  local target="$PLUGIN_DIR/lib/argcshim.so"

  if ! command -v gcc >/dev/null 2>&1; then
    echo "No gcc: skipping the HTML renderer shim (mail will use Qt's rich text)."
    return
  fi
  if gcc -shared -fPIC -O2 -o "$target" "$source" -ldl 2>/dev/null; then
    echo "Built the HTML renderer shim."
  else
    echo "Could not build the HTML renderer shim; mail will use Qt's rich text."
    return
  fi

  local line="hl.env(\"LD_PRELOAD\", \"$target\")"
  if grep -qs "argcshim.so" "$HOME/.config/hypr/hyprland.lua"; then
    return
  fi
  echo
  echo "To turn the HTML renderer on, add this to ~/.config/hypr/hyprland.lua"
  echo "and run 'hyprctl reload && omarchy restart shell':"
  echo "  $line"
}

if [[ "$MODE" == "uninstall" ]]; then
  rm -rf "$PLUGIN_DIR"
  rm -f "$BIN_DIR/olook"
  reload_shell
  echo "Olook removed. Mail cache and accounts were left alone:"
  echo "  ~/.config/olook  ~/.local/state/olook"
  if grep -qs "argcshim.so" "$HOME/.config/hypr/hyprland.lua"; then
    echo
    echo "Also drop the LD_PRELOAD line from ~/.config/hypr/hyprland.lua:"
    echo "  it names a file that is now gone, and the dynamic linker will"
    echo "  complain about it in every process you start."
  fi
  exit 0
fi

mkdir -p "$(dirname "$PLUGIN_DIR")" "$BIN_DIR"
rm -rf "$PLUGIN_DIR"

if [[ "$MODE" == "link" ]]; then
  ln -sfn "$SRC" "$PLUGIN_DIR"
  echo "Linked $SRC -> $PLUGIN_DIR"
else
  mkdir -p "$PLUGIN_DIR"
  cp -r "$SRC/manifest.json" "$SRC/ui" "$SRC/bin" "$SRC/lib" "$PLUGIN_DIR/"
  echo "Copied Olook into $PLUGIN_DIR"
fi

ln -sfn "$PLUGIN_DIR/bin/olook" "$BIN_DIR/olook"
echo "Linked the engine to $BIN_DIR/olook"

build_shim

reload_shell

if command -v omarchy >/dev/null 2>&1; then
  if omarchy plugin list --json 2>/dev/null | grep -q "\"id\":\"$PLUGIN_ID\",\"name\":\"[^\"]*\",\"kinds\":[^]]*],\"enabled\":true"; then
    echo "Olook is already enabled in the bar."
  else
    omarchy plugin enable "$PLUGIN_ID" --section right >/dev/null 2>&1 \
      && echo "Added Olook to the bar." \
      || echo "Could not add the bar widget automatically. Run: omarchy plugin enable $PLUGIN_ID --section right"
  fi
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH; add it to run 'olook' from a terminal." ;;
esac

echo
echo "Next: olook setup    (add Gmail, Outlook.com, Microsoft 365, or any IMAP account)"
echo "      Super+M        (once you add the keybinding — see README)"
