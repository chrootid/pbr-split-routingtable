#!/bin/bash
# shellcheck disable=SC2016  # $-expressions inside _check snippets are
#                             # intentionally expanded later by eval
#
# pbr-split-routingtable.sh - policy-routing split of default routes
#
# For OpenStack instances with one IP per Neutron port: every port's subnet
# installs its own default route into the single main routing table, so
# traffic of the non-primary IPs leaves via the wrong gateway. This script
# moves each non-primary default route (and all other routes of that NIC)
# into a dedicated routing table and adds policy rules so that traffic
# sourced from / arriving on / bound to that NIC uses its own table.
# The primary default route (lowest metric) always stays in main, so
# unbound applications keep working.
#
# Usage:
#   pbr-split-routingtable.sh [apply]   (re)apply the split (default; idempotent)
#   pbr-split-routingtable.sh watch     apply, then auto re-apply on changes
#                                       (hot-plug/remove of ports, DHCP renew)
#   pbr-split-routingtable.sh restore   move routes back to main, flush our rules
#   pbr-split-routingtable.sh status    show rules, tables and defaults
#   pbr-split-routingtable.sh selftest  offline test in an isolated netns
#
# Environment:
#   PBR_WAIT_SECONDS  how long the first `apply` waits for >=2 default routes
#                     (default 0 = no wait; the systemd unit sets 30; later
#                     re-applies from `watch` never wait)
#   PBR_RT_TABLES     override path of the iproute2 tables file
#                     (default /etc/iproute2/rt_tables; used by selftest)
#
# Supported platforms:
#   - Ubuntu, AlmaLinux/RHEL, Arch, openSUSE: works out of the box
#     (bash, iproute2 and systemd are all present by default)
#   - Alpine Linux: needs two packages and the bundled OpenRC service
#     instead of systemd (busybox `sh`/`ip` are not sufficient):
#       apk add bash iproute2
#       install -m 0755 pbr-split-routingtable.sh /usr/local/sbin/
#       install -m 0755 pbr-split.openrc /etc/init.d/pbr-split
#       rc-update add pbr-split default
#       rc-service pbr-split start      # logs: /var/log/pbr-split.log
#   - FreeBSD, OpenBSD, NetBSD, DragonFlyBSD: use pbr-split-bsd.sh
#     (PF-based; different networking stack - see that script / README)
#
# Install (systemd distros):
#   install -m 0755 pbr-split-routingtable.sh /usr/local/sbin/
#   install -m 0644 pbr-split.service /etc/systemd/system/
#   systemctl daemon-reload && systemctl enable --now pbr-split.service
#
# cloud-init: bake the platform files above into the image (or deliver them
# with write_files) and activate on first boot with:
#   #cloud-config            (systemd distros)
#   runcmd:
#     - [systemctl, daemon-reload]
#     - [systemctl, enable, --now, pbr-split.service]
#
#   #cloud-config            (Alpine / OpenRC)
#   runcmd:
#     - [apk, add, bash, iproute2]
#     - [rc-update, add, pbr-split, default]
#     - [rc-service, pbr-split, start]
#
# The service runs `watch`: it applies the split as soon as defaults exist
# and re-applies automatically whenever ports/routes change, so hot-plugged
# Neutron ports become fully reachable without manual steps. Works on both
# NetworkManager and systemd-networkd images (pure iproute2 netlink events).
#
# Notes:
#   - all our rules are tagged `protocol 199` so re-runs can flush exactly
#     our rules and nothing else
#   - IPv6 is not handled
#   - no distro-specific networking tooling is touched (plain iproute2)

set -u -o pipefail

RULE_PROTOCOL=199
TABLE_PREFIX="port_"
RT_TABLES="${PBR_RT_TABLES:-/etc/iproute2/rt_tables}"
WAIT_SECONDS="${PBR_WAIT_SECONDS:-0}"

_log() {
	echo "pbr-split: $*"
}

_die() {
	_log "ERROR: $*" >&2
	exit 1
}

_require_root() {
	(( EUID == 0 )) || _die "requires root or sudo"
	_require_iproute2
}

