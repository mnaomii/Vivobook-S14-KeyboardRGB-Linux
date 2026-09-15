# Keyboard RGB for the ASUS Vivobook S14

Linux control for the single-zone RGB backlight on the ASUS Vivobook S14 (ITE5570
keyboard controller). There is a command line tool, a background daemon, and a
small GTK4 window.

The keyboard shows up as a HID LampArray device. Windows drivers talk to it the
same way, there is just nothing on Linux that does, so this is a small stack that
does the talking.

## What is in here

| Path | What it does |
| --- | --- |
| `bin/kbdrgb` | One shot CLI. Sets a color, or runs an animation in the foreground until Ctrl-C. |
| `bin/kbdrgbd` | The daemon. Owns the device, reads a state file, keeps effects running. |
| `bin/kbdrgb-gui` | GTK4 / libadwaita window. Writes the state file and starts or stops the daemon. |
| `systemd/kbdrgb.service` | User service so the daemon comes back at login. |
| `udev/99-asus-kbd-rgb.rules` | Grants the local user write access to the hidraw node. |
| `applications/kbdrgb.desktop` | App launcher entry for the GUI. |
| `install.sh` | Installs or uninstalls all of the above. See [Install](#install). |

## How it works

### Finding the keyboard

The device is a raw HID node under `/dev/hidraw*`. The number is not stable,
because hidraw nodes are handed out in enumeration order. A USB mouse left
plugged in across a reboot enumerates first and shifts the keyboard from
`hidraw2` to `hidraw3`.

So instead of hardcoding a node, both the CLI and the daemon walk
`/sys/class/hidraw/*/device/uevent` and look for `HID_ID` matching `0B05:5570`.
Whatever node has that identity is the keyboard. This also stops LampArray
reports going into some unrelated device that happened to take the old number.

### Talking to it

Everything goes through HID feature reports sent with the `HIDIOCSFEATURE`
ioctl. Two reports matter:

- **Report 0x46, control.** One byte payload. `1` means the firmware drives the
  LEDs by itself (that is the rainbow at the GRUB screen). `0` means the firmware
  backs off and the host drives them. It has to be sent before anything else,
  otherwise color writes are ignored.
- **Report 0x45, lamp range update.** Carries a flag byte, a start and end lamp
  index, then R, G, B and an intensity byte. Since this keyboard is one zone, the
  range is always 0 to 0, and one write repaints the whole keyboard.

The daemon also knows a vendor variant of the same pair, 0x35 and 0x36. On the
first write it tries the standard reports, and if the device rejects them it
falls back to the vendor ones, then remembers which set worked. Some firmware
revisions only accept one or the other.

### Why there is a daemon

LampArray has no built in effects. The device only knows "be this color right
now". Anything animated means a process sitting there pushing a new frame 30 or
60 times a second. If that process exits, the animation stops on whatever frame
it was on.

That is why the CLI animations block until Ctrl-C, and it is why the daemon
exists. `kbdrgbd` runs in the background, so a rainbow wave keeps going after the
GUI window closes.

### How the pieces talk to each other

They do not, really. There is no socket or D-Bus service. The GUI writes
`~/.config/kbdrgb/state.json`, the daemon watches that file with a GLib file
monitor and re-renders whenever it changes. The write goes to a temp file and is
then renamed, so the daemon never reads a half written file.

That keeps the GUI dumb. It is a settings editor, nothing more. Editing the file
by hand does the same job:

```json
{"mode": "solid", "color": [0, 170, 255], "intensity": 255, "seconds": 8.0, "fps": 30}
```

- `mode` is `solid`, `wave`, `off`, or `auto` (hands the LEDs back to firmware).
- `color` is RGB, 0 to 255 each. Only used by `solid`.
- `intensity` is 0 to 255. This is the LampArray intensity byte, separate from
  the overall backlight brightness on Fn+F3 and Fn+F4.
- `seconds` is how long one full hue rotation takes in `wave` mode.
- `fps` is the animation frame rate, clamped to 1 to 120. The GUI does not expose
  it, but it preserves the value if it was set by hand.

### Suspend and other annoyances

The firmware takes the LEDs back when the machine suspends. The daemon subscribes
to `PrepareForSleep` from logind, and on resume it drops its file descriptor,
re-resolves the device and redoes the handshake after a short delay. The delay is
there because the device is not ready the instant the signal fires.

If the keyboard is not there at all, or is not writable yet, the daemon does not
exit. It logs once and retries every three seconds. Letting systemd restart it in
a loop would not help, since the problem is usually a device that has not
appeared yet.

### Permissions

Writing to hidraw needs permission that is not granted by default. A udev rule
would normally match on USB vendor and product IDs, but this keyboard sits on
I2C-HID and has no USB IDs, so the rule matches the controller name instead:

```
ATTRS{name}=="ITE5570:00"
```

It sets `TAG+="uaccess"`, which is what lets the logged in user at the seat write
to the node without sudo.

## Install

Requires Python 3, PyGObject, GTK4 and libadwaita. The CLI only needs Python 3;
the daemon and the GUI need the rest.

### With the install script

From the root of this repository, as your normal user (not with sudo):

```sh
./install.sh
```

It asks for your password only for the steps that touch the system. In order, it:

1. Checks that PyGObject, GTK4 and libadwaita import. If not, and `apt-get` is
   available, it installs `python3-gi gir1.2-gtk-4.0 gir1.2-adw-1`. On other
   distros it says what is missing and carries on.
2. Copies `kbdrgb`, `kbdrgbd` and `kbdrgb-gui` to `~/.local/bin`, the launcher to
   `~/.local/share/applications`, and the unit to `~/.config/systemd/user`.
3. Installs the udev rule to `/etc/udev/rules.d` and reloads udev for hidraw
   devices (sudo).
4. Enables `kbdrgb.service` and (re)starts it, so running the script again after
   pulling changes picks up the new daemon.
5. Warns if `~/.local/bin` is not on PATH.

Options:

| Option | Effect |
| --- | --- |
| `--uninstall` | Stops and disables the service, removes every installed file and the udev rule. Leaves `~/.config/kbdrgb/` alone. |
| `--skip-deps` | Skips the dependency check and apt install. |
| `--no-udev` | Skips the udev rule, so nothing runs with sudo. |
| `--no-service` | Installs the unit but does not enable or start it. |
| `-h`, `--help` | Prints usage. |

`PREFIX=/some/path ./install.sh` installs `bin/` and `share/applications/` under
another prefix instead of `~/.local`. The installed unit's `ExecStart` is
rewritten to match. Pass the same `PREFIX` to `--uninstall`.

If the script is run without a systemd user session (over plain ssh, say), it
installs the files and prints the `systemctl --user` commands to run later from
the desktop session.

### By hand

Install the dependencies. On Debian or Ubuntu:

```sh
sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
```

Then:

```sh
install -Dm755 bin/kbdrgb bin/kbdrgbd bin/kbdrgb-gui -t ~/.local/bin/
install -Dm644 applications/kbdrgb.desktop -t ~/.local/share/applications/
install -Dm644 systemd/kbdrgb.service -t ~/.config/systemd/user/

sudo install -Dm644 udev/99-asus-kbd-rgb.rules -t /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger

systemctl --user daemon-reload
systemctl --user enable --now kbdrgb.service
```

`~/.local/bin` has to be on PATH. The systemd unit calls `%h/.local/bin/kbdrgbd`
by full path, so binaries installed anywhere else need that line edited.

## Using it

The GUI shows up as "Keyboard RGB" in the app menu, or runs as `kbdrgb-gui`. It
has a color picker, a hex field, the mode list, an intensity slider, a switch to
start and stop the daemon, and a switch for starting at login. The colored strip
at the top is a local preview drawn with CSS. It does not read the keyboard back,
it only reflects the current selection.

The CLI is for scripts and quick tests:

```sh
kbdrgb ff0000              # solid red
kbdrgb "#3aa" -i 128       # half intensity
kbdrgb off                 # black, backlight LED itself stays on
kbdrgb auto                # gives control back to the firmware
kbdrgb breathe 00aaff      # slow pulse until Ctrl-C
kbdrgb cycle -s 20         # full hue rotation, 20 seconds per turn
kbdrgb wave 0066ff -c2 aa00ff -s 6   # eased sweep between two hues
```

It also takes named colors (`red`, `cyan`, `orange`, and so on), three digit hex,
and `-d` to point it at a specific hidraw node.

Worth knowing: the CLI and the daemon both want to drive the device. With the
daemon running, a `kbdrgb red` from the terminal turns into a fight that the
daemon usually wins. Stopping the daemon first avoids that, and the GUI avoids it
entirely.

## If something is not working

**No light at all.** The backlight brightness comes first:

```sh
cat /sys/class/leds/asus::kbd_backlight/brightness
```

If that reads 0, the LEDs are physically off and no color will show. Fn+F3 and
Fn+F4 bring it back. The CLI warns about this case, the GUI does not.

**Permission denied on /dev/hidrawN.** The udev rule is not applied. Reloading it
with the commands above fixes it, as does a replug or a reboot. To confirm the
rule matches the device:

```sh
udevadm info -a /dev/hidraw3 | grep -i 'name\|ATTRS{name}'
```

**Keyboard 0B05:5570 not found.** The machine has a different controller. To see
which one:

```sh
grep -H . /sys/class/hidraw/*/device/uevent | grep HID_ID
```

If the IDs differ, `HID_IDS` in `bin/kbdrgb` and `bin/kbdrgbd` needs changing,
along with the `ATTRS{name}` match in the udev rule. The report layout is
standard LampArray, so there is a decent chance it still works.

**Daemon not doing anything.** The log says why:

```sh
systemctl --user status kbdrgb.service
journalctl --user -u kbdrgb.service -f
```

## Limits

- One zone. The hardware does not do per key, so neither does this.
- The daemon's wave mode is a full hue circle only. The two color sweep exists in
  the CLI but is not wired into the state file yet.
- No brightness control in the app. That is the `asus::kbd_backlight` LED and it
  belongs to the Fn keys.
