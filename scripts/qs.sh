#!/usr/bin/env bash
# Helpers for the GNOME-style quick settings and date menus.
#
# `qs.sh daemon` listens for system events and pushes state into ironvars,
# so the bar updates instantly instead of polling. Toggles set the new state
# optimistically before acting, and the daemon corrects it if the action fails.
#
# Styles that depend on state (tile highlights, calendar days) come from a
# generated stylesheet (state.css) that ironbar hot-reloads, so things change
# look in place instead of widgets being swapped, which would resize the menus.

shopt -s extglob

cache="${XDG_RUNTIME_DIR:-/tmp}/ironbar-qs"
sep=$'\x1f'

sock="${XDG_RUNTIME_DIR:-/tmp}/ironbar-ipc.sock"
state="${XDG_STATE_HOME:-$HOME/.local/state}/ironbar-gnome"

# Only sends changed values, as every update makes ironbar re-render.
# The cache is shared between the daemon and the click handlers.
# Writes to ironbar's socket directly when socat is there: the ironbar
# client takes ~40ms to start, which adds up when a click changes many vars.
if command -v socat >/dev/null; then
    set_var() {
        [ -f "$cache/$1" ] && [ "$(<"$cache/$1")" = "$2" ] && return
        printf '%s' "$2" >"$cache/$1"
        local v=${2//\\/\\\\}
        v=${v//\"/\\\"}
        v=${v//$'\n'/\\n}
        v=${v//$'\t'/\\t}
        printf '{"command":"var","subcommand":"set","key":"%s","value":"%s"}' "$1" "$v" |
            socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
    }
else
    set_var() {
        [ -f "$cache/$1" ] && [ "$(<"$cache/$1")" = "$2" ] && return
        printf '%s' "$2" >"$cache/$1"
        ironbar var set "$1" "$2" >/dev/null 2>&1
    }
fi

get() { [ -f "$cache/$1" ] && REPLY=$(<"$cache/$1") || REPLY=; }

is_active() { get "$1_active"; [ "$REPLY" = 1 ]; }

# sel "c1 c2"; prints a selector list for those calendar days
sel() {
    local c out=""
    for c in $1; do out+="#bar popover .cal-grid .day.$c, "; done
    printf '%s' "${out%, }"
}

write_state() {
    local css="" tile days
    for tile in wired wifi bt profile night dnd kbd airplane; do
        is_active $tile || continue
        css+="#bar popover .qtile.$tile button { background-color: var(--accent); }
#bar popover .qtile.$tile button:hover { background-color: var(--accent-hover); }
#bar popover .qtile.$tile button.arrow { background-color: var(--accent-arrow); border-left-color: var(--accent-separator); }
#bar popover .qtile.$tile button.arrow:hover { background-color: var(--accent-arrow-hover); }
"
    done
    get menu_profile_sel
    [ -n "$REPLY" ] && css+="#bar popover .submenu .pick.$REPLY .check { opacity: 1; }
"
    get kbd_level
    [ -n "$REPLY" ] && css+="#bar popover .kbd-menu .level.l$REPLY .level-icon { background-color: var(--card-hover); }
"
    # like GNOME, an open submenu dims the rest of the menu
    get menu_open
    [ -n "$REPLY" ] && css+="#bar popover .qs-menu > revealer > box:not(.submenu) { opacity: 0.5; }
"
    # calendar: days of the shown month stand out (weekends a bit less),
    # today is a blue circle
    get cal_days; days=$REPLY
    [ -n "$days" ] && css+="$(sel "$days") { font-weight: bold; color: var(--panel-fg); }
"
    get cal_we; days=$REPLY
    [ -n "$days" ] && css+="$(sel "$days") { font-weight: bold; color: var(--weekend); }
"
    get ws_focused
    [ -n "$REPLY" ] && css+="#bar .workspaces .item.w$REPLY { min-width: 36px; background-color: var(--panel-fg); }
"
    get cal_today
    [ -n "$REPLY" ] && css+="#bar popover .cal-grid .day.$REPLY { background-color: var(--accent); font-weight: bold; color: var(--panel-fg); }
"
    printf '%s' "$css" >"$cache/state.css"
}

# set_state <name> <value>: a value that write_state turns into styles
set_state() {
    get "$1"
    [ -f "$cache/$1" ] && [ "$REPLY" = "$2" ] && return
    printf '%s' "$2" >"$cache/$1"
    write_state
}

# Highlights a tile (1) or not (0).
set_active() { set_state "$1_active" "$2"; }

# escape <text>; result in $REPLY
escape() {
    REPLY=${1//&/&amp;}
    REPLY=${REPLY//</&lt;}
    REPLY=${REPLY//>/&gt;}
}

# tile_markup <title> [subtitle]; result in $markup
tile_markup() {
    local title
    escape "$1"; title=$REPLY
    markup="<span weight='bold'>$title</span>"
    [ -n "$2" ] && { escape "$2"; markup+=$'\n'"<span size='small'>$REPLY</span>"; }
}

# --- quick settings ---

show_wifi() {
    if [ "$1" = 1 ]; then
        tile_markup Wi-Fi "$2"
    else
        set_var wifi_icon network-wireless-disabled-symbolic
        tile_markup Wi-Fi
    fi
    set_var wifi_markup "$markup"
    set_active wifi "$1"
}

show_bt() {
    if [ "$1" = 1 ]; then
        set_var bt_icon bluetooth-active-symbolic
        tile_markup Bluetooth "$2"
    else
        set_var bt_icon bluetooth-disabled-symbolic
        tile_markup Bluetooth
    fi
    set_var bt_markup "$markup"
    set_active bt "$1"
}

show_dnd() {
    if [ "$1" = 1 ]; then
        set_var dnd_on true
    else
        set_var dnd_on false
    fi
    set_active dnd "$1"
    update_clock
}

show_profile() {
    local label active=1
    case "$1" in
    performance) label=Performance ;;
    power-saver) label="Power Saver" ;;
    *) label=Balanced ;;
    esac
    # GNOME highlights the tile, and shows the profile in the bar,
    # when not on the default profile
    [ "$1" = balanced ] && active=0
    tile_markup "Power Mode" "$label"
    set_var profile "$1"
    set_var profile_icon "power-profile-$1-symbolic"
    set_var profile_markup "$markup"
    set_var profile_bar "$( ((active)) && echo true || echo false)"
    set_active profile $active
    set_state menu_profile_sel "$1"
}

update_net() {
    local devs icon ssid sig
    devs=$(nmcli -t -f TYPE,STATE,CONNECTION dev)
    if [ "$(nmcli radio wifi)" = enabled ]; then
        ssid=$(awk -F: '$1=="wifi" && $2=="connected"{print $3; exit}' <<<"$devs")
        [ -n "$ssid" ] && sig=$(nmcli -t -f ACTIVE,SIGNAL dev wifi list --rescan no 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
        if [ -z "$sig" ]; then icon=network-wireless-offline-symbolic
        elif [ "$sig" -ge 75 ]; then icon=network-wireless-signal-excellent-symbolic
        elif [ "$sig" -ge 50 ]; then icon=network-wireless-signal-good-symbolic
        elif [ "$sig" -ge 25 ]; then icon=network-wireless-signal-ok-symbolic
        else icon=network-wireless-signal-weak-symbolic
        fi
        set_var wifi_icon "$icon"
        show_wifi 1 "$ssid"
    else
        icon=network-wireless-disabled-symbolic
        show_wifi 0
    fi
    if [[ $devs == *ethernet:connected:* ]]; then
        set_var net_icon network-wired-symbolic
        set_active wired 1
    else
        set_var net_icon "$icon"
        set_active wired 0
    fi
    [[ $devs == *ethernet:* ]] && set_var wired_show true || set_var wired_show false
}

update_vol() {
    local out vol icon
    out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@)
    vol=${out#Volume: }
    vol=${vol%% *}
    vol=$(( 10#${vol/./} ))
    if [[ $out == *MUTED* ]] || [ "$vol" -eq 0 ]; then icon=audio-volume-muted-symbolic
    elif [ "$vol" -ge 67 ]; then icon=audio-volume-high-symbolic
    elif [ "$vol" -ge 34 ]; then icon=audio-volume-medium-symbolic
    else icon=audio-volume-low-symbolic
    fi
    set_var vol_icon "$icon"
    # read by the volume slider
    printf '%s' "$vol" >"$cache/vol"
}

# Icons as GNOME 49+ picks them, including "plugged in, not charging"
# (e.g. with a charge limit) and "fully charged".
update_bat() {
    local bat=/sys/class/power_supply/BAT0 ac=0 cap status lvl icon
    [ -d "$bat" ] || return
    cap=$(<$bat/capacity)
    status=$(<$bat/status)
    [ -f /sys/class/power_supply/AC/online ] && ac=$(</sys/class/power_supply/AC/online)
    lvl=$(( (cap + 5) / 10 * 10 ))
    if [ "$status" = Full ] || { [ "$status" = Charging ] && ((lvl >= 100)); }; then
        icon=battery-level-100-charged-symbolic
    elif [ "$status" = Charging ]; then icon="battery-level-$lvl-charging-symbolic"
    elif ((ac)); then icon="battery-level-$lvl-plugged-in-symbolic"
    else icon="battery-level-$lvl-symbolic"
    fi
    set_var bat_icon "$icon"
    set_var bat_pct "$cap%"
}

# busctl rather than powerprofilesctl, which is a slow-starting Python script
pp=(org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile)

update_profile() {
    local out
    out=$(busctl get-property "${pp[@]}")
    out=${out#s \"}
    show_profile "${out%\"}"
}

update_bt() {
    local rf dev
    rf=$(rfkill list)
    if [[ $(rfkill list bluetooth) == *"Soft blocked: no"* ]]; then
        # GNOME names the connected device, if there is one
        dev=$(bluetoothctl devices Connected 2>/dev/null | head -n1)
        dev=${dev#Device * }
        [[ $dev == Device* ]] && dev=
        show_bt 1 "$dev"
    else
        show_bt 0
    fi
    # Airplane Mode: every radio is off
    if [[ $rf == *"Soft blocked: no"* ]]; then set_active airplane 0; else set_active airplane 1; fi
}

# --- tiles GNOME adds: Night Light, Keyboard ---

kbd=$(echo /sys/class/leds/*kbd_backlight 2>/dev/null)
[ -d "$kbd" ] || kbd=

# The Night Light temperature, kept across restarts; the slider polls a copy
# in the cache.
night_temp() {
    local file="$state/night-temp"
    if [ -s "$file" ]; then
        REPLY=$(<"$file")
    else
        REPLY=$(gsettings get org.gnome.settings-daemon.plugins.color night-light-temperature 2>/dev/null)
        REPLY=${REPLY#uint32 }
        REPLY=${REPLY:-2700}
    fi
}

update_night() {
    if pgrep -x hyprsunset >/dev/null; then
        set_active night 1
        set_var night_on true
    else
        set_active night 0
        set_var night_on false
    fi
    night_temp
    printf '%s' "$REPLY" >"$cache/night_temp"
}


update_kbd() {
    [ -n "$kbd" ] || return
    local level=$(<"$kbd/brightness")
    ((level > 0)) && set_active kbd 1 || set_active kbd 0
    set_state kbd_level "$level"
}

# GNOME's own icons (screenshot, the unread dot...) ship inside
# gnome-shell. If it's installed they're copied once into the user's icon
# theme, so they stay after it's removed (and get recoloured like any
# symbolic icon); without them the closest Adwaita icons are used.
load_icons() {
    local res=/usr/share/gnome-shell/gnome-shell-icons.gresource name fallback list= path
    local dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/status"
    mkdir -p "$dir"
    while read -r name fallback; do
        if [ ! -s "$dir/$name.svg" ] && [ -f "$res" ]; then
            [ -n "$list" ] || list=$(gresource list "$res")
            path=$(grep -m1 "/$name.svg\$" <<<"$list") &&
                gresource extract "$res" "$path" >"$dir/$name.svg" 2>/dev/null
        fi
        if [ -s "$dir/$name.svg" ]; then
            set_var "icon_${name//-/_}" "icon:$name"
        else
            rm -f "$dir/$name.svg"
            set_var "icon_${name//-/_}" "icon:$fallback"
        fi
    done <<'ICONS'
keyboard-brightness-off-symbolic keyboard-brightness-symbolic
keyboard-brightness-medium-symbolic keyboard-brightness-symbolic
keyboard-brightness-high-symbolic keyboard-brightness-symbolic
screenshooter-symbolic camera-photo-symbolic
message-indicator-symbolic mail-unread-symbolic
no-notifications-symbolic preferences-system-notifications-symbolic
notification-expand-symbolic pan-down-symbolic
group-collapse-symbolic pan-up-symbolic
ICONS
}

# --- workspaces ---

# A dot per workspace (up to 10), in order; ws<N> holds dot N's workspace id.
update_ws() {
    local id active n=0 focused=""
    active=$(hyprctl -j activeworkspace | jq -r .id)
    for id in $(hyprctl -j workspaces | jq -r '[.[] | select(.id > 0) | .id] | sort | .[]'); do
        ((++n > 10)) && break
        printf '%s' "$id" >"$cache/ws$n"
        set_var "ws${n}_show" true
        [ "$id" = "$active" ] && focused=$n
    done
    for ((n = n + 1; n <= 10; n++)); do set_var "ws${n}_show" false; done
    set_state ws_focused "$focused"
}

# --- date menu: clock, notifications, calendar ---

# The clock follows GNOME's clock settings (12/24h, weekday, seconds), read
# once at start; the unread dot and Do Not Disturb icon are images beside it.
clock_format() {
    local s=org.gnome.desktop.interface fmt="%b %-d  "
    [ "$(gsettings get $s clock-show-weekday 2>/dev/null)" = true ] && fmt="%a $fmt"
    [ "$(gsettings get $s clock-show-date 2>/dev/null)" = false ] && fmt=
    if [ "$(gsettings get $s clock-format 2>/dev/null)" = "'12h'" ]; then
        [ "$(gsettings get $s clock-show-seconds 2>/dev/null)" = true ] && fmt+="%-I:%M:%S %p" || fmt+="%-I:%M %p"
    else
        [ "$(gsettings get $s clock-show-seconds 2>/dev/null)" = true ] && fmt+="%H:%M:%S" || fmt+="%H:%M"
    fi
    printf '%s' "$fmt" >"$cache/clock_fmt"
}

update_clock() {
    local now
    get clock_fmt
    printf -v now "%(${REPLY:-%b %-d  %H:%M})T" -1
    set_var clock_markup "$now"
    # only while the list has something: some notifications never reach
    # dunst's history (transient ones, or ones their app closes)
    get n_any
    if [ -f "$cache/unseen" ] && [ "$REPLY" = true ] && ! is_active dnd; then
        set_var unread true
    else
        set_var unread false
    fi
}

# Month grid as 42 day labels (c1..c42); their emphasis comes from state.css.
update_calendar() {
    local offset base y m first days prev c day start fw month i
    local -a names=(S M T W T F S)
    get cal_offset; offset=${REPLY:-0}
    base=$(date -d "$(date +%Y-%m-01) $offset month" +%Y-%m)
    y=${base%-*} m=${base#*-}
    # locale week start: first_weekday 1 = Sunday, 2 = Monday
    fw=$(locale first_weekday 2>/dev/null); start=$(( (${fw:-1} - 1) % 7 ))
    first=$(( ($(date -d "$base-01" +%w) - start + 7) % 7 ))
    days=$(date -d "$base-01 +1 month -1 day" +%d)
    prev=$(date -d "$base-01 -1 day" +%d)

    printf -v month '%(%B)T' "$(date -d "$base-15" +%s)"
    [ "$y" != "$(printf '%(%Y)T' -1)" ] && month+=" $y"
    set_var cal_month "$month"
    set_var cal_weekday "$(printf '%(%A)T' -1)"
    set_var cal_date "$(printf '%(%B %-d %Y)T' -1)"
    # in parallel; waits only for these, as the daemon also has its listeners
    # as children, which never exit
    local -a jobs=()
    for ((i = 0; i < 7; i++)); do set_var "cal_h$((i + 1))" "${names[(i + start) % 7]}" & jobs+=($!); done

    local current="" weekend="" wd
    for ((c = 1; c <= 42; c++)); do
        day=$((c - first))
        if ((day < 1)); then day=$((prev + day))
        elif ((day > 10#$days)); then day=$((day - 10#$days))
        else
            wd=$(( (c - 1 + start) % 7 ))
            ((wd == 0 || wd == 6)) && weekend+=" c$c" || current+=" c$c"
        fi
        printf -v day '%02d' "$day"
        set_var "c$c" "$day" & jobs+=($!)
    done
    wait "${jobs[@]}"
    printf '%s' "${weekend# }" >"$cache/cal_we"
    set_state cal_days "${current# }"
    if ((offset == 0)); then
        set_state cal_today "c$((first + 10#$(printf '%(%d)T' -1)))"
    else
        set_state cal_today ""
    fi
}

# relative_time <seconds ago>; result in $REPLY
# as GNOME words it
relative_time() {
    local n unit
    if (($1 < 60)); then REPLY="Just now"; return
    elif (($1 < 3600)); then n=$(($1 / 60)) unit=minute
    elif (($1 < 86400)); then n=$(($1 / 3600)) unit=hour
    elif (($1 < 172800)); then REPLY=Yesterday; return
    elif (($1 < 604800)); then n=$(($1 / 86400)) unit=day
    else n=$(($1 / 604800)) unit=week
    fi
    ((n == 1)) && REPLY="$n $unit ago" || REPLY="$n ${unit}s ago"
}

# truncate <text> <chars>; result in $REPLY, escaped
truncate() {
    local t=$1
    ((${#t} > $2)) && t="${t:0:$(($2 - 1))}…"
    escape "$t"
}

# All notifications, newest first: the ones still on screen (tracked from
# D-Bus, as dunst's history only gets them once closed) plus the history.
# One line each: epoch, id, app, summary, body, icon, desktop entry.
list_notifs() {
    local up now_us
    read -r up _ </proc/uptime
    now_us=$((10#${up/./} * 10000))
    {
        [ -f "$cache/displayed" ] && awk -F"$sep" -v OFS="$sep" '{ print $6, $1, $2, $3, $4, $5, $7 }' "$cache/displayed"
        dunstctl history | jq -r --argjson now "$now_us" --argjson epoch "$EPOCHSECONDS" \
            '.data[0][] | [($epoch - (($now - .timestamp.data) / 1000000 | floor)), .id.data, .appname.data, .summary.data, .body.data, .icon_path.data, (.desktop_entry.data // "")] | map(tostring | gsub("[\n\t\u001f]"; " ")) | join("\u001f")'
    } | sort -t"$sep" -k1,1nr -k2,2nr
}

# app_icon <desktop entry>; its icon in $REPLY, or GNOME's generic one.
# GNOME shows it in each card's header, and only knows the app from that hint.
app_icon() {
    local f
    REPLY=application-x-executable-symbolic
    [ -n "$1" ] || return
    for f in ~/.local/share/applications/"$1".desktop /usr/share/applications/"$1".desktop; do
        [ -f "$f" ] || continue
        f=$(grep -m1 '^Icon=' "$f")
        [ -n "${f#Icon=}" ] && REPLY=${f#Icon=}
        return
    done
}

# desktop_entry <desktop-entry hint> <app name>; in $REPLY. Apps that send no
# hint (Electron ones, like Claude) are found by the Name= of their .desktop
# file, as GNOME finds them by their window. Empty if there's none.
declare -A de_of
desktop_entry() {
    REPLY=$1
    [ -n "$REPLY" ] || [ -z "$2" ] && return
    if [ -z "${de_of[$2]+set}" ]; then
        local f
        f=$(grep -lxF "Name=$2" ~/.local/share/applications/*.desktop /usr/share/applications/*.desktop 2>/dev/null | head -1)
        f=${f##*/}
        de_of[$2]=${f%.desktop}
    fi
    REPLY=${de_of[$2]}
}

# group_key <desktop entry> <id> <app name>; in $REPLY. Like GNOME,
# notifications are grouped by their app; ones from no known app are grouped
# by the name they give, except notify-send's, which each stand alone.
group_key() {
    desktop_entry "$1" "$3"
    if [ -n "$REPLY" ]; then REPLY="app:$REPLY"
    elif [ -n "$3" ] && [ "$3" != notify-send ]; then REPLY="name:$3"
    else REPLY="id:$2"
    fi
}

# Fills the five slots, GNOME 48+ style. Each app is one card, stacked when
# it has more; expanding a stack shows only that app, under a header with its
# name. A card's own expand button shows its whole text.
update_notifs() {
    local epoch id app summary body icon de slot=0 expanded open n key
    local -A count newest name
    local -a order lines
    get expanded; expanded=$REPLY
    get open; open=$REPLY
    mapfile -t lines < <(list_notifs)
    for line in "${lines[@]}"; do
        IFS=$sep read -r epoch id app summary body icon de <<<"$line"
        group_key "$de" "$id" "$app"; key=$REPLY
        [ -z "${count[$key]}" ] && { order+=("$key"); newest[$key]=$line; name[$key]=${app:-Notification}; }
        count[$key]=$(( ${count[$key]:-0} + 1 ))
    done
    [ -n "$expanded" ] && ((${count[$expanded]:-0} > 1)) || expanded=

    fill_slot() {  # <line> <cards stacked under it>
        ((slot >= 5)) && return
        ((++slot))
        local text when full more=false less=false
        IFS=$sep read -r epoch id app summary body icon de <<<"$1"
        relative_time $((EPOCHSECONDS - epoch)); when=$REPLY
        truncate "${app:-Notification}" 24
        set_var n${slot}_head "<span weight='bold'>$REPLY</span>  <span size='small'>$when</span>"
        truncate "$summary" 34; text="<span weight='bold'>$REPLY</span>"
        if [ "$id" = "$open" ]; then
            escape "$body"; full=$REPLY
            [ -n "$body" ] && text+=$'\n'"$(fold -s -w 40 <<<"$full")"
            less=true
        elif [ -n "$body" ]; then
            truncate "$body" 40; text+=$'\n'"$REPLY"
            ((${#body} > 40)) && more=true
        fi
        # ironbar only treats a label as markup if it starts with a span
        set_var n${slot}_markup "<span>$text</span>"
        # the notification's own icon or image goes beside the text
        if [ -f "$icon" ]; then :
        elif [ -n "$icon" ] && [[ $icon != */* ]]; then icon="icon:$icon"
        else icon=
        fi
        [ -n "$icon" ] && set_var n${slot}_icon "$icon"
        set_var n${slot}_has_icon "$([ -n "$icon" ] && echo true || echo false)"
        desktop_entry "$de" "$app"
        app_icon "$REPLY"
        set_var n${slot}_app_icon "icon:$REPLY"
        group_key "$de" "$id" "$app"
        printf '%s' "$id" >"$cache/n${slot}_id"
        printf '%s' "$REPLY" >"$cache/n${slot}_app"
        printf '%s' "$2" >"$cache/n${slot}_stack"
        set_var n${slot}_more "$more"
        set_var n${slot}_less "$less"
        set_var n${slot}_layer1 "$( (($2 >= 1)) && echo true || echo false)"
        set_var n${slot}_layer2 "$( (($2 >= 2)) && echo true || echo false)"
        set_var n${slot}_show true
    }

    if [ -n "$expanded" ]; then
        escape "${name[$expanded]}"
        set_var group_name "<span size='large' weight='800'>$REPLY</span>"
        set_var group_show true
        for line in "${lines[@]}"; do
            IFS=$sep read -r epoch id app summary body icon de <<<"$line"
            group_key "$de" "$id" "$app"
            [ "$REPLY" = "$expanded" ] && fill_slot "$line" 0
        done
    else
        set_var group_show false
        for key in "${order[@]}"; do
            n=$((count[$key] - 1))
            fill_slot "${newest[$key]}" $((n > 2 ? 2 : n))
        done
    fi
    if ((slot)); then set_var n_empty false; set_var n_any true
    else set_var n_empty true; set_var n_any false; rm -f "$cache/unseen"; set_var unread false
    fi
    for ((slot++; slot <= 5; slot++)); do
        set_var n${slot}_show false
    done
}

# rm_notif <id>: closes it if still on screen, then drops it from the history
rm_notif() {
    if [ -f "$cache/displayed" ] && grep -q "^$1$sep" "$cache/displayed"; then
        dunstctl close "$1"
        sed -i "/^$1$sep/d" "$cache/displayed"
    fi
    dunstctl history-rm "$1"
}

# Turns dbus-monitor output into one line per event:
#   notif-new <id> <replaces> <app> <icon> <summary> <body> <desktop entry>  (\x1f separated)
#   notif-closed <id>
# A new notification's id is only in dunst's reply, so calls are matched to
# replies by serial. Everything else dunst replies (e.g. history dumps) is dropped.
notif_filter() {
    awk -v SEP="$sep" '
    function field(s) { return substr(s, index(s, "\"") + 1) }
    /^(signal|method call|method return|error) / {
        mode = ""
        if ($0 ~ /member=Notify$/) { mode = "args"; n = 0; inq = 0; de = ""; s = $0; sub(/.* serial=/, "", s); sub(/ .*/, "", s); serial = s }
        else if ($0 ~ /member=NotificationClosed$/) mode = "closed"
        else if ($0 ~ /^method return / && $0 ~ / reply_serial=/) { s = $0; sub(/.* reply_serial=/, "", s); if (s in pending) { mode = "reply"; reply = s } }
        next
    }
    mode == "args" {
        if (inq) { buf = buf " " $0; if ($0 ~ /"$/) { val[n++] = substr(buf, 1, length(buf) - 1); inq = 0 } }
        else if ($0 ~ /^   string "/) {
            v = field($0)
            if (v ~ /"$/ && length(v) > 0) val[n++] = substr(v, 1, length(v) - 1)
            else { inq = 1; buf = v }
        }
        else if ($0 ~ /^   uint32 /) val[n++] = $2
        if (n == 5) mode = "hints"
        next
    }
    # the args end with the timeout, after the actions and hints
    mode == "hints" {
        if ($0 ~ /string "desktop-entry"$/) want = 1
        else if (want && $0 ~ /variant/) { de = $0; sub(/.*string "/, "", de); sub(/"$/, "", de); want = 0 }
        else if ($0 ~ /^   int32 /) { pending[serial] = val[1] SEP val[0] SEP val[2] SEP val[3] SEP val[4] SEP de; mode = "" }
        next
    }
    mode == "reply" && /^   uint32 / { print "notif-new" SEP $2 SEP pending[reply]; fflush(); delete pending[reply]; mode = ""; next }
    mode == "closed" && /^   uint32 / { print "notif-closed " $2; fflush(); mode = ""; next }
    '
}

daemon() {
    local pidfile="$cache/daemon.pids" fifo="$cache/events" pids="" p line bar=$PPID
    local net vol bat profile bt active notif minute last_minute day last_day
    local id replaces app icon summary body de

    mkdir -p "$cache"

    # stop a previous daemon and its listeners, which outlive it if it was killed
    if [ -f "$pidfile" ]; then
        for p in $(<"$pidfile"); do
            [[ $(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null) == *@(qs.sh|monitor|subscribe|rfkill|awk|socat)* ]] && kill "$p"
        done
    fi
    trap 'kill $pids 2>/dev/null' EXIT
    trap exit TERM INT HUP

    # ironbar starts with no vars or extra styles, so resend everything;
    # slider values stay, as the sliders may poll them before they're updated
    find "$cache" -maxdepth 1 -type f ! -name vol ! -name night_temp -delete
    write_state
    ironbar style load-css "$cache/state.css" >/dev/null 2>&1
    load_icons
    update_ws
    update_net
    update_vol
    update_bat
    update_profile
    update_bt
    update_night
    update_kbd
    [[ $(dunstctl is-paused 2>/dev/null) == true ]] && show_dnd 1 || show_dnd 0
    clock_format; update_clock
    update_calendar
    update_notifs

    # every listener writes into one fifo, read by a single loop below;
    # the fd is opened read-write so it never hits EOF
    rm -f "$fifo"; mkfifo "$fifo"
    exec 3<>"$fifo"
    # Hyprland's event socket, for workspaces
    socat -u "UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" - >&3 &
    pids+=" $!"
    nmcli monitor >&3 & pids+=" $!"
    pactl subscribe >&3 & pids+=" $!"
    upower --monitor >&3 & pids+=" $!"
    gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles >&3 & pids+=" $!"
    rfkill event >&3 & pids+=" $!"
    dbus-monitor --session \
        "type='signal',interface='org.freedesktop.Notifications',member='NotificationClosed'" \
        "type='method_call',interface='org.freedesktop.Notifications',member='Notify'" \
        "type='method_return',sender='org.freedesktop.Notifications'" | notif_filter >&3 &
    pids+=" $(pgrep -P $$ -f dbus-monitor) $!"
    echo "$$$pids" >"$pidfile"

    printf -v last_minute '%(%H%M)T' -1
    printf -v last_day '%(%j)T' -1
    while :; do
        # tick the clock, even when events keep the loop busy
        printf -v minute '%(%H%M)T' -1
        if [ "$minute" != "$last_minute" ]; then
            update_notifs  # refreshes the "N min ago" labels
            update_clock
            printf -v day '%(%j)T' -1
            [ "$day" != "$last_day" ] && { update_calendar; last_day=$day; }
            update_night
            update_kbd
            last_minute=$minute
        fi
        if ! read -r -t 5 -u 3 line; then
            # exit with ironbar
            kill -0 "$bar" 2>/dev/null || exit
            continue
        fi
        # gather a burst of events, then update each source once
        net= vol= bat= profile= bt= notif= ws=
        while :; do
            case "$line" in
            workspace*">>"* | createworkspace*">>"* | destroyworkspace*">>"* | changeworkspaceid">>"* | \
                moveworkspace*">>"* | focusedmon*">>"*) ws=1 ;;
            *">>"*) ;;  # other Hyprland events
            "notif-new$sep"*)
                IFS=$sep read -r _ id replaces app icon summary body de <<<"$line"
                touch "$cache/displayed"
                sed -i "/^$id$sep/d; /^$replaces$sep/d" "$cache/displayed"
                printf '%s\n' "$id$sep$app$sep$summary$sep$body$sep$icon$sep$EPOCHSECONDS$sep$de" >>"$cache/displayed"
                # GNOME's unread dot
                : >"$cache/unseen"
                notif=1
                ;;
            "notif-closed "*)
                # now in dunst's history
                [ -f "$cache/displayed" ] && sed -i "/^${line#notif-closed }$sep/d" "$cache/displayed"
                notif=1
                ;;
            "Event '"*" on sink "* | "Event '"*" on server"*) vol=1 ;;
            "Event '"*) ;;  # other pulse objects
            *" idx "*" type "*" op "*) bt=1 ;;
            *"'ActiveProfile': <'"*)
                # the event carries the new profile, so no lookup is needed
                active=${line#*\'ActiveProfile\': <\'}
                profile=${active%%\'*}
                ;;
            *PowerProfiles*) ;;
            *"device changed"* | *"device added"* | *"device removed"* | *"daemon changed"*) bat=1 ;;
            "Monitoring activity"*) ;;
            *) net=1 ;;
            esac
            read -r -t 0.05 -u 3 line || break
        done
        [ -n "$ws" ] && update_ws
        [ -n "$net" ] && update_net
        [ -n "$vol" ] && update_vol
        [ -n "$bat" ] && update_bat
        [ -n "$profile" ] && show_profile "$profile"
        [ -n "$bt" ] && update_bt
        [ -n "$notif" ] && { update_notifs; update_clock; }
    done
}

case "$1" in
daemon) daemon ;;
wifi-toggle)
    if is_active wifi; then
        show_wifi 0
        nmcli radio wifi off
    else
        set_var wifi_icon network-wireless-offline-symbolic
        show_wifi 1
        nmcli radio wifi on
    fi
    ;;
bt-toggle)
    if is_active bt; then
        show_bt 0
        rfkill block bluetooth
    else
        show_bt 1
        rfkill unblock bluetooth
    fi
    ;;
dnd-toggle)
    if is_active dnd; then
        show_dnd 0
        dunstctl set-paused false
    else
        show_dnd 1
        dunstctl set-paused true
    fi
    ;;
