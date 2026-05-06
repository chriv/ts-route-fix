#!/bin/sh
# ts-route-fix — Site-aware Tailscale route conflict resolver
#
# Detects which configured "site" the machine is currently at (via DNS search
# domains or local IP prefix), then removes conflicting Tailscale routes and
# restores local routing for that site's subnets. Cleans up stale routes from
# previously-visited sites.
#
# Requires root (run via sudo or installed with a sudoers.d drop-in).
#
# Usage: ts-route-fix [-c config_file] [-n] [-q] [-v]
#   -c  Path to sites.conf (default: /etc/ts-route-fix/sites.conf,
#       or $TS_ROUTE_FIX_CONF)
#   -n  Dry-run: print what would be done without executing
#   -q  Quiet: suppress output from route commands (useful for unattended runs)
#   -v  Verbose: show interface/IP details and each command run

set -eu

CONF_FILE="${TS_ROUTE_FIX_CONF:-/etc/ts-route-fix/sites.conf}"
DRY_RUN=0
QUIET=0
VERBOSE=0

# ── Logging ──────────────────────────────────────────────────────────────────────

_now()    { date '+%Y-%m-%d %H:%M:%S'; }
log()     { printf 'ts-route-fix: [%s] %s\n' "$(_now)" "$*"; }
verbose() { [ "$VERBOSE" -eq 1 ] && printf 'ts-route-fix: [%s] %s\n' "$(_now)" "$*" || true; }
die()     { printf 'ts-route-fix: [%s] ERROR: %s\n' "$(_now)" "$*" >&2; exit 1; }

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'ts-route-fix: [DRY-RUN]'; printf ' %s' "$@"; printf '\n'
        return 0
    fi
    [ "$VERBOSE" -eq 1 ] && { printf 'ts-route-fix:   +'; printf ' %s' "$@"; printf '\n'; } || true
    if [ "$QUIET" -eq 1 ]; then
        "$@" >/dev/null 2>&1 || true
    else
        "$@" || true
    fi
}

# ── Argument Parsing ──────────────────────────────────────────────────────────────

while getopts ":c:nqv" opt; do
    case "$opt" in
        c) CONF_FILE="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        q) QUIET=1 ;;
        v) VERBOSE=1 ;;
        :) die "Option -$OPTARG requires an argument" ;;
       \?) die "Unknown option: -$OPTARG" ;;
    esac
done

[ -f "$CONF_FILE" ] || die "Config not found: $CONF_FILE  (set \$TS_ROUTE_FIX_CONF or use -c)"

# ── OS Detection ──────────────────────────────────────────────────────────────────

OS=$(uname -s)
case "$OS" in
    Darwin|Linux) ;;
    *) die "Unsupported OS: $OS" ;;
esac

# ── Interface & Gateway Detection ────────────────────────────────────────────────

detect_ts_if() {
    case "$OS" in
        Darwin)
            # Find the utunX interface that carries the 100.x.x.x Tailscale IP
            ifconfig | awk '/utun[0-9]+:/ { iface = $1 }
                           /inet 100\./   { print iface }' | tr -d ':'
            ;;
        Linux)
            # Prefer the canonical name; fall back to scanning for the 100.x.x.x IP
            if ip link show tailscale0 >/dev/null 2>&1; then
                echo "tailscale0"
            else
                ip -4 addr show | awk '/inet 100\./ { print $NF }'
            fi
            ;;
    esac
}

detect_default_gw() {
    case "$OS" in
        Darwin)
            route -n get default 2>/dev/null | awk '/gateway:/ { print $2 }'
            ;;
        Linux)
            ip route show default 2>/dev/null \
                | awk 'NR==1 { for (i=1; i<NF; i++) if ($i == "via") { print $(i+1); exit } }'
            ;;
    esac
}

# ── Route Operations ──────────────────────────────────────────────────────────────

# Remove a CIDR from the Tailscale interface
ts_route_del() {
    _cidr="$1" _if="$2"
    log "  Removing $_cidr from $_if"
    case "$OS" in
        Darwin)
            # Delete the regular route (gateway = interface)
            run_cmd route -n delete -net "$_cidr" -interface "$_if"
            # Also delete any interface-scoped route (IFSCOPE/UCSI flag).
            # Tailscale creates these when a peer host route exists inside the subnet;
            # they require -ifscope rather than -interface to target them.
            run_cmd route -n delete -ifscope "$_if" -net "$_cidr"
            ;;
        Linux)
            # TODO: Tailscale on Linux installs routes in table 52, not the main
            # table. This command targets the main table and will not find them.
            # Fix: ip route del "$_cidr" table 52
            run_cmd ip route del "$_cidr" dev "$_if"
            ;;
    esac
}