# Real iproute2 is required: we rely on `ip rule protocol` (idempotency),
# `ip monitor` (watch) and rt_tables. Busybox `ip` (Alpine default) has
# none of these.
_require_iproute2() {
	local out
	out=$(ip rule help 2>&1) || true
	grep -q 'protocol' <<<"$out" ||
		_die "unsupported 'ip' command: install iproute2 (Alpine: apk add bash iproute2)"
}

_ensure_rt_tables() {
	mkdir -p "$(dirname "$RT_TABLES")" || return 1
	[[ -f "$RT_TABLES" ]] || touch "$RT_TABLES" || return 1
}

# Default routes of the main table, in kernel order (lowest metric first),
# one device per line (handles multipath lines with several nexthops).
_default_devs() {
	ip -4 route show default | awk '{
		for (i = 1; i < NF; i++)
			if ($i == "dev") { print $(i + 1); next }
	}'
}

_primary_default_dev() {
	_default_devs | sed -n '1p'
}

# IPv4 addresses of a device, one per line (exact device match, no grep
# substring false positives like eth1 matching eth10/veth1).
_dev_ips() {
	ip -4 -o addr show dev "$1" 2>/dev/null |
		awk '{ split($4, a, "/"); print a[1] }' | sort -u
}

_next_table_id() {
	local used id=100
	used=$(awk '$1 ~ /^[0-9]+$/ { print $1 }' "$RT_TABLES" 2>/dev/null | sort -un | tr '\n' ' ')
	while [[ " $used " == *" $id "* ]]; do
		id=$((id + 1))
	done
	echo "$id"
}

