# ironbar-gnome

An [ironbar](https://github.com/JakeStanger/ironbar) config that mimics the GNOME Shell 51 top bar, for Hyprland.

![Date menu](screenshots/date-menu.png)
![Quick settings](screenshots/quick-settings.png)

- Workspace pills on the left
- Date and time in the centre, with an unread dot or a Do Not Disturb icon, opening GNOME's
  date menu: notifications on the left, one card per app with its other notifications as
  layers underneath (click a stack to expand it, ∨ to read a long message, × to dismiss),
  and Clear; on the right the date, a month calendar you can page through, and the events card
- Status indicators on the right opening a quick settings menu: battery, lock/reboot/power off,
  volume and brightness sliders, and Wi-Fi, Network, Power Mode, Bluetooth and Do Not Disturb
  tiles
- GNOME 49+ battery icons, including "plugged in, not charging" and "fully charged"

## Requirements

- ironbar 0.19
- NetworkManager (`nmcli`), PipeWire (`wpctl`, `pactl`), UPower, power-profiles-daemon,
  `rfkill`, `brightnessctl`, `busctl`/`gdbus`, `hyprlock`, `nm-connection-editor`
- dunst (`dunstctl`), `dbus-monitor` and `jq` for the notification list
- `socat` (optional, makes updates faster by talking to ironbar's socket directly)
- Adwaita icon theme and Adwaita Sans font

## Install

```sh
git clone https://github.com/AuthenticSm1les/ironbar-gnome ~/.config/ironbar
```

The brightness slider reads `/sys/class/backlight/intel_backlight` with a maximum of 7500.
Adjust `value` and `max` in `config.corn` for your backlight device
(see `/sys/class/backlight/*/max_brightness`).

## How it works

`scripts/qs.sh daemon` is started by the bar. It listens for NetworkManager, PipeWire, UPower,
power profile, rfkill and notification events, and pushes state into ironbar variables, so
nothing is polled except the two slider positions. Notifications are tracked from D-Bus while
on screen and read from dunst's history once closed; the menu shows up to five cards.
State-dependent styles (tile highlights, stacks, calendar days) come from a generated
stylesheet that ironbar hot-reloads, so things never resize the menus.

The events card is static: there is no calendar backend.
