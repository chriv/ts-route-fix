#!/bin/sh
# setup.sh — installer/uninstaller for ts-route-fix (macOS and Linux)
#
# Usage:
#   sudo ./setup.sh             Install ts-route-fix
#   sudo ./setup.sh --uninstall Remove ts-route-fix
#   sudo ./setup.sh --help      Show this help

set -eu

INSTALL_BIN="/usr/local/bin/ts-route-fix"
CONF_DIR="/etc/ts-route-fix"
CONF_FILE="$CONF_DIR/sites.conf"
SUDOERS_FILE="/etc/sudoers.d/ts-route-fix"

log()  { printf 'setup: %s\n' "$*"; }
warn() { printf 'setup: WARNING: %s\n' "$*" >&2; }
die()  { printf 'setup: ERROR: %s\n' "$*" >&2; exit 1; }

# ── Mode selection ────────────────────────────────────────────────────────────────

case "${1:-}" in
    --uninstall) MODE=uninstall ;;
    --help|-h)
        printf 'Usage: sudo %s [--uninstall]\n' "$0"
        printf '  (no args)     Install ts-route-fix\n'
        printf '  --uninstall   Remove ts-route-fix\n'
        exit 0
        ;;
    '') MODE=install ;;
    *) die "Unknown argument: $1  (try --help)" ;;
esac

# ── Uninstall ────────────────────────────────────────────────────────────────────

do_uninstall() {
    log "Uninstalling ts-route-fix..."

    case "$OS" in
        Darwin)
            PLIST_DST="/Library/LaunchDaemons/org.ts-route-fix.plist"
            if [ -f "$PLIST_DST" ]; then
                log "Removing LaunchDaemon..."
                launchctl bootout system "$PLIST_DST" 2>/dev/null \
                    || launchctl unload "$PLIST_DST" 2>/dev/null \
                    || true
                rm -f "$PLIST_DST"
                log "  Removed $PLIST_DST"
            fi
            ;;
        Linux)
            for _hook in \
                /etc/NetworkManager/dispatcher.d/ts-route-fix \
                /etc/networkd-dispatcher/routable.d/ts-route-fix; do
                if [ -f "$_hook" ]; then
                    rm -f "$_hook"
                    log "  Removed $_hook"
                fi
            done
            ;;
    esac

    [ -f "$SUDOERS_FILE" ] && { rm -f "$SUDOERS_FILE"; log "  Removed $SUDOERS_FILE"; } || true
    [ -f "$INSTALL_BIN"  ] && { rm -f "$INSTALL_BIN";  log "  Removed $INSTALL_BIN";  } || true

    if [ -d "$CONF_DIR" ]; then
        if [ -t 0 ]; then
            printf 'setup: Remove config directory %s (contains your sites.conf)? [y/N] ' "$CONF_DIR"
            read -r _answer
            case "$_answer" in
                [Yy]*) rm -rf "$CONF_DIR"; log "  Removed $CONF_DIR" ;;
                *)     log "  Kept $CONF_DIR — remove manually if desired" ;;
            esac
        else
            log "  Kept $CONF_DIR (non-interactive — remove manually if desired)"
        fi
    fi

    printf '\n'
    log "Uninstall complete."
    printf '\n'
}

# ── Preflight ─────────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || die "Must be run as root. Try: sudo $0 ${1:-}"

OS=$(uname -s)
case "$OS" in
    Darwin|Linux) ;;
    *) die "Unsupported OS: $OS" ;;
esac

[ "$MODE" = "uninstall" ] && { do_uninstall; exit 0; }

# Locate the repo directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$SCRIPT_DIR/ts-route-fix.sh" ] \
    || die "ts-route-fix.sh not found in $SCRIPT_DIR — run setup.sh from the repo directory"

if ! command -v tailscale >/dev/null 2>&1; then
    warn "'tailscale' not found in PATH. Install Tailscale before using ts-route-fix."
fi

# ── Install binary ────────────────────────────────────────────────────────────────

log "Installing ts-route-fix to $INSTALL_BIN..."
mkdir -p "$(dirname "$INSTALL_BIN")"
cp "$SCRIPT_DIR/ts-route-fix.sh" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
log "  Done."

# ── Config directory ──────────────────────────────────────────────────────────────

log "Creating config directory $CONF_DIR..."
mkdir -p "$CONF_DIR"

if [ -f "$CONF_FILE" ] && [ -f "$SCRIPT_DIR/config/sites.conf" ]; then
    # Both the installed config and a repo config exist — ask which to keep
    if [ -t 0 ]; then
        printf 'setup: %s already exists and config/sites.conf is also present.\n' "$CONF_FILE"
        printf 'setup: Overwrite installed config with repo version? [y/N] '
        read -r _answer
        case "$_answer" in
            [Yy]*)
                cp "$SCRIPT_DIR/config/sites.conf" "$CONF_FILE"
                log "  Replaced $CONF_FILE with config/sites.conf."
                ;;
            *)
                log "  Keeping existing $CONF_FILE."
                ;;
        esac
    else
        log "  $CONF_FILE already exists — leaving it in place (non-interactive)."
    fi
