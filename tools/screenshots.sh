#!/usr/bin/env bash
# Screenshots of Olook and Olook Calendar, taken from demo data only.
#
#   tools/screenshots.sh [path/to/olook-calendar]
#
# Nothing here reads your accounts. It builds a throwaway home with the
# demo mailboxes (`olook demo`) and two sample calendar files, runs a second
# Hyprland nested inside this one with its own Omarchy shell, and captures
# that. The nested session is parked on a virtual output, so it renders
# without ever appearing on your screen; everything is torn down at the end.
#
# Writes PNGs to docs/screenshots/.
set -uo pipefail
unset LD_PRELOAD

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALENDAR_SRC="${1:-$ROOT/../olook-calendar}"
OUT="$ROOT/docs/screenshots"
WORK="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/olook-shots.XXXXXX")"
F="$WORK/home"
# The nested screen in pixels, drawn at 1.5x like a typical laptop: a
# 1280x800 desktop, captured sharp.
WIDTH=1920
HEIGHT=1200
SCALE=1.5
LW=$(( WIDTH * 2 / 3 ))   # logical size, which window placement works in
LH=$(( HEIGHT * 2 / 3 ))

[[ -f $CALENDAR_SRC/manifest.json ]] || { echo "olook-calendar checkout not found: $CALENDAR_SRC" >&2; exit 1; }
command -v grim >/dev/null || { echo "needs grim" >&2; exit 1; }
mkdir -p "$OUT" "$F/.config/omarchy/plugins" "$F/.local/state" "$F/.local/share" "$F/.cache"

fake_env=(HOME="$F" XDG_CONFIG_HOME="$F/.config" XDG_STATE_HOME="$F/.local/state"
          XDG_DATA_HOME="$F/.local/share" XDG_CACHE_HOME="$F/.cache")