wired-toggle)
    dev=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="ethernet"{print $1; exit}')
    if is_active wired; then
        set_active wired 0
        nmcli device disconnect "$dev"
    else
        set_active wired 1
        nmcli device connect "$dev"
    fi
    ;;
airplane-toggle)
    if is_active airplane; then
        set_active airplane 0
        rfkill unblock all
    else
        set_active airplane 1
        rfkill block all
    fi
    ;;
night-toggle)
    if is_active night; then
        set_active night 0
        set_var night_on false
        pkill -x hyprsunset
    else
        set_active night 1
        set_var night_on true
        night_temp
        setsid -f hyprsunset -t "$REPLY" >/dev/null 2>&1
    fi
    ;;
night-temp)
    [[ $2 =~ ^[0-9]+$ ]] || exit
    mkdir -p "$state"
    printf '%s' "$2" >"$state/night-temp"
    printf '%s' "$2" >"$cache/night_temp"
    pgrep -x hyprsunset >/dev/null && hyprctl hyprsunset temperature "$2" >/dev/null
    ;;
kbd-set)
    [ -n "$kbd" ] || exit
    set_state kbd_level "$2"
    ((${2} > 0)) && set_active kbd 1 || set_active kbd 0
    brightnessctl -q -d "${kbd##*/}" set "$2"
    ;;
