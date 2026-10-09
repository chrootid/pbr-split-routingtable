#!/bin/sh
# pbr-split-bsd.sh - policy-routing split of default routes for the BSDs
# (FreeBSD, OpenBSD, NetBSD, DragonFlyBSD).
#
# Native equivalent of pbr-split-routingtable.sh for hosts with several
# default routes / WAN ports (OpenStack multi-port instances, multi-WAN
# edge boxes). Uses Packet Filter (PF) anchors with route-to / reply-to
# so each port's IPs leave via their own gateway, without requiring a
# custom kernel with multiple FIBs/ROUTETABLES.
#
# Why PF and not FIBs:
#   - FreeBSD/DragonFly need `options ROUTETABLES=N` to get >1 FIB
#   - OpenBSD removed multiple FIBs entirely
#   - NetBSD multi-FIB is not the default configuration
#   - PF is in base on all four; route-to works on a stock kernel
#
# What it does:
#   - primary default route (the one in the routing table) stays as-is
#   - every other interface that has a known gateway gets PF rules:
#       pass out quick from <ip>/32 to any route-to (<if> <gw>)
#       pass in  quick on <if> reply-to (<if> <gw>) to <ip>/32
#   - rules live in the PF anchor "pbr-split" (auto-referenced from
#     pf.conf, flushed/reloaded idempotently on every apply)
#
# Usage:
#   pbr-split-bsd.sh [apply]   (re)apply the split (default; idempotent)
#   pbr-split-bsd.sh watch     apply, then re-apply every PBR_POLL_SECONDS
#                              when the network state fingerprint changes
#   pbr-split-bsd.sh restore   flush our PF anchor rules
#   pbr-split-bsd.sh status    show defaults, gateways and PF anchor rules
#
# Environment:
#   PBR_WAIT_SECONDS   how long the first apply waits for a default route
#                      (default 0; the rc.d units set 30)
#   PBR_POLL_SECONDS   watch poll interval (default 15)
#   PBR_ANCHOR         PF anchor name (default pbr-split)
#   PBR_PF_CONF        path to pf.conf (default /etc/pf.conf)
#   PBR_GATEWAYS       optional manual gateways, e.g.
#                      "em1:10.0.1.1,em2:10.0.2.1" (overrides lease files)
#   PBR_PRIMARY        optional primary interface name (default: the
#                      interface of the current default route)
#
# Gateway discovery (first match wins per interface):
#   1. PBR_GATEWAYS
#   2. /etc/pbr-split.conf lines:  <interface> <gateway>
#   3. dhclient lease files:       /var/db/dhclient.leases.<if>
#      and the combined            /var/db/dhclient.leases
#   4. dhcpcd lease files:         /var/db/dhcpcd-<if>.lease
#      (NetBSD default dhcpcd; also used on some FreeBSD/OpenBSD setups)
#
# Notes:
#   - IPv4 only
#   - PF is enabled if it is not already; a backup of pf.conf is written
#     to pf.conf.pbr-split.bak the first time the anchor line is inserted
#   - selftest is Linux-only (needs netns); on BSD use `status` and
#     /tool-free checks below after apply
#   - written against FreeBSD 13/14, OpenBSD 7.x, NetBSD 10.x,
#     DragonFly 6.x base tools; verify on a lab box before production

set -u

ANCHOR="${PBR_ANCHOR:-pbr-split}"
PF_CONF="${PBR_PF_CONF:-/etc/pf.conf}"
WAIT_SECONDS="${PBR_WAIT_SECONDS:-0}"
POLL_SECONDS="${PBR_POLL_SECONDS:-15}"
GATEWAYS_ENV="${PBR_GATEWAYS:-}"
PRIMARY_IF="${PBR_PRIMARY:-}"
CONF_FILE="${PBR_CONF:-/etc/pbr-split.conf}"

_log() {
	echo "pbr-split: $*"
}

_die() {
	echo "pbr-split: ERROR: $*" >&2
	exit 1
}

_require_root() {
	[ "$(id -u)" -eq 0 ] || _die "requires root or sudo"
	_os_detect
	_require_tools
}

_os_detect() {
	OS=$(uname -s)
	case "$OS" in
	FreeBSD | DragonFly | OpenBSD | NetBSD) ;;
	*) _die "unsupported OS: $OS (this script is for FreeBSD, OpenBSD, NetBSD, DragonFlyBSD)" ;;
	esac
}

_require_tools() {
	for t in route ifconfig pfctl netstat awk sed grep; do
		command -v "$t" >/dev/null 2>&1 ||
			_die "missing required tool: $t"
	done
}