NESTED_PID=""
SHELL_PID=""
VIRTUAL=""
cleanup() {
  [[ -n $SHELL_PID ]] && kill "$SHELL_PID" 2>/dev/null
  [[ -n $NESTED_PID ]] && kill "$NESTED_PID" 2>/dev/null
  sleep 1
  [[ -n $VIRTUAL ]] && hyprctl output remove "$VIRTUAL" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- the demo home ------------------------------------------------------------
P="$F/.config/omarchy/plugins"
mkdir -p "$P/ttt.olook" "$P/ttt.olook-calendar"
cp -r "$ROOT/manifest.json" "$ROOT/ui" "$ROOT/bin" "$ROOT/lib" "$P/ttt.olook/"
cp "$CALENDAR_SRC"/manifest.json "$CALENDAR_SRC"/*.qml "$P/ttt.olook-calendar/"
ENGINE="$P/ttt.olook/bin/olook"

env "${fake_env[@]}" "$ENGINE" demo >/dev/null

python3 - "$F" <<'PY'
import datetime, json, pathlib, sys
F = pathlib.Path(sys.argv[1])
today = datetime.date.today()
monday = today - datetime.timedelta(days=today.weekday())

def event(uid, day, start, minutes, summary, where="", notes="", rule=""):
    begin = datetime.datetime.combine(day, datetime.time(*start))
    end = begin + datetime.timedelta(minutes=minutes)
    lines = ["BEGIN:VEVENT", f"UID:{uid}@example", f"SUMMARY:{summary}",
             f"DTSTART;TZID=Europe/Amsterdam:{begin:%Y%m%dT%H%M%S}",
             f"DTEND;TZID=Europe/Amsterdam:{end:%Y%m%dT%H%M%S}"]
    if where: lines.append(f"LOCATION:{where}")
    if notes: lines.append(f"DESCRIPTION:{notes}")
    if rule: lines.append(f"RRULE:{rule}")
    return lines + ["END:VEVENT"]

def all_day(uid, day, summary):
    return ["BEGIN:VEVENT", f"UID:{uid}@example", f"SUMMARY:{summary}",
            f"DTSTART;VALUE=DATE:{day:%Y%m%d}",
            f"DTEND;VALUE=DATE:{day + datetime.timedelta(days=1):%Y%m%d}", "END:VEVENT"]

def day(n): return monday + datetime.timedelta(days=n)

first = today.replace(day=1)
start_week = first - datetime.timedelta(days=first.weekday())

work = (event("standup", start_week, (9, 30), 15, "Stand-up", "Room 2.14",
              rule="FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        + event("planning", start_week, (13, 0), 60, "Sprint planning", "Room 4.02",
                rule="FREQ=WEEKLY;INTERVAL=2;BYDAY=MO")
        + event("allhands", first + datetime.timedelta(days=9), (15, 0), 60, "All hands", "Auditorium")
        + event("roadmap", day(1), (11, 0), 60, "Q3 roadmap review", "Room 4.02",
                "Agenda: what shipped, what slipped, what is next.\\nNotes: https://example.com/roadmap")
        + event("oneonone", day(2), (14, 0), 30, "1:1 with Kim", "Kitchen")
        + event("design", day(3), (10, 0), 90, "Design review", "Room 2.14")
        + event("retro", day(4), (16, 0), 45, "Retro", "Room 4.02")
        + event("release", day(8), (13, 0), 60, "Release 4.1", "Online"))
home = (event("dentist", day(2), (8, 30), 45, "Dentist", "Kerkstraat 12")
        + event("swim", start_week + datetime.timedelta(days=1), (18, 30), 60, "Swimming", "De Krommerijn",
                rule="FREQ=WEEKLY;BYDAY=TU,TH")
        + all_day("birthday", day(5), "Ada's birthday")
        + event("dinner", day(5), (19, 0), 120, "Dinner with Kim", "Vlaamsch Broodhuys"))

for name, body in (("work", work), ("personal", home)):
    (F / f"{name}.ics").write_text("\n".join(
        ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Olook//Demo//EN"] + body
        + ["END:VCALENDAR"]) + "\n")

# The bar: Olook's two widgets where they belong, the clock's place taken.
# Idle is pushed out of reach -- 0 would mean "lock at once".
shell = json.load(open("/usr/share/omarchy/config/omarchy/shell.json"))
shell["idle"] = {"screensaver": 86400, "lock": 86400}
shell["bar"]["centerAnchor"] = "ttt.olook-calendar"
shell["bar"]["layout"] = {
    "left": [{"id": "omarchy.menu"}, {"id": "omarchy.workspaces"}],
    "center": [{"id": "ttt.olook-calendar"}],
    "right": [{"id": "ttt.olook"}, {"id": "omarchy.network"}, {"id": "omarchy.audio"}],
}
json.dump(shell, open(F / ".config/omarchy/shell.json", "w"), indent=2)
PY

env "${fake_env[@]}" "$ENGINE" calendar-add --name Work --file "$F/work.ics" --colour "#4c8ef7" >/dev/null
env "${fake_env[@]}" "$ENGINE" calendar-add --name Personal --file "$F/personal.ics" --colour "#3fb950" >/dev/null
env "${fake_env[@]}" "$ENGINE" calendar --sync >/dev/null

cat > "$WORK/hypr.conf" <<EOF
monitor = WAYLAND-1, ${WIDTH}x${HEIGHT}@60, 0x0, ${SCALE}
general {
    gaps_in = 6
    gaps_out = 12
    border_size = 2
}
decoration {
    rounding = 8
}
animations {
    enabled = false
}
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
EOF

# --- a virtual output to render on --------------------------------------------
before=$(hyprctl monitors -j | python3 -c "import json,sys;print(' '.join(m['name'] for m in json.load(sys.stdin)))")
hyprctl output create headless >/dev/null
sleep 1
VIRTUAL=$(hyprctl monitors -j | python3 -c "
import json,sys
before=set('$before'.split())
print(next((m['name'] for m in json.load(sys.stdin) if m['name'] not in before), ''))")
[[ -n $VIRTUAL ]] || { echo "could not create a virtual output" >&2; exit 1; }
VIRTUAL_WS=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next(m['activeWorkspace']['id'] for m in json.load(sys.stdin) if m['name']=='$VIRTUAL'))")

# --- the nested session -------------------------------------------------------
sockets_before=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort)
env -u HYPRLAND_INSTANCE_SIGNATURE "${fake_env[@]}" \
    setsid Hyprland -c "$WORK/hypr.conf" >"$WORK/hypr.log" 2>&1 </dev/null &
NESTED_PID=$!
sleep 6
NESTED_DISPLAY=$(comm -13 <(echo "$sockets_before") \
                 <(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | sort) | head -1)
[[ -n $NESTED_DISPLAY ]] || { echo "nested Hyprland did not start (see $WORK/hypr.log)" >&2; exit 1; }

# Which instance is the nested one: its lock file names the Wayland socket
# it serves. Every command below that closes windows goes to this instance,
# so it has to be certain -- never "the newest", which can be your session.
NSIG=""
for d in "$XDG_RUNTIME_DIR"/hypr/*/; do
  if [[ $(sed -n 2p "$d/hyprland.lock" 2>/dev/null) == "$NESTED_DISPLAY" ]]; then
    NSIG=$(basename "$d")
    NESTED_PID=$(sed -n 1p "$d/hyprland.lock")
  fi
done
if [[ -z $NSIG || $NSIG == "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  echo "could not tell the nested Hyprland from this one; stopping" >&2
  exit 1
fi

ADDR=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin)
            if c['class']=='aquamarine' and c['pid']==$NESTED_PID), ''))")
