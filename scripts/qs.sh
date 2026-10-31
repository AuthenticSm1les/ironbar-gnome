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
    for tile in wifi bt profile dnd; do
        is_active $tile || continue
        css+="#bar popover button.tile.$tile { background-color: var(--accent); }
#bar popover button.tile.$tile:hover { background-color: var(--accent-hover); }
"
    done
    # calendar: days of the shown month stand out (weekends a bit less),
    # today is a blue circle
    get cal_days; days=$REPLY
    [ -n "$days" ] && css+="$(sel "$days") { font-weight: bold; opacity: 1; }
"
    get cal_we; days=$REPLY
    [ -n "$days" ] && css+="$(sel "$days") { opacity: 0.6; }
"
    get cal_today
    [ -n "$REPLY" ] && css+="#bar popover .cal-grid .day.$REPLY { background-color: var(--accent); font-weight: bold; opacity: 1; }
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

# tile_markup <title> <subtitle> <active>; result in $markup
tile_markup() {
    local title
    escape "$1"; title=$REPLY
    if [ "$3" = 1 ]; then
        markup="<b>$title</b>
<span size='small'>$2</span>"
    else
        markup="<b>$title</b>
<span size='small' alpha='60%'>$2</span>"
    fi
}

# --- quick settings ---

show_wifi() {
    if [ "$1" = 1 ]; then
        tile_markup "$2" On 1
    else
        set_var wifi_icon network-wireless-disabled-symbolic
        tile_markup Wi-Fi Off 0
    fi
    set_var wifi_markup "$markup"
    set_active wifi "$1"
}

show_bt() {
    if [ "$1" = 1 ]; then
        set_var bt_icon bluetooth-active-symbolic
        tile_markup Bluetooth On 1
    else
        set_var bt_icon bluetooth-disabled-symbolic
        tile_markup Bluetooth Off 0
    fi
    set_var bt_markup "$markup"
    set_active bt "$1"
}

show_dnd() {
    if [ "$1" = 1 ]; then
        set_var dnd_icon notifications-disabled-symbolic
        tile_markup "Do Not Disturb" On 1
        set_var dnd_on true
    else
        set_var dnd_icon preferences-system-notifications-symbolic
        tile_markup "Do Not Disturb" Off 0
        set_var dnd_on false
    fi
    set_var dnd_markup "$markup"
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
    # GNOME highlights the tile when not on the default profile
    [ "$1" = balanced ] && active=0
    tile_markup "Power Mode" "$label" $active
    set_var profile "$1"
    set_var profile_icon "power-profile-$1-symbolic"
    set_var profile_markup "$markup"
    set_active profile $active
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
        show_wifi 1 "${ssid:-Wi-Fi}"
    else
        icon=network-wireless-disabled-symbolic
        show_wifi 0
    fi
    if [[ $devs == *ethernet:connected:* ]]; then
        set_var net_icon network-wired-symbolic
    else
        set_var net_icon "$icon"
    fi
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
    [[ $(rfkill list bluetooth) == *"Soft blocked: no"* ]] && show_bt 1 || show_bt 0
}

# --- date menu: clock, notifications, calendar ---

