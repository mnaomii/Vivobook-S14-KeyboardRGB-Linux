#!/usr/bin/env bash
# Install (or uninstall) Keyboard RGB for the ASUS Vivobook S14.
#
# Runs as your normal user. Binaries, the launcher and the systemd user unit go
# under your home directory; only the udev rule needs sudo.
#
#   ./install.sh               install everything and start the daemon
#   ./install.sh --uninstall   remove everything the installer put down
#
# Options:
#   --skip-deps    do not check for or install PyGObject / GTK4 / libadwaita
#   --no-udev      do not install the udev rule (skips sudo entirely)
#   --no-service   do not enable or start the systemd user service
#   -h, --help     show this help
#
# PREFIX (default ~/.local) moves where bin/ and share/applications/ go.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PREFIX=${PREFIX:-$HOME/.local}
BIN_DIR=$PREFIX/bin
APP_DIR=$PREFIX/share/applications
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
UDEV_DIR=/etc/udev/rules.d

BINS=(kbdrgb kbdrgbd kbdrgb-gui)
DESKTOP=kbdrgb.desktop
UNIT=kbdrgb.service
RULE=99-asus-kbd-rgb.rules

uninstall=0 deps=1 udev=1 service=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }

for arg in "$@"; do
    case $arg in
        --uninstall)  uninstall=1 ;;
        --skip-deps)  deps=0 ;;
        --no-udev)    udev=0 ;;
        --no-service) service=0 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "unknown option: $arg" ;;
    esac
done

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (sudo is used only for the udev rule)"

# systemctl --user needs the session bus; without it (e.g. plain ssh) skip quietly.
have_user_systemd() {
    command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1
}

reload_udev() {
    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=hidraw
}

do_uninstall() {
    if [[ $service -eq 1 ]] && have_user_systemd; then
        say "Stopping and disabling $UNIT"
        systemctl --user disable --now "$UNIT" 2>/dev/null || true
    fi

    say "Removing files from $PREFIX and $UNIT_DIR"
    for b in "${BINS[@]}"; do rm -f "$BIN_DIR/$b"; done
    rm -f "$APP_DIR/$DESKTOP" "$UNIT_DIR/$UNIT"
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$APP_DIR" || true

    if [[ $service -eq 1 ]] && have_user_systemd; then
        systemctl --user daemon-reload
    fi

    if [[ $udev -eq 1 && -e $UDEV_DIR/$RULE ]]; then
        say "Removing udev rule (needs sudo)"
        sudo rm -f "$UDEV_DIR/$RULE"
        reload_udev
    fi

    say "Uninstalled. Your settings in ~/.config/kbdrgb/ were left in place."
}

check_deps() {
    local probe='import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1"); from gi.repository import Adw, Gio, GLib, Gtk'
    command -v python3 >/dev/null || die "python3 is required"
    if python3 -c "$probe" 2>/dev/null; then
        return
    fi

    if command -v apt-get >/dev/null; then
        say "Installing PyGObject, GTK4 and libadwaita (needs sudo)"
        sudo apt-get install -y python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
        python3 -c "$probe" 2>/dev/null || die "dependencies still not importable after install"
    else
        warn "PyGObject with GTK4 and libadwaita was not found."
        warn "Install them with your package manager (python3-gobject, gtk4, libadwaita)."
        warn "The CLI will still work; the daemon and GUI will not."
    fi
}

do_install() {
    if [[ $deps -eq 1 ]]; then check_deps; fi

    say "Installing binaries to $BIN_DIR"
    install -Dm755 -t "$BIN_DIR" "${BINS[@]/#/bin/}"

    say "Installing launcher to $APP_DIR"
    install -Dm644 -t "$APP_DIR" "applications/$DESKTOP"
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$APP_DIR" || true

    say "Installing systemd user unit to $UNIT_DIR"
    mkdir -p "$UNIT_DIR"
    # The unit hardcodes %h/.local/bin; point it at wherever the daemon really went.
    sed "s|^ExecStart=.*|ExecStart=$BIN_DIR/kbdrgbd|" "systemd/$UNIT" > "$UNIT_DIR/$UNIT"
    chmod 644 "$UNIT_DIR/$UNIT"

    if [[ $udev -eq 1 ]]; then
        say "Installing udev rule to $UDEV_DIR (needs sudo)"
        sudo install -Dm644 -t "$UDEV_DIR" "udev/$RULE"
        reload_udev
    fi

    if [[ $service -eq 1 ]]; then
        if have_user_systemd; then
            say "Enabling and starting $UNIT"
            systemctl --user daemon-reload
            systemctl --user enable "$UNIT"
            systemctl --user restart "$UNIT"
        else
            warn "no systemd user session found; run these from your desktop session:"
            warn "  systemctl --user daemon-reload && systemctl --user enable --now $UNIT"
        fi
    fi

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR is not on your PATH; add it to use kbdrgb and kbdrgb-gui from a terminal." ;;
    esac

    say "Done. Open \"Keyboard RGB\" from the app menu, or run kbdrgb-gui."
}

if [[ $uninstall -eq 1 ]]; then
    do_uninstall
else
    do_install
fi