[[ -n $ADDR ]] || { echo "nested window not found" >&2; exit 1; }
hyprctl dispatch "hl.dsp.window.float({ window = \"address:$ADDR\", action = \"on\" })" >/dev/null
hyprctl dispatch "hl.dsp.window.resize({ window = \"address:$ADDR\", x = $WIDTH, y = $HEIGHT, exact = true })" >/dev/null
hyprctl dispatch "hl.dsp.window.move({ window = \"address:$ADDR\", workspace = \"$VIRTUAL_WS\", silent = true })" >/dev/null
sleep 2

n() {
  env WAYLAND_DISPLAY="$NESTED_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$NSIG" \
      OMARCHY_PATH=/usr/share/omarchy "${fake_env[@]}" "$@"
}
n setsid quickshell -n -p /usr/share/omarchy/shell >"$WORK/shell.log" 2>&1 </dev/null &
SHELL_PID=$!
sleep 10

clear_windows() {
  n omarchy-shell ttt.olook-window close >/dev/null 2>&1
  for a in $(n hyprctl clients -j | python3 -c "
import json,sys
print(' '.join(c['address'] for c in json.load(sys.stdin)))"); do
    # The nested session runs a classic config, where the Lua-style hl.dsp
    # calls the real session takes are silently ignored.
    n hyprctl dispatch closewindow "address:$a" >/dev/null
  done
  sleep 2
}
# A popped-out window tiles to fill the screen; float it at the size it
# would have on a desktop, centred.
# The crop around a window float_newest placed, with a margin, in pixels.
around() {  # width height
  local m=60
  local x=$(( (LW - $1) / 2 * 3 / 2 - m )) y=$(( ((LH - $2) / 2 + 14) * 3 / 2 - m ))
  echo "$(( $1 * 3 / 2 + 2 * m ))x$(( $2 * 3 / 2 + 2 * m ))+$x+$y"
}
float_newest() {  # width height
  sleep 2
  local a
  a=$(n hyprctl clients -j | python3 -c "
import json,sys
cs=json.load(sys.stdin)
print(max(cs, key=lambda c: c['focusHistoryID']*-1)['address'] if cs else '')")
  [[ -n $a ]] || return
  n hyprctl dispatch setfloating "address:$a" >/dev/null
  n hyprctl dispatch resizewindowpixel "exact $1 $2,address:$a" >/dev/null
  n hyprctl dispatch movewindowpixel "exact $(( (LW - $1) / 2 )) $(( (LH - $2) / 2 + 14 )),address:$a" >/dev/null
}
shot() {  # wait, name, [crop geometry]
  sleep "$1"
  # The pointer out of the way, in the bottom corner.
  n hyprctl dispatch movecursor "$LW" "$LH" >/dev/null
  if timeout 20 env WAYLAND_DISPLAY="$NESTED_DISPLAY" grim "$WORK/raw.png"; then
    if [[ -n ${3:-} ]]; then magick "$WORK/raw.png" -crop "$3" +repage "$OUT/$2"
    else cp "$WORK/raw.png" "$OUT/$2"; fi
    echo "  $OUT/$2"
  else
    echo "  capture failed: $2" >&2
  fi
}

echo "Capturing:"
clear_windows
n omarchy-shell shell summon ttt.olook '{"view":"mail","account":"demo","folder":"INBOX","uid":1000}' >/dev/null
shot 5 mail.png

clear_windows
n omarchy-shell shell summon ttt.olook '{"view":"calendar","calendarView":"week"}' >/dev/null
shot 6 calendar.png

clear_windows
n omarchy-shell shell summon ttt.olook '{"view":"calendar","calendarView":"month"}' >/dev/null
shot 6 calendar-month.png

clear_windows
n omarchy-shell shell summon ttt.olook '{"view":"people"}' >/dev/null
shot 5 people.png

clear_windows
n omarchy-shell ttt.olook-window newMessageWith '{"to":["ada@analytical.engine"],"subject":"Re: Notes on the Analytical Engine","body":"That is the part I keep coming back to.\n\nShall we talk it through on **Friday**?","format":"markdown"}' >/dev/null
float_newest 860 560
shot 3 compose.png "$(around 860 560)"

clear_windows
n omarchy-shell ttt.olook toggle >/dev/null
shot 4 bar-mail.png "$((WIDTH / 2))x$((HEIGHT * 17 / 20))+$((WIDTH / 2))+0"
n omarchy-shell ttt.olook toggle >/dev/null

clear_windows
n omarchy-shell ttt.olook-calendar open >/dev/null
shot 4 bar-calendar.png "$((WIDTH / 2))x${HEIGHT}+$((WIDTH / 4))+0"
n omarchy-shell ttt.olook-calendar close >/dev/null

clear_windows
n omarchy-shell ttt.olook-calendar openFirst >/dev/null
float_newest 480 400
shot 3 appointment.png "$(around 480 400)"
clear_windows
echo "Done."