kbd-toggle)
    [ -n "$kbd" ] || exit
    if is_active kbd; then
        set_active kbd 0
        cat "$kbd/brightness" >"$cache/kbd_last"
        brightnessctl -q -d "${kbd##*/}" set 0
        set_state kbd_level 0
    else
        set_active kbd 1
        get kbd_last
        level=${REPLY:-$(<"$kbd/max_brightness")}
        ((level > 0)) || level=$(<"$kbd/max_brightness")
        brightnessctl -q -d "${kbd##*/}" set "$level"
        set_state kbd_level "$level"
    fi
    ;;
profile-set)
    show_profile "$2"
    busctl set-property "${pp[@]}" s "$2"
    ;;
menu)
    # the submenus that GNOME's arrow buttons open: one at a time
    get menu_open
    [ "$REPLY" = "$2" ] && next= || next=$2
    set_state menu_open "$next"
    for m in profile kbd power; do
        [ "$m" = "$next" ] && set_var "menu_$m" true || set_var "menu_$m" false
    done
    ;;
screenshot)
    # GNOME's screenshot button: pick an area, save it and copy it
    ironbar bar main hide-popup >/dev/null
    dir=$(xdg-user-dir PICTURES 2>/dev/null || echo ~/Pictures)/Screenshots
    mkdir -p "$dir"
    sleep 0.2
    area=$(slurp) || exit
    file="$dir/Screenshot From $(date '+%Y-%m-%d %H-%M-%S').png"
    grim -g "$area" "$file" && wl-copy <"$file"
    ;;