# Route line from `ip route show ...` may lack `dev <name>` (iproute2 omits
# it when output is filtered by device); the device is mandatory for add/del.
_route_with_dev() {
	local route=$1 dev=$2
	route="${route%"${route##*[![:space:]]}"}" # trim trailing whitespace
	if [[ $route =~ [[:space:]]dev[[:space:]] ]]; then
		echo "$route"
	else
		echo "$route dev $dev"
	fi
}

# Move every route of a non-primary device into its own table, then add
# policy rules. Routes are installed in the new table *before* the rules
# are added and only then removed from main, so traffic is never blackholed.
_split_dev() {
	local dev=$1
	local tid name
	tid=$(_next_table_id) || return 1
	name="${TABLE_PREFIX}${dev}"
	grep -qE "^[0-9]+[[:space:]]+$name\$" "$RT_TABLES" 2>/dev/null ||
		echo "$tid $name" >> "$RT_TABLES" ||
		_die "cannot write $RT_TABLES"

	local -a routes
	mapfile -t routes < <(ip -4 route show dev "$dev")

	local moved=0 failed=0 route full
	local -a rargs
	for route in "${routes[@]}"; do
		[[ -z $route ]] && continue
		full=$(_route_with_dev "$route" "$dev")
		read -r -a rargs <<< "$full"
		if ip route add "${rargs[@]}" table "$tid"; then
			moved=$((moved + 1))
		else
			failed=$((failed + 1))
			_log "WARNING: could not add '$full' to table $tid"
			continue
		fi
	done

	local -a ips
	mapfile -t ips < <(_dev_ips "$dev")
	if ((${#ips[@]} == 0)); then
		_log "WARNING: $dev has no IPv4 address, adding only iif/oif rules"
	fi

	local rc=0 ip
	for ip in "${ips[@]}"; do
		ip rule add protocol "$RULE_PROTOCOL" from "$ip/32" table "$tid" ||
			{ _log "WARNING: rule from $ip failed"; rc=1; }
	done
	ip rule add protocol "$RULE_PROTOCOL" iif "$dev" table "$tid" ||
		{ _log "WARNING: rule iif $dev failed"; rc=1; }
	ip rule add protocol "$RULE_PROTOCOL" oif "$dev" table "$tid" ||
		{ _log "WARNING: rule oif $dev failed"; rc=1; }

	# now that the new table is live, drop the routes from main
	for route in "${routes[@]}"; do
		[[ -z $route ]] && continue
		full=$(_route_with_dev "$route" "$dev")
		read -r -a rargs <<< "$full"
		ip route del "${rargs[@]}" table main 2>/dev/null ||
			_log "WARNING: could not remove '$full' from main"
	done

	_log "split $dev -> table $tid ($name): ${#routes[@]} routes (${failed} failed), ${#ips[@]} source IP(s)"
	return $rc
}

# Reverse everything this script did: put all port_* table routes back into
# main, flush only our protocol-tagged rules, drop our rt_tables entries.
# This is what makes `apply` safe to run repeatedly.
_restore_all() {
	local -a port_ids=()
	local tid name route

	if [[ -f $RT_TABLES ]]; then
		while read -r tid name; do
			[[ -z ${tid:-} || -z ${name:-} ]] && continue
			[[ $tid =~ ^[0-9]+$ ]] || continue
			[[ $name == "${TABLE_PREFIX}"* ]] || continue
			port_ids+=("$tid")
			local -a routes
			mapfile -t routes < <(ip -4 route show table "$tid" 2>/dev/null)
			for route in "${routes[@]}"; do
				[[ -z $route ]] && continue
				local -a rargs
				read -r -a rargs <<< "$route"
				ip route add "${rargs[@]}" table main 2>/dev/null || true
			done
		done < "$RT_TABLES"
	fi

	ip rule flush protocol "$RULE_PROTOCOL" 2>/dev/null || true

	# flush our tables only after no rule references them anymore, so no
	# lookup ever sees an empty table
	local id
	for id in "${port_ids[@]}"; do
		ip -4 route flush table "$id" 2>/dev/null || true
	done

	if [[ -f $RT_TABLES ]]; then
		sed -i -E "/^[[:space:]]*[0-9]+[[:space:]]+${TABLE_PREFIX}[A-Za-z0-9_.:-]+[[:space:]]*$/d" \
			"$RT_TABLES"
	fi
}

_wait_for_defaults() {
	local deadline=$((SECONDS + WAIT_SECONDS)) count
	while (( SECONDS < deadline )); do
		count=$(_default_devs | wc -l)
		(( count >= 2 )) && return 0
		sleep 2
	done
	return 0
}

_apply() {
	# clean slate first: restores previously split routes and flushes our
	# old rules, so double runs never accumulate rules or misassign tables
	_restore_all
	_ensure_rt_tables || _die "cannot prepare $RT_TABLES"

	_wait_for_defaults

	local primary
	primary=$(_primary_default_dev)
	if [[ -z $primary ]]; then
		_log "no default route in main, nothing to do"
		return 0
	fi

	local -a devs
	mapfile -t devs < <(_default_devs | awk -v p="$primary" '$0 != p' | sort -u)

	if ((${#devs[@]} == 0)); then
		_log "single default route via $primary; nothing to split"
		return 0
	fi

	_log "primary default via $primary stays in main; splitting: ${devs[*]}"
	local dev rc=0
	for dev in "${devs[@]}"; do
		_split_dev "$dev" || rc=1
	done
	return $rc
}

_restore_cmd() {
	_restore_all
	_log "restored: routes are back in main, our rules and table entries removed"
}

# Stable snapshot of what `apply` manages: IPv4 addresses (without DHCP
# lifetimes, which tick down and would change on every renew) and the main
# table's default routes (without expiry counters).
_state_fingerprint() {
	{
		ip -4 -o addr show 2>/dev/null |
			sed -E 's/ valid_lft [^ ]+ preferred_lft [^ ]+//'
		ip -4 route show default 2>/dev/null |
			sed -E 's/ expires [0-9]+sec//'
	} | sort
}

_WATCH_FP=""

# Re-apply when the fingerprint differs from the last successfully applied
# state. On apply failure the old fingerprint is kept, so the next event or
# 30s tick retries automatically.
_state_check() {
	local now
	now=$(_state_fingerprint)
	[[ $now == "$_WATCH_FP" ]] && return 0
	_log "watch: network state changed, re-applying"
	if _apply; then
		_WATCH_FP=$(_state_fingerprint)
	else
		_log "watch: apply failed; will retry on next event or tick"
	fi
}

# Long-running mode: apply once, then react to netlink addr/route events
# (debounced) with a state-fingerprint check. Self-generated events from our
# own apply never re-trigger it (fingerprint unchanged), so it cannot loop.
# Falls back gracefully: multi-type monitor -> plain `ip monitor` -> 30s poll.
_watch() {
	local -a monitor=(ip -4 monitor addr route)
	local rc stream_events drain

	# open the monitor before the first apply so no event is missed
	exec 3< <("${monitor[@]}" 2>/dev/null)

	_log "watch: initial apply"
	_apply || _log "watch: initial apply failed; will retry on events"
	WAIT_SECONDS=0 # later re-applies must never block
	_WATCH_FP=$(_state_fingerprint)

	while :; do
		stream_events=0
		while :; do
			read -r -t 30 <&3 # only the exit status matters (event or tick)
			rc=$?
			if ((rc == 0)); then
				stream_events=1
				# coalesce bursts (hot-plug + DHCP arrive together);
				# capped so constant traffic cannot starve checks
				drain=0
				while ((drain < 10)) && read -r -t 2 <&3; do
					drain=$((drain + 2))
				done
			fi
			_state_check
			((rc == 1)) && break # monitor stream ended
		done
		exec 3<&- || true

		# degrade only if the stream died without ever delivering events
		# (e.g. old iproute2 without multi-type monitor support)
		if ((stream_events == 0)); then
			case "${monitor[*]}" in
			"ip -4 monitor addr route")
				monitor=(ip monitor)
				_log "watch: multi-type monitor unavailable, using 'ip monitor'"
				;;
			"ip monitor")
				monitor=(sleep 30)
				_log "watch: event monitoring unavailable, polling every 30s"
				;;
			esac
		fi
		exec 3< <("${monitor[@]}" 2>/dev/null)
	done
}

_status() {
	_require_iproute2
	echo "== default routes in main =="
	ip -4 route show default || true
	echo
	echo "== policy rules (protocol $RULE_PROTOCOL) =="
	ip rule show | grep "proto $RULE_PROTOCOL" || echo "(none)"
	echo
	echo "== $TABLE_PREFIX entries in $RT_TABLES =="
	grep "${TABLE_PREFIX}" "$RT_TABLES" 2>/dev/null || echo "(none)"
	echo
	echo "== split tables =="
	awk -v p="$TABLE_PREFIX" '$1 ~ /^[0-9]+$/ && $2 ~ "^" p { print $1, $2 }' \
		"$RT_TABLES" 2>/dev/null | while read -r id name; do
		echo "-- table $id ($name) --"
		ip -4 route show table "$id" 2>/dev/null || true
	done
}

# ---------------------------------------------------------------------------
# selftest: simulates a 3-port OpenStack instance inside a netns, then
# hot-plugs a 4th port, and asserts the per-port split, source-based
# selection, unbound fallback, idempotency, hot-plug re-apply and restore
# (works for N ports: one primary in main, one table per the others)
# ---------------------------------------------------------------------------

_SELFTEST_NS=""

_cleanup_selftest_ns() {
	if [[ -n ${_SELFTEST_NS:-} ]]; then
		ip netns del "$_SELFTEST_NS" 2>/dev/null || true
		_SELFTEST_NS=""
	fi
}

TESTS_FAILED=0

_check() {
	local desc=$1 snippet=$2 out
	if out=$(eval "$snippet" 2>&1); then
		echo "PASS: $desc"
		[[ -n $out ]] && printf '      %s\n' "$out"
	else
		echo "FAIL: $desc"
		[[ -n $out ]] && printf '      %s\n' "$out"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

_selftest_inner() {
	RT_TABLES="$(mktemp)"
	WAIT_SECONDS=0

	ip link set lo up
	ip link add pbr0 type dummy
	ip link set pbr0 up
	ip addr add 10.0.0.5/24 dev pbr0
	ip link add pbr1 type dummy
	ip link set pbr1 up
	ip addr add 10.1.0.5/24 dev pbr1
	ip addr add 10.2.0.5/24 dev pbr1 # second IP on the secondary NIC
	ip link add pbr2 type dummy
	ip link set pbr2 up
	ip addr add 10.3.0.5/24 dev pbr2 # third port
	ip route add default via 10.0.0.1 dev pbr0 metric 100
	ip route add default via 10.1.0.1 dev pbr1 metric 200
	ip route add default via 10.3.0.1 dev pbr2 metric 300

	echo "--- apply (first run) ---"
	_check "apply succeeds" '_apply'

	echo "--- main table keeps exactly the primary default ---"
	_check "main has one default route" \
		'[[ $(ip -4 route show default | wc -l) -eq 1 ]]'
	_check "primary default stays in main" \
		'ip -4 route show default | grep -q "via 10.0.0.1"'
	_check "both secondary defaults removed from main" \
		'! ip -4 route show default | grep -qE "via 10\.(1|3)\.0\.1"'
	_check "secondary connected routes moved out of main" \
		'! ip -4 route show | grep -qE "10\.(1|2|3)\.0\.0/24"'

	echo "--- each secondary port lives in its own table ---"
	_check "rt_tables has port_pbr1 entry" \
		'grep -qE "^[0-9]+[[:space:]]+port_pbr1\$" "$RT_TABLES"'
	_check "rt_tables has port_pbr2 entry" \
		'grep -qE "^[0-9]+[[:space:]]+port_pbr2\$" "$RT_TABLES"'
	_check "two entries with two distinct table ids" \
		'[[ $(grep port_ "$RT_TABLES" | awk "{print \$1}" | sort -u | wc -l) -eq 2 ]]'
	_check "port_pbr1 table contains its default" \
		'id=$(awk "/ port_pbr1\$/ {print \$1}" "$RT_TABLES"); ip -4 route show table "$id" | grep -q "via 10.1.0.1"'
	_check "port_pbr2 table contains its default" \
		'id=$(awk "/ port_pbr2\$/ {print \$1}" "$RT_TABLES"); ip -4 route show table "$id" | grep -q "via 10.3.0.1"'

	echo "--- traffic selection ---"
	_check "pbr1 source-bound traffic uses its gateway" \
		'ip route get 1.1.1.1 from 10.1.0.5 | grep -q "via 10.1.0.1"'
	_check "second IP of pbr1 also bound correctly" \
		'ip route get 1.1.1.1 from 10.2.0.5 | grep -q "via 10.1.0.1"'
	_check "pbr2 source-bound traffic uses its gateway" \
		'ip route get 1.1.1.1 from 10.3.0.5 | grep -q "via 10.3.0.1"'
	_check "unbound traffic falls back to primary gateway" \
		'ip route get 1.1.1.1 | grep -q "via 10.0.0.1"'
	_check "exactly 7 rules (pbr1: 2 from + iif + oif, pbr2: 1 from + iif + oif)" \
		'[[ $(ip rule show | grep -c "proto 199") -eq 7 ]]'

	echo "--- apply (second run must be idempotent) ---"
	_check "second apply succeeds with no warnings" \
		'o=$(_apply 2>&1); r=$?; printf "%s\n" "$o"; [[ $r -eq 0 && $o != *WARNING* ]]'
	_check "still exactly 7 rules after re-run" \
		'[[ $(ip rule show | grep -c "proto 199") -eq 7 ]]'
	_check "still exactly 2 rt_tables entries after re-run" \
		'[[ $(grep -c port_ "$RT_TABLES") -eq 2 ]]'
	_check "still one default in main after re-run" \
		'[[ $(ip -4 route show default | wc -l) -eq 1 ]]'
	_check "bound traffic still correct after re-run" \
		'ip route get 1.1.1.1 from 10.1.0.5 | grep -q "via 10.1.0.1" && ip route get 1.1.1.1 from 10.3.0.5 | grep -q "via 10.3.0.1"'

	echo "--- hot-plug a 4th port while the split is active ---"
	ip link add pbr3 type dummy
	ip link set pbr3 up
	ip addr add 10.4.0.5/24 dev pbr3
	ip route add default via 10.4.0.1 dev pbr3 metric 400

	_check "existing split untouched by hot-plug" \
		'ip route get 1.1.1.1 from 10.1.0.5 | grep -q "via 10.1.0.1" && ip route get 1.1.1.1 from 10.3.0.5 | grep -q "via 10.3.0.1" && ip route get 1.1.1.1 | grep -q "via 10.0.0.1"'
	_check "new port same-subnet traffic works (connected route in main)" \
		'ip route get 10.4.0.1 | grep -q "dev pbr3"'
	_check "documented pre-reapply state: new default landed in main" \
		'[[ $(ip -4 route show default | wc -l) -eq 2 ]]'
	_check "documented pre-reapply limitation: new IP not split yet" \
		'ip route get 1.1.1.1 from 10.4.0.5 | grep -q "via 10.0.0.1"'

	_check "re-apply picks up the hot-plugged port with no warnings" \
		'o=$(_apply 2>&1); r=$?; printf "%s\n" "$o"; [[ $r -eq 0 && $o != *WARNING* ]]'
	_check "one default left in main after hot-plug re-apply" \
		'[[ $(ip -4 route show default | wc -l) -eq 1 ]]'
	_check "new port now uses its own gateway" \
		'ip route get 1.1.1.1 from 10.4.0.5 | grep -q "via 10.4.0.1"'
	_check "existing ports unaffected by hot-plug re-apply" \
		'ip route get 1.1.1.1 from 10.1.0.5 | grep -q "via 10.1.0.1" && ip route get 1.1.1.1 from 10.3.0.5 | grep -q "via 10.3.0.1" && ip route get 1.1.1.1 | grep -q "via 10.0.0.1"'
	_check "exactly 10 rules after hot-plug re-apply (4+3+3)" \
		'[[ $(ip rule show | grep -c "proto 199") -eq 10 ]]'
	_check "3 rt_tables entries with 3 distinct table ids" \
		'[[ $(grep port_ "$RT_TABLES" | awk "{print \$1}" | sort -u | wc -l) -eq 3 ]]'

	echo "--- restore ---"
	_check "restore succeeds" '_restore_cmd'
	_check "all four defaults back in main" \
		'[[ $(ip -4 route show default | wc -l) -eq 4 ]]'
	_check "no protocol-199 rules left" \
		'! ip rule show | grep -q "proto 199"'
	_check "rt_tables cleaned" \
		'! grep -q port_ "$RT_TABLES"'
	_check "connected routes restored to main" \
		'ip -4 route show | grep -q "10.4.0.0/24"'

	rm -f "$RT_TABLES"
	echo
	if (( TESTS_FAILED == 0 )); then
		echo "selftest: all tests passed"
	else
		echo "selftest: $TESTS_FAILED test(s) FAILED"
	fi
	return "$TESTS_FAILED"
}

_selftest() {
	_SELFTEST_NS="pbr-selftest-$$"
	ip netns add "$_SELFTEST_NS" ||
		_die "selftest: cannot create network namespace (root required)"
	trap _cleanup_selftest_ns EXIT

	local rc=0
	ip netns exec "$_SELFTEST_NS" bash "$(readlink -f "$0")" __selftest_inner || rc=$?

	_cleanup_selftest_ns
	trap - EXIT
	return $rc
}

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") [command]

Commands:
  apply      (re)apply the split (default; idempotent, needs root)
  watch      apply, then auto re-apply on port/route changes (needs root)
  restore    move split routes back to main, flush our rules (needs root)
  status     show default routes, our rules and split tables
  selftest   run an isolated functional test in a network namespace (root)

Environment:
  PBR_WAIT_SECONDS  seconds to wait for >=2 default routes (default 0)
  PBR_RT_TABLES     override rt_tables path (default /etc/iproute2/rt_tables)
EOF
	exit 2
}

main() {
	local cmd="${1:-apply}"
	case "$cmd" in
	apply)
		_require_root
		_apply
		;;
	watch)
		_require_root
		_watch
		;;
	restore)
		_require_root
		_restore_cmd
		;;
	status)
		_status
		;;
	selftest)
		_require_root
		_selftest
		;;
	__selftest_inner)
		_selftest_inner
		;;
	*)
		usage
		;;
	esac
}

main "${1:-apply}"
