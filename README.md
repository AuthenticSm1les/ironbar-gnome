# ironbar-gnome

An [ironbar](https://github.com/JakeStanger/ironbar) config that mimics the GNOME Shell top bar, for Hyprland.

- Workspace pills on the left, date and time in the centre with a calendar popup
- Status indicators on the right opening a quick settings menu: battery, lock/reboot/power off,
  volume and brightness sliders, and Wi-Fi, Network, Power Mode and Bluetooth tiles

## Requirements

- ironbar 0.19
- NetworkManager (`nmcli`), PipeWire (`wpctl`, `pactl`), UPower, power-profiles-daemon,
  `rfkill`, `brightnessctl`, `busctl`/`gdbus`, `hyprlock`, `nm-connection-editor`
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
power profile and rfkill events, and pushes state into ironbar variables, so nothing is polled
except the two slider positions. Tile highlights come from a generated stylesheet that ironbar
hot-reloads, so toggling never resizes the menu.