profile-cycle)
    # cached value, so rapid clicks step from the last shown profile
    get profile
    case "$REPLY" in
    balanced) next=performance ;;
    performance) next=power-saver ;;
    *) next=balanced ;;
    esac
    show_profile "$next"
    busctl set-property "${pp[@]}" s "$next"
    ;;
quick-settings)
    ironbar bar main toggle-popup quick-settings >/dev/null
    # like GNOME, the menu opens with its submenus closed
    get menu_open
    [ -n "$REPLY" ] && { set_state menu_open ""; for m in profile kbd power; do set_var "menu_$m" false; done; }
    ;;
ws-focus)
    get "ws$2"
    [ -n "$REPLY" ] || exit
    # Lua config (Hyprland 0.55+), else the classic dispatcher
    [ "$(hyprctl dispatch "hl.dsp.focus({ workspace = $REPLY })")" = ok ] ||
        hyprctl dispatch workspace "$REPLY" >/dev/null
    ;;
date-menu)
    ironbar bar main toggle-popup date-menu >/dev/null
    rm -f "$cache/unseen"
    update_clock
    # like GNOME, the menu opens on the current month with stacks collapsed
    get cal_offset; [ "${REPLY:-0}" != 0 ] && { printf 0 >"$cache/cal_offset"; update_calendar; }
    printf '' >"$cache/expanded"
    printf '' >"$cache/open"
    update_notifs
    ;;
notif-rm)
    get n$2_id; rm_notif "$REPLY"
    update_notifs
    ;;
notif-click)
    # a stack expands, a single notification is dismissed
    get n$2_stack
    if [ "${REPLY:-0}" != 0 ]; then
        get n$2_app; printf '%s' "$REPLY" >"$cache/expanded"
    else
        get n$2_id; rm_notif "$REPLY"
    fi
    update_notifs
    ;;
notif-open)
    get n$2_id; printf '%s' "$REPLY" >"$cache/open"
    update_notifs
    ;;
notif-close-text)
    printf '' >"$cache/open"
    update_notifs
    ;;
group-collapse)
    printf '' >"$cache/expanded"
    update_notifs
    ;;
notif-clear)
    dunstctl close-all
    dunstctl history-clear
    printf '' >"$cache/displayed"
    update_notifs
    ;;
cal-prev | cal-next | cal-today)
    get cal_offset; offset=${REPLY:-0}
    case "$1" in
    cal-prev) offset=$((offset - 1)) ;;
    cal-next) offset=$((offset + 1)) ;;
    *) offset=0 ;;
    esac
    printf '%s' "$offset" >"$cache/cal_offset"
    update_calendar
    ;;
esac
