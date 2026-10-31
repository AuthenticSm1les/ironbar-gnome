#!/usr/bin/env bash
# Helpers for the GNOME-style quick settings menu.
#
# `qs.sh daemon` listens for system events and pushes state into ironvars,
# so the bar updates instantly instead of polling. Toggles set the new state
# optimistically before acting, and the daemon corrects it if the action fails.
#
# Tile highlights come from a generated stylesheet (state.css) that ironbar
# hot-reloads, so a tile changes colour in place without widgets being
# swapped, which would resize the menu.

shopt -s extglob

cache="${XDG_RUNTIME_DIR:-/tmp}/ironbar-qs"

# Only sends changed values, as every update makes ironbar re-render.
# The cache is shared between the daemon and the click handlers.
set_var() {
    [ -f "$cache/$1" ] && [ "$(<"$cache/$1")" = "$2" ] && return
    printf '%s' "$2" >"$cache/$1"
    ironbar var set "$1" "$2" >/dev/null 2>&1
}

is_active() { [ -f "$cache/$1_active" ] && [ "$(<"$cache/$1_active")" = 1 ]; }

write_state() {
    local css="" tile
    for tile in wifi bt profile; do
        is_active $tile || continue
        css+="#bar popover button.tile.$tile { background-color: var(--accent); }
#bar popover button.tile.$tile:hover { background-color: var(--accent-hover); }
"
    done
    printf '%s' "$css" >"$cache/state.css"
}

# Highlights a tile (1) or not (0).
set_active() {
    [ -f "$cache/$1_active" ] && [ "$(<"$cache/$1_active")" = "$2" ] && return
    printf '%s' "$2" >"$cache/$1_active"
    write_state
}

# tile_markup <title> <subtitle> <active>; result in $markup
tile_markup() {
    local title=${1//&/&amp;}
    title=${title//</&lt;}
    title=${title//>/&gt;}
    if [ "$3" = 1 ]; then
        markup="<b>$title</b>
<span size='small'>$2</span>"
    else
        markup="<b>$title</b>
<span size='small' alpha='60%'>$2</span>"
    fi
}

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

update_bat() {
    local bat=/sys/class/power_supply/BAT0 cap status lvl icon
    [ -d "$bat" ] || return
    cap=$(<$bat/capacity)
    status=$(<$bat/status)
    lvl=$(( (cap + 5) / 10 * 10 ))
    if [ "$status" = Full ] || [ "$lvl" -ge 100 ]; then icon=battery-level-100-symbolic
    elif [ "$status" = Charging ]; then icon="battery-level-$lvl-charging-symbolic"
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

daemon() {
    local pidfile="$cache/daemon.pids" fifo="$cache/events" pids="" p line bar=$PPID
    local net vol bat profile bt active

    mkdir -p "$cache"

    # stop a previous daemon and its listeners, which outlive it if it was killed
    if [ -f "$pidfile" ]; then
        for p in $(<"$pidfile"); do
            [[ $(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null) == *@(qs.sh|monitor|subscribe|rfkill)* ]] && kill "$p"
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

    # every listener writes into one fifo, read by a single loop below;
    # the fd is opened read-write so it never hits EOF
    rm -f "$fifo"; mkfifo "$fifo"
    exec 3<>"$fifo"
    nmcli monitor >&3 & pids+=" $!"
    pactl subscribe >&3 & pids+=" $!"
    upower --monitor >&3 & pids+=" $!"
    gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles >&3 & pids+=" $!"
    rfkill event >&3 & pids+=" $!"
    echo "$$$pids" >"$pidfile"

    while :; do
        if ! read -r -t 5 -u 3 line; then
            # exit with ironbar
            kill -0 "$bar" 2>/dev/null || exit
            continue
        fi
        # gather a burst of events, then update each source once
        net= vol= bat= profile= bt=
        while :; do
            case "$line" in
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
profile-cycle)
    # cached value, so rapid clicks step from the last shown profile
    case "$(<"$cache/profile")" in
    balanced) next=performance ;;
    performance) next=power-saver ;;
    *) next=balanced ;;
    esac
    show_profile "$next"
    busctl set-property "${pp[@]}" s "$next"
    ;;
esac
