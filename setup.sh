#!/bin/sh
# setup.sh — installer for ts-route-fix (macOS and Linux)
#
# Usage: sudo ./setup.sh
#
# Installs ts-route-fix to /usr/local/bin, creates /etc/ts-route-fix/,
# seeds an example sites.conf if none exists, and optionally installs a
# sudoers drop-in so the target user can run the script without a password.

set -eu

INSTALL_BIN="/usr/local/bin/ts-route-fix"
CONF_DIR="/etc/ts-route-fix"
CONF_FILE="$CONF_DIR/sites.conf"
SUDOERS_FILE="/etc/sudoers.d/ts-route-fix"

log()  { printf 'setup: %s\n' "$*"; }
warn() { printf 'setup: WARNING: %s\n' "$*" >&2; }
die()  { printf 'setup: ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || die "Must be run as root. Try: sudo $0"

OS=$(uname -s)
case "$OS" in
    Darwin|Linux) ;;
    *) die "Unsupported OS: $OS" ;;
esac

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

if [ -f "$CONF_FILE" ]; then
    log "  $CONF_FILE already exists — leaving it in place."
else
    cp "$SCRIPT_DIR/config/sites.conf.example" "$CONF_FILE"
    log "  Copied sites.conf.example to $CONF_FILE."
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