# ---------------------------------------------------------------------------
# network state discovery
# ---------------------------------------------------------------------------

# Current default route: prints "<interface> <gateway>" or nothing.
_default_if_gw() {
	out=$(route -n get default 2>/dev/null) || return 0
	ifn=$(printf '%s\n' "$out" | awk '/interface:/ { print $2; exit }')
	gw=$(printf '%s\n' "$out" | awk '/gateway:/ { print $2; exit }')
	[ -n "$ifn" ] && [ -n "$gw" ] && [ "$gw" != "-" ] && printf '%s %s\n' "$ifn" "$gw"
}

# IPv4 addresses of an interface, one per line (no netmask).
_if_ips() {
	ifconfig "$1" 2>/dev/null |
		awk '/inet / && $2 != "127.0.0.1" { print $2 }'
}

# Last "option routers" from a dhclient lease block for interface $2 in file $1.
# Lease blocks look like:
#   lease { interface "em1"; option routers 10.0.1.1; ... }
_lease_gw_dhclient() {
	file=$1 ifc=$2
	[ -f "$file" ] || return 0
	awk -v ifc="$ifc" '
		BEGIN { RS = "lease"; FS = "\n"; gw = "" }
		{
			thisif = ""
			thisgw = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^[[:space:]]*interface[[:space:]]+"/) {
					s = $i
					sub(/^[[:space:]]*interface[[:space:]]+"/, "", s)
					sub(/".*/, "", s)
					thisif = s
				}
				if ($i ~ /option[[:space:]]+routers/) {
					s = $i
					sub(/.*option[[:space:]]+routers[[:space:]]+/, "", s)
					sub(/[[:space:];].*/, "", s)
					thisgw = s
				}
			}
			if (thisif == ifc && thisgw != "") gw = thisgw
		}
		END { if (gw != "") print gw }
	' "$file"
}

# dhcpcd lease: key=value lines, last router= wins for this interface.
_lease_gw_dhcpcd() {
	ifc=$1
	for f in "/var/db/dhcpcd-${ifc}.lease" "/var/db/dhcpcd/${ifc}.lease" \
		"/var/db/dhcpcd-${ifc}.lease6"; do
		[ -f "$f" ] || continue
		gw=$(grep -E '^router=' "$f" 2>/dev/null | tail -n 1 | cut -d= -f2)
		# some dhcpcd builds use "routers="
		[ -z "$gw" ] && gw=$(grep -E '^routers=' "$f" 2>/dev/null | tail -n 1 | cut -d= -f2)
		if [ -n "$gw" ]; then
			printf '%s\n' "$gw"
			return 0
		fi
	done
}

# Resolve gateway for interface $1. Order: env > conf file > dhclient > dhcpcd.
_gateway_for_if() {
	ifc=$1

	if [ -n "$GATEWAYS_ENV" ]; then
		gw=$(printf '%s\n' "$GATEWAYS_ENV" | tr ',' '\n' |
			awk -F: -v i="$ifc" '$1 == i { print $2; exit }')
		[ -n "$gw" ] && { printf '%s\n' "$gw"; return 0; }
	fi

	if [ -f "$CONF_FILE" ]; then
		gw=$(awk -v i="$ifc" '$1 == i && $2 != "" { print $2; exit }' "$CONF_FILE")
		[ -n "$gw" ] && { printf '%s\n' "$gw"; return 0; }
	fi

	gw=$(_lease_gw_dhclient "/var/db/dhclient.leases.${ifc}" "$ifc")
	[ -z "$gw" ] && gw=$(_lease_gw_dhclient "/var/db/dhclient.leases" "$ifc")
	[ -n "$gw" ] && { printf '%s\n' "$gw"; return 0; }

	gw=$(_lease_gw_dhcpcd "$ifc")
	[ -n "$gw" ] && { printf '%s\n' "$gw"; return 0; }
	return 0
}

# Interfaces that have a default-like role: primary + every other if that
# has a resolvable gateway and at least one IPv4 address. Prints
# "<interface> <gateway>" lines; primary first.
_secondary_if_gw() {
	primary=$1
	for ifn in $(ifconfig -l 2>/dev/null); do
		case "$ifn" in
		lo* | pflog* | pfsync* | enc* | gre* | tun* | tap* | wg*) continue ;;
		esac
		[ "$ifn" = "$primary" ] && continue
		# only interfaces with an IPv4 address
		_if_ips "$ifn" | grep -q . || continue
		gw=$(_gateway_for_if "$ifn")
		[ -n "$gw" ] && printf '%s %s\n' "$ifn" "$gw"
	done
}