# Add a CIDR via the local default gateway
gw_route_add() {
    _cidr="$1" _gw="$2"
    log "  Adding $_cidr via $_gw"
    case "$OS" in
        Darwin) run_cmd route -n add -net "$_cidr" "$_gw" ;;
        Linux)  run_cmd ip route add "$_cidr" via "$_gw" ;;
    esac
}

# Remove a CIDR regardless of which interface/gateway it's on (stale route cleanup)
route_del_any() {
    _cidr="$1"
    verbose "  Cleaning up stale route $_cidr"
    case "$OS" in
        Darwin) run_cmd route -n delete -net "$_cidr" ;;
        Linux)  run_cmd ip route del "$_cidr" ;;
    esac
}

# ── Route Table Check ────────────────────────────────────────────────────────────
#
# Read the route table ONCE per run and check it in memory.  No per-route
# commands; all comparison is string-matching against a cached variable.

# Convert CIDR notation to BSD netstat display format (macOS only).
# Strips trailing zero octets and omits the prefix length when it coincides
# with the classful boundary (A=/8, B=/16, C=/24).
# Examples: 10.10.16.0/21 -> 10.10.16/21    10.0.0.0/8 -> 10
_cidr_to_netstat() {
    _addr="${1%%/*}" _mask="${1##*/}"
    _o1="${_addr%%.*}"; _r="${_addr#*.}"
    _o2="${_r%%.*}";    _r="${_r#*.}"
    _o3="${_r%%.*}";    _o4="${_r##*.}"

    if   [ "$_o4" != "0" ]; then _net="$_o1.$_o2.$_o3.$_o4"
    elif [ "$_o3" != "0" ]; then _net="$_o1.$_o2.$_o3"
    elif [ "$_o2" != "0" ]; then _net="$_o1.$_o2"
    else                          _net="$_o1"
    fi

    _classful=0
    if   [ "$_o1" -le 127 ] && [ "$_mask" -eq  8 ]; then _classful=1
    elif [ "$_o1" -ge 128 ] && [ "$_o1" -le 191 ] && [ "$_mask" -eq 16 ]; then _classful=1
    elif [ "$_o1" -ge 192 ] && [ "$_o1" -le 223 ] && [ "$_mask" -eq 24 ]; then _classful=1
    fi

    [ "$_classful" -eq 1 ] && printf '%s' "$_net" || printf '%s/%s' "$_net" "$_mask"
}

# Snapshot the routing table into a variable (called once per run).
_read_route_table() {
    case "$OS" in
        Darwin) netstat -rn -f inet 2>/dev/null ;;
        Linux)  ip route show table 52 2>/dev/null ;;
    esac
}

# Returns 0 if the given CIDR is currently present on the Tailscale interface.
_ts_route_present() {
    _cidr="$1"
    case "$OS" in
        Darwin)
            _net=$(_cidr_to_netstat "$_cidr")
            printf '%s\n' "$ROUTE_TABLE" | awk -v n="$_net" -v i="$TS_IF" \
                '$1 == n && $NF == i { found=1 } END { exit 1-found }'
            ;;
        Linux)
            printf '%s\n' "$ROUTE_TABLE" | grep -q "^${_cidr} "
            ;;
    esac
}

# Returns 0 (fix needed) if any TS_REMOVE_ROUTES for the matched site are
# still present on the Tailscale interface.
_needs_fix() {
    [ -n "$MATCHED_TS_ROUTES" ] || return 1
    _IFS_SAVE="$IFS"; IFS=','
    for _r in $MATCHED_TS_ROUTES; do
        if _ts_route_present "$_r"; then
            IFS="$_IFS_SAVE"
            verbose "  TS route $_r still on $TS_IF — fix needed"
            return 0
        fi
    done
    IFS="$_IFS_SAVE"
    return 1
}

# ── Site Matching Helpers ─────────────────────────────────────────────────────────

# Returns 0 if any comma-separated needle in $2 appears as a substring of $1
domains_match() {
    _haystack="$1"
    _IFS_SAVE="$IFS"; IFS=','
    # shellcheck disable=SC2086  # intentional word-split on comma-separated $2
    for _d in $2; do
        case "$_haystack" in
            *"$_d"*) IFS="$_IFS_SAVE"; return 0 ;;
        esac
    done
    IFS="$_IFS_SAVE"
    return 1
}