# GNOME's default clock: no weekday, then the unread dot or the
# Do Not Disturb icon (an image in the config, shown through dnd_on)
update_clock() {
    local now
    printf -v now '%(%b %-d  %H:%M)T' -1
    if [ -f "$cache/unread" ] && ! is_active dnd; then
        now+="  <span size='x-small'>●</span>"
    fi
    set_var clock_markup "$now"
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
    for ((i = 0; i < 7; i++)); do set_var "cal_h$((i + 1))" "${names[(i + start) % 7]}" & done

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
        set_var "c$c" "$day" &
    done
    wait
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
# One line each: epoch, id, app, summary, body, icon.
list_notifs() {
    local up now_us
    read -r up _ </proc/uptime
    now_us=$((10#${up/./} * 10000))
    {
        [ -f "$cache/displayed" ] && awk -F"$sep" -v OFS="$sep" '{ print $6, $1, $2, $3, $4, $5 }' "$cache/displayed"
        dunstctl history | jq -r --argjson now "$now_us" --argjson epoch "$EPOCHSECONDS" \
            '.data[0][] | [($epoch - (($now - .timestamp.data) / 1000000 | floor)), .id.data, .appname.data, .summary.data, .body.data, .icon_path.data] | map(tostring | gsub("[\n\t\u001f]"; " ")) | join("\u001f")'
    } | sort -t"$sep" -k1,1nr -k2,2nr
}

# app_icon <app name>; the icon of its .desktop file in $REPLY, or nothing.
# Looked up once per app, as GNOME shows the app's icon in each card's header.
app_icon() {
    local line f
    if [ -f "$cache/appicons" ]; then
        while IFS=$sep read -r f line; do
            [ "$f" = "$1" ] && { REPLY=$line; return; }
        done <"$cache/appicons"
    fi
    REPLY=
    f=$(grep -lisxF -m1 "Name=$1" /usr/share/applications/*.desktop ~/.local/share/applications/*.desktop 2>/dev/null | head -n1)
    [ -n "$f" ] && { REPLY=$(grep -m1 '^Icon=' "$f"); REPLY=${REPLY#Icon=}; }
    printf '%s\n' "$1$sep$REPLY" >>"$cache/appicons"
}

# Fills the five slots, GNOME 48+ style. Each app is one card, stacked when
# it has more; expanding a stack shows only that app, under a header with its
# name. A card's own expand button shows its whole text.
update_notifs() {
    local epoch id app summary body icon slot=0 expanded open n
    local -A count newest
    local -a order lines
    get expanded; expanded=$REPLY
    get open; open=$REPLY
    mapfile -t lines < <(list_notifs)
    for line in "${lines[@]}"; do
        IFS=$sep read -r epoch id app summary body icon <<<"$line"
        app=${app:-Notification}
        [ -z "${count[$app]}" ] && { order+=("$app"); newest[$app]=$line; }
        count[$app]=$(( ${count[$app]:-0} + 1 ))
    done
    [ -n "$expanded" ] && ((${count[$expanded]:-0} > 1)) || expanded=

    fill_slot() {  # <line> <cards stacked under it>
        ((slot >= 5)) && return
        ((++slot))
        local text when full more=false less=false
        IFS=$sep read -r epoch id app summary body icon <<<"$1"
        app=${app:-Notification}
        relative_time $((EPOCHSECONDS - epoch)); when=$REPLY
        truncate "$app" 24
        set_var n${slot}_head "<span size='small' weight='bold' alpha='70%'>$REPLY</span>  <span size='small' alpha='55%'>$when</span>"
        truncate "$summary" 34; text="<b>$REPLY</b>"
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
        app_icon "$app"
        set_var n${slot}_app_icon "icon:${REPLY:-preferences-system-notifications-symbolic}"
        printf '%s' "$id" >"$cache/n${slot}_id"
        printf '%s' "$app" >"$cache/n${slot}_app"
        printf '%s' "$2" >"$cache/n${slot}_stack"
        set_var n${slot}_more "$more"
        set_var n${slot}_less "$less"
        set_var n${slot}_layer1 "$( (($2 >= 1)) && echo true || echo false)"
        set_var n${slot}_layer2 "$( (($2 >= 2)) && echo true || echo false)"
        set_var n${slot}_show true
    }

    if [ -n "$expanded" ]; then
        escape "$expanded"
        set_var group_name "<span size='large' weight='bold'>$REPLY</span>"
        set_var group_show true
        for line in "${lines[@]}"; do
            IFS=$sep read -r epoch id app _ <<<"$line"
            [ "${app:-Notification}" = "$expanded" ] && fill_slot "$line" 0
        done
    else
        set_var group_show false
        for app in "${order[@]}"; do
            n=$((count[$app] - 1))
            fill_slot "${newest[$app]}" $((n > 2 ? 2 : n))
        done
    fi
    if ((slot)); then set_var n_empty false; set_var n_any true
    else set_var n_empty true; set_var n_any false
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
#   notif-new <id> <replaces> <app> <icon> <summary> <body>  (\x1f separated)
#   notif-closed <id>
# A new notification's id is only in dunst's reply, so calls are matched to
# replies by serial. Everything else dunst replies (e.g. history dumps) is dropped.
notif_filter() {
    awk -v SEP="$sep" '
    function field(s) { return substr(s, index(s, "\"") + 1) }
    /^(signal|method call|method return|error) / {
        mode = ""
        if ($0 ~ /member=Notify$/) { mode = "args"; n = 0; inq = 0; s = $0; sub(/.* serial=/, "", s); sub(/ .*/, "", s); serial = s }
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
        if (n == 5) { pending[serial] = val[1] SEP val[0] SEP val[2] SEP val[3] SEP val[4]; mode = "" }
        next
    }
    mode == "reply" && /^   uint32 / { print "notif-new" SEP $2 SEP pending[reply]; fflush(); delete pending[reply]; mode = ""; next }
    mode == "closed" && /^   uint32 / { print "notif-closed " $2; fflush(); mode = ""; next }
    '
}

daemon() {
    local pidfile="$cache/daemon.pids" fifo="$cache/events" pids="" p line bar=$PPID
    local net vol bat profile bt active notif minute last_minute day last_day
    local id replaces app icon summary body

    mkdir -p "$cache"

    # stop a previous daemon and its listeners, which outlive it if it was killed
    if [ -f "$pidfile" ]; then
        for p in $(<"$pidfile"); do
            [[ $(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null) == *@(qs.sh|monitor|subscribe|rfkill|awk)* ]] && kill "$p"
        done
    fi
    trap 'kill $pids 2>/dev/null' EXIT
    trap exit TERM INT HUP

    # ironbar starts with no vars or extra styles, so resend everything;
    # vol stays, as the slider may poll it before update_vol runs
    find "$cache" -maxdepth 1 -type f ! -name vol -delete
    write_state
    ironbar style load-css "$cache/state.css" >/dev/null 2>&1
    update_net; update_vol; update_bat; update_profile; update_bt
    [[ $(dunstctl is-paused) == true ]] && show_dnd 1 || show_dnd 0
    update_clock; update_calendar; update_notifs

    # every listener writes into one fifo, read by a single loop below;
    # the fd is opened read-write so it never hits EOF
    rm -f "$fifo"; mkfifo "$fifo"
    exec 3<>"$fifo"
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
            update_clock
            printf -v day '%(%j)T' -1
            [ "$day" != "$last_day" ] && { update_calendar; last_day=$day; }
            update_notifs  # refreshes the "N min ago" labels
            last_minute=$minute
        fi
        if ! read -r -t 5 -u 3 line; then
            # exit with ironbar
            kill -0 "$bar" 2>/dev/null || exit
            continue
        fi
        # gather a burst of events, then update each source once
        net= vol= bat= profile= bt= notif=
        while :; do
            case "$line" in
            "notif-new$sep"*)
                IFS=$sep read -r _ id replaces app icon summary body <<<"$line"
                touch "$cache/displayed"
                sed -i "/^$id$sep/d; /^$replaces$sep/d" "$cache/displayed"
                printf '%s\n' "$id$sep$app$sep$summary$sep$body$sep$icon$sep$EPOCHSECONDS" >>"$cache/displayed"
                # GNOME's unread dot
                : >"$cache/unread"
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
        [ -n "$net" ] && update_net
        [ -n "$vol" ] && update_vol
        [ -n "$bat" ] && update_bat
        [ -n "$profile" ] && show_profile "$profile"
        [ -n "$bt" ] && update_bt
        [ -n "$notif" ] && { update_clock; update_notifs; }
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
        show_wifi 1 Wi-Fi
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
date-menu)
    ironbar bar main toggle-popup date-menu >/dev/null
    rm -f "$cache/unread"
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