# ---------------------------------------------------------------------------
# PF: enable, ensure anchor reference, load/flush rules
# ---------------------------------------------------------------------------

_pf_enable() {
	pfctl -e 2>/dev/null || true
}

_pf_conf_has_anchor() {
	[ -f "$PF_CONF" ] && grep -qE "anchor[[:space:]]+\"?${ANCHOR}\"?" "$PF_CONF"
}

# Insert `anchor "pbr-split"` into pf.conf before the first filter rule
# (pass/block/match/anchor) so our quick rules are evaluated early.
# Backup once to pf.conf.pbr-split.bak.
_ensure_anchor_in_pfconf() {
	_pf_conf_has_anchor && return 0

	if [ ! -f "$PF_CONF" ]; then
		printf 'anchor "%s"\n' "$ANCHOR" >"$PF_CONF" ||
			_die "cannot create $PF_CONF"
		pfctl -f "$PF_CONF" || _die "pfctl -f $PF_CONF failed"
		_log "created $PF_CONF with anchor \"$ANCHOR\""
		return 0
	fi

	[ -f "$PF_CONF.pbr-split.bak" ] ||
		cp "$PF_CONF" "$PF_CONF.pbr-split.bak" 2>/dev/null || true

	tmp=$(mktemp) || _die "mktemp failed"
	awk -v a="$ANCHOR" '
		!done && /^[[:space:]]*(pass|block|match|anchor|load|table)/ {
			printf "anchor \"%s\"   # added by pbr-split\n", a
			done = 1
		}
		{ print }
		END {
			if (!done) printf "anchor \"%s\"   # added by pbr-split\n", a
		}
	' "$PF_CONF" >"$tmp" || { rm -f "$tmp"; _die "cannot rewrite $PF_CONF"; }
	cat "$tmp" >"$PF_CONF" || { rm -f "$tmp"; _die "cannot update $PF_CONF"; }
	rm -f "$tmp"
	pfctl -f "$PF_CONF" 2>/dev/null || true
	_log "inserted anchor \"$ANCHOR\" into $PF_CONF (backup: $PF_CONF.pbr-split.bak)"
}

# Emit anchor rules for "<if> <gw>" lines on stdin.
_ruleset() {
	while read -r ifn gw; do
		[ -z "${ifn:-}" ] && continue
		[ -z "${gw:-}" ] && continue
		_if_ips "$ifn" | while read -r ip; do
			[ -z "${ip:-}" ] && continue
			# outbound: force egress via this port's gateway
			printf 'pass out quick from %s/32 to any route-to (%s %s)\n' \
				"$ip" "$ifn" "$gw"
			# inbound on the port: replies must go back the same way
			printf 'pass in quick on %s reply-to (%s %s) from any to %s/32\n' \
				"$ifn" "$ifn" "$gw" "$ip"
		done
	done
}

_ruleset_body() {
	primary_if=$1
	{
		printf '# generated by pbr-split (%s) - do not edit\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo now)"
		_secondary_if_gw "$primary_if" | _ruleset
	} 2>/dev/null
}

_pf_load_anchor() {
	# stdin = ruleset
	pfctl -a "$ANCHOR" -f - || _die "pfctl -a $ANCHOR -f - failed"
}