elif [ -f "$CONF_FILE" ]; then
    log "  $CONF_FILE already exists — leaving it in place."
elif [ -f "$SCRIPT_DIR/config/sites.conf" ]; then
    cp "$SCRIPT_DIR/config/sites.conf" "$CONF_FILE"
    log "  Copied config/sites.conf to $CONF_FILE."
else
    cp "$SCRIPT_DIR/config/sites.conf.example" "$CONF_FILE"
    log "  Copied sites.conf.example to $CONF_FILE (edit before first use)."
fi

# ── Sudoers drop-in ───────────────────────────────────────────────────────────────

# Identify the target user: prefer $SUDO_USER (set when invoked via sudo),
# fall back to prompting when running directly as root.
INSTALL_USER="${SUDO_USER:-}"

if [ -z "$INSTALL_USER" ] && [ -t 0 ]; then
    printf 'setup: Username to grant passwordless sudo for ts-route-fix (blank to skip): '
    read -r INSTALL_USER
fi

if [ -z "$INSTALL_USER" ]; then
    warn "No username provided — skipping sudoers setup."
    warn "To add manually, see sudoers.d/ts-route-fix.example in the repo."
elif [ ! -d /etc/sudoers.d ]; then
    warn "/etc/sudoers.d not found — skipping sudoers setup."
    warn "Add the following to /etc/sudoers with visudo:"
    warn "  $INSTALL_USER ALL=(ALL) NOPASSWD: $INSTALL_BIN"
else
    log "Installing sudoers drop-in for user '$INSTALL_USER'..."
    printf '%s\n' "$INSTALL_USER ALL=(ALL) NOPASSWD: $INSTALL_BIN" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"

    if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        log "  Installed and validated: $SUDOERS_FILE"
    else
        rm -f "$SUDOERS_FILE"
        warn "visudo validation failed — sudoers file removed."
        warn "Add the entry manually with visudo:"
        warn "  $INSTALL_USER ALL=(ALL) NOPASSWD: $INSTALL_BIN"
    fi
fi

# ── Network hook ─────────────────────────────────────────────────────────────────

case "$OS" in
    Darwin)
        PLIST_SRC="$SCRIPT_DIR/launchd/org.ts-route-fix.plist"
        PLIST_DST="/Library/LaunchDaemons/org.ts-route-fix.plist"
        log "Installing LaunchDaemon..."
        # Unload first if already running so plist changes take effect
        if launchctl list org.ts-route-fix >/dev/null 2>&1; then
            log "  Stopping existing daemon..."
            launchctl bootout system "$PLIST_DST" 2>/dev/null \
                || launchctl unload "$PLIST_DST" 2>/dev/null \
                || true
        fi
        cp "$PLIST_SRC" "$PLIST_DST"
        chmod 644 "$PLIST_DST"
        chown root:wheel "$PLIST_DST"
        # Try modern bootstrap first, fall back to legacy load
        if launchctl bootstrap system "$PLIST_DST" 2>/dev/null; then
            log "  Bootstrapped: $PLIST_DST"
        elif launchctl load -w "$PLIST_DST" 2>/dev/null; then
            log "  Loaded: $PLIST_DST"
        else
            warn "Could not activate LaunchDaemon automatically."
            warn "Reboot, or run: sudo launchctl bootstrap system $PLIST_DST"
        fi
        log "  ts-route-fix will run automatically when Tailscale connects."
        log "  Logs: /var/log/ts-route-fix.log"
        ;;
    Linux)
        HOOK_SRC="$SCRIPT_DIR/linux/ts-route-fix-hook"
        HOOK_INSTALLED=0

        if [ -d /etc/NetworkManager/dispatcher.d ]; then
            log "Installing NetworkManager dispatcher hook..."
            cp "$HOOK_SRC" /etc/NetworkManager/dispatcher.d/ts-route-fix
            chmod 755 /etc/NetworkManager/dispatcher.d/ts-route-fix
            log "  Installed: /etc/NetworkManager/dispatcher.d/ts-route-fix"
            HOOK_INSTALLED=1
        fi

        if [ -d /etc/networkd-dispatcher/routable.d ]; then
            log "Installing networkd-dispatcher hook..."
            cp "$HOOK_SRC" /etc/networkd-dispatcher/routable.d/ts-route-fix
            chmod 755 /etc/networkd-dispatcher/routable.d/ts-route-fix
            log "  Installed: /etc/networkd-dispatcher/routable.d/ts-route-fix"
            HOOK_INSTALLED=1
        fi

        if [ "$HOOK_INSTALLED" -eq 0 ]; then
            warn "No supported network dispatcher found (NetworkManager or networkd-dispatcher)."
            warn "See linux/ts-route-fix-hook for manual installation instructions."
        fi
        ;;
esac

# ── Done ──────────────────────────────────────────────────────────────────────────

printf '\n'
log "Installation complete."
printf '\n'
log "  Edit your site definitions:"
log "    \${EDITOR:-vi} $CONF_FILE"
printf '\n'
log "  Then test before your first real run:"
log "    sudo ts-route-fix -n -v"
printf '\n'