# Returns 0 if any newline-separated IP in $1 starts with any comma-separated prefix in $2
ips_match_prefix() {
    _prefixes="$2"
    # Read IPs line-by-line to avoid IFS interference with newlines
    while IFS= read -r _ip; do
        [ -z "$_ip" ] && continue
        _IFS_SAVE="$IFS"; IFS=','
        # shellcheck disable=SC2086
        for _p in $_prefixes; do
            case "$_ip" in
                "${_p}"*) IFS="$_IFS_SAVE"; return 0 ;;
            esac
        done
        IFS="$_IFS_SAVE"
    done <<EOF
$1
EOF
    return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────────

TS_IF=$(detect_ts_if)
if [ -z "$TS_IF" ]; then
    verbose "Tailscale not running — skipping"
    exit 0
fi

LOCAL_GW=$(detect_default_gw)
if [ -z "$LOCAL_GW" ]; then
    verbose "No default gateway — skipping"
    exit 0
fi

SEARCH_DOMAINS=$(grep "^search" /etc/resolv.conf 2>/dev/null | cut -d' ' -f2- || true)

if [ "$OS" = "Darwin" ]; then
    LOCAL_IPS=$(ifconfig | awk '/inet / && !/127\./ && !/100\./ { print $2 }')
else
    LOCAL_IPS=$(ip -4 addr show | awk '/inet / && !/127\./ && !/100\./ { split($2,a,"/"); print a[1] }')
fi

verbose "Tailscale interface : $TS_IF"
verbose "Default gateway     : $LOCAL_GW"
verbose "Search domains      : $SEARCH_DOMAINS"
verbose "Local IPs           : $(printf '%s ' $LOCAL_IPS)"

MATCHED_SITE=""
MATCHED_TS_ROUTES=""
MATCHED_GW_ROUTES=""

# ── Pass 1: Find the current site ─────────────────────────────────────────────────

while IFS='|' read -r _name _domains _ip_prefix _ts_routes _gw_routes; do
    case "$_name" in ''|\#*) continue ;; esac

    _matched=0

    if [ -n "$_domains" ] && [ -n "$SEARCH_DOMAINS" ]; then
        domains_match "$SEARCH_DOMAINS" "$_domains" && _matched=1
    fi

    if [ "$_matched" -eq 0 ] && [ -n "$_ip_prefix" ] && [ -n "$LOCAL_IPS" ]; then
        ips_match_prefix "$LOCAL_IPS" "$_ip_prefix" && _matched=1
    fi

    if [ "$_matched" -eq 1 ]; then
        MATCHED_SITE="$_name"
        MATCHED_TS_ROUTES="${_ts_routes:-}"
        MATCHED_GW_ROUTES="${_gw_routes:-}"
        break
    fi
done < "$CONF_FILE"

if [ -z "$MATCHED_SITE" ]; then
    verbose "No site matched — skipping"
    exit 0
fi

verbose "Matched site        : $MATCHED_SITE"

# ── Route table check ─────────────────────────────────────────────────────────────
# Read the table once; _needs_fix compares in memory — no further commands needed
# if routes are already correct.

ROUTE_TABLE=$(_read_route_table)

if ! _needs_fix; then
    verbose "Routes already correct for '$MATCHED_SITE' — nothing to do"
    exit 0
fi

# ── Pass 2: Apply fix ─────────────────────────────────────────────────────────────

log "Location: $MATCHED_SITE — fixing routes"

if [ -n "$MATCHED_TS_ROUTES" ]; then
    _IFS_SAVE="$IFS"; IFS=','
    for _r in $MATCHED_TS_ROUTES; do
        ts_route_del "$_r" "$TS_IF"
    done
    IFS="$_IFS_SAVE"
fi

if [ -n "$MATCHED_GW_ROUTES" ]; then
    _IFS_SAVE="$IFS"; IFS=','
    for _r in $MATCHED_GW_ROUTES; do
        gw_route_add "$_r" "$LOCAL_GW"
    done
    IFS="$_IFS_SAVE"
fi

# ── Pass 3: Clean up stale GW routes from non-matched sites ───────────────────────

while IFS='|' read -r _name _domains _ip_prefix _ts_routes _gw_routes; do
    case "$_name" in ''|\#*) continue ;; esac
    [ "$_name" = "$MATCHED_SITE" ] && continue

    _gw_routes="${_gw_routes:-}"
    if [ -n "$_gw_routes" ]; then
        _IFS_SAVE="$IFS"; IFS=','
        for _r in $_gw_routes; do
            route_del_any "$_r"
        done
        IFS="$_IFS_SAVE"
    fi
done < "$CONF_FILE"

log "Done."