_pf_flush_anchor() {
	pfctl -a "$ANCHOR" -F all 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# fingerprint / apply / restore / status / watch
# ---------------------------------------------------------------------------

# Stable snapshot of what apply manages: default route + all ifconfig inet
# lines (IPv4 only). DHCP lifetimes are not included, so renewals do not
# force a re-apply unless the address or gateway actually changes.
_state_fingerprint() {
	{
		route -n get default 2>/dev/null |
			awk '/interface:|gateway:/ { print }'
		ifconfig 2>/dev/null |
			awk '
				/^[a-zA-Z0-9]/ && /:/ {
					ifn = $1
					sub(/:.*/, "", ifn)
				}
				/inet / && $2 != "127.0.0.1" { print ifn, $2 }
			'
	} | sort
}

_wait_for_default() {
	deadline=$(($(date +%s) + WAIT_SECONDS))
	while :; do
		_default_if_gw | grep -q . && return 0
		[ "$(date +%s)" -ge "$deadline" ] && return 0
		sleep 2
	done
}

# Build and load the anchor. Always restores (flush) first so double runs
# never accumulate rules — same idempotency contract as the Linux script.
_apply() {
	_require_root
	_pf_enable
	_ensure_anchor_in_pfconf

	_wait_for_default

	dfg=$(_default_if_gw)
	if [ -z "$dfg" ]; then
		_log "no default route, flushing anchor and doing nothing"
		_pf_flush_anchor
		return 0
	fi

	# intentional word split: "if gw" on one line -> two args
	# shellcheck disable=SC2086
	set -- $dfg
	prim_if=$1
	prim_gw=$2
	if [ -n "$PRIMARY_IF" ]; then
		prim_if=$PRIMARY_IF
	fi

	# flush first so reload replaces the whole anchor atomically
	_pf_flush_anchor

	rules=$(_ruleset_body "$prim_if")
	if [ -z "$rules" ] || [ "$(printf '%s\n' "$rules" | grep -c '^pass ')" -eq 0 ]; then
		_log "primary default via $prim_if ($prim_gw); no secondary gateways found (lease/env/conf) - nothing to split"
		return 0
	fi

	printf '%s\n' "$rules" | _pf_load_anchor

	n=$(printf '%s\n' "$rules" | grep -c '^pass out ')
	nif=$(printf '%s\n' "$rules" |
		awk '/^pass out / { for (i = 1; i <= NF; i++) if ($i == "route-to") { gsub(/[()]/, "", $(i+1)); print $(i+1) } }' |
		sort -u | tr '\n' ' ')
	_log "applied: primary=$prim_if ($prim_gw); split: $nif ($n out rules) in PF anchor \"$ANCHOR\""
	return 0
}

_restore_cmd() {
	_require_root
	_pf_flush_anchor
	_log "restored: flushed PF anchor \"$ANCHOR\" (pf.conf anchor line left in place)"
}

_status() {
	_require_root
	echo "== default route =="
	route -n get default 2>/dev/null || echo "(none)"
	echo
	echo "== interfaces with gateway + addresses =="
	dfg=$(_default_if_gw)
	# intentional word split: "if gw" on one line -> two args
	# shellcheck disable=SC2086
	set -- $dfg
	prim_if=${1:-}
	_secondary_if_gw "$prim_if" | while read -r ifn gw; do
		[ -z "${ifn:-}" ] && continue
		printf '%s gateway %s addrs: %s\n' "$ifn" "$gw" "$(_if_ips "$ifn" | tr '\n' ' ')"
	done
	echo
	echo "== PF anchor $ANCHOR =="
	pfctl -a "$ANCHOR" -s rules 2>/dev/null || echo "(empty / not loaded)"
}

# Long-running mode: fingerprint poll (portable across all four BSDs;
# route -n monitor exists but does not cover address changes / lease
# renewals, so a pure poll is simpler and complete). No self-loop: our
# own pfctl reloads do not change the fingerprint.
_WATCH_FP=""

_watch() {
	_require_root
	_log "watch: initial apply (poll every ${POLL_SECONDS}s, fingerprint-gated)"
	_apply || _log "watch: initial apply failed; will retry on next tick"
	WAIT_SECONDS=0
	_WATCH_FP=$(_state_fingerprint)
	while :; do
		sleep "$POLL_SECONDS"
		now=$(_state_fingerprint)
		[ "$now" = "$_WATCH_FP" ] && continue
		_log "watch: network state changed, re-applying"
		if _apply; then
			_WATCH_FP=$(_state_fingerprint)
		else
			_log "watch: apply failed; will retry on next tick"
		fi
	done
}

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") [command]

Commands:
  apply      (re)apply the split (default; idempotent, needs root)
  watch      apply, then re-apply on state changes (needs root)
  restore    flush our PF anchor rules (needs root)
  status     show default route, gateways and PF anchor rules

Environment:
  PBR_WAIT_SECONDS   seconds to wait for a default route (default 0)
  PBR_POLL_SECONDS   watch poll interval (default 15)
  PBR_GATEWAYS       manual gateways "em1:10.0.1.1,em2:10.0.2.1"
  PBR_PRIMARY        primary interface override
  PBR_PF_CONF        pf.conf path (default /etc/pf.conf)
  PBR_ANCHOR         PF anchor name (default pbr-split)
EOF
	exit 2
}

main() {
	cmd=${1:-apply}
	case "$cmd" in
	apply)
		_apply
		;;
	watch)
		_watch
		;;
	restore)
		_restore_cmd
		;;
	status)
		_status
		;;
	*)
		usage
		;;
	esac
}

main "${1:-apply}"
