# pbr-split-routingtable

Policy-based routing for Linux hosts with **multiple default routes** —
typically OpenStack instances attached to **two or more Neutron ports**
(each port on a different subnet, each subnet advertising its own default
route).

## The problem

When an OpenStack instance has several ports, every port's subnet installs
a default route into the **single** main routing table. The kernel then
picks one of them for all traffic, so replies to connections that arrived
on another port leave through the **wrong gateway** — Neutron's
anti-spoofing (port security) drops them, and the extra IPs look "half
reachable".

## How it works

```
before:                              after:
main: default via A (eth0)           main:  default via A (eth0)      <- primary (lowest metric)
       default via B (eth1)                 port_eth1 table: default via B
       default via C (eth2)                 port_eth2 table: default via C
                                            rules (proto 199):
                                              from <ip-B>/32 lookup port_eth1
                                              iif eth1 table port_eth1
                                              oif eth1 table port_eth1
                                              ... (same for eth2)
```

- the **primary** default (lowest metric) stays in `main`, so applications
  that don't bind a source IP keep working
- every other default-route NIC gets its own routing table
  (`/etc/iproute2/rt_tables`: `<id> port_<nic>`, ids from 100) containing
  all of that NIC's routes
- policy rules send traffic **sourced from / arriving on / bound to** that
  NIC to its own table, so each IP exits via its own subnet gateway
- all rules are tagged `protocol 199`, so a re-run flushes exactly these
  rules and nothing else (idempotent: restore → re-split)

A long-running **`watch`** mode applies the split at boot and **re-applies
automatically** whenever ports or routes change (hot-plug, port removal,
DHCP renew) by listening to netlink events (`ip monitor`), with graceful
fallback to plain `ip monitor` and finally 30-second polling.

## Supported platforms

| Platform | Status | Notes |
|---|---|---|
| Ubuntu | works as-is | bash, iproute2, systemd present by default |
| AlmaLinux / RHEL | works as-is | same |
| Arch Linux | works as-is | same |
| openSUSE | works as-is | same |
| Alpine Linux | works after setup | `apk add bash iproute2` + OpenRC service (busybox `sh`/`ip` are insufficient) |
| FreeBSD | works as-is (untested) | `pbr-split-bsd.sh` + PF anchor `route-to`/`reply-to`; stock kernel, no custom FIBs |
| DragonFlyBSD | works as-is (untested) | same BSD script + FreeBSD-style rc.d |
| OpenBSD | works as-is (untested) | same BSD script + OpenBSD rc.d (PF is base) |
| NetBSD | works as-is (untested) | same BSD script + NetBSD rc.d (PF in base; dhcpcd leases parsed) |
| MikroTik CHR (RouterOS v7) | works as-is (untested) | native `pbr-split.rsc`; scheduler re-applies every 15 s; verify on a live CHR before production |

IPv4 only. The Linux script touches nothing distro-specific beyond `iproute2`; the BSD script uses only base tools (`route`, `ifconfig`, `pfctl`, `netstat`).

## Files

| File | Purpose |
|---|---|
| `pbr-split-routingtable.sh` | the Linux script (`apply` / `watch` / `restore` / `status` / `selftest`) |
| `pbr-split.service` | systemd unit (runs `watch`) |
| `pbr-split.openrc` | OpenRC unit for Alpine (runs `watch`) |
| `pbr-split-bsd.sh` | BSD script for FreeBSD / OpenBSD / NetBSD / DragonFly (PF-based) |
| `pbr-split.freebsd` | rc.d unit for FreeBSD and DragonFlyBSD |
| `pbr-split.openbsd` | rc.d unit for OpenBSD |
| `pbr-split.netbsd` | rc.d unit for NetBSD |
| `pbr-split.rsc` | native RouterOS v7 script for MikroTik CHR (see below) |

## Usage

Linux:

```sh
sudo pbr-split-routingtable.sh [apply]   # (re)apply the split — idempotent (default)
sudo pbr-split-routingtable.sh watch     # apply, then auto re-apply on changes
sudo pbr-split-routingtable.sh restore   # undo: routes back to main, rules removed
sudo pbr-split-routingtable.sh status    # show defaults, rules and split tables
sudo pbr-split-routingtable.sh selftest  # offline functional test in a netns
```

BSD (FreeBSD / OpenBSD / NetBSD / DragonFly):

```sh
sudo pbr-split-bsd.sh [apply]   # (re)apply the split — idempotent (default)
sudo pbr-split-bsd.sh watch     # apply, then re-apply on changes (poll)
sudo pbr-split-bsd.sh restore   # flush the pbr-split PF anchor
sudo pbr-split-bsd.sh status    # show default, gateways and PF rules
```

Verify on a live instance:

```sh
# traffic from a secondary IP must exit via that subnet's gateway:
ip route get 8.8.8.8 from <secondary-ip>
#   ... via <subnet-gw> dev eth1 table <id>          <- correct

# unbound traffic uses the primary gateway:
ip route get 8.8.8.8

pbr-split-routingtable.sh status
```

Logs: `journalctl -u pbr-split` (systemd) or `/var/log/pbr-split.log`
(OpenRC). On failure the service restarts automatically
(`Restart=on-failure` / `respawn`).

## Install

### systemd (Ubuntu, Debian, AlmaLinux/RHEL, Arch, openSUSE)

```sh
install -m 0755 pbr-split-routingtable.sh /usr/local/sbin/
install -m 0644 pbr-split.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pbr-split.service
```

### OpenRC (Alpine Linux)

```sh
apk add bash iproute2
install -m 0755 pbr-split-routingtable.sh /usr/local/sbin/
install -m 0755 pbr-split.openrc /etc/init.d/pbr-split
rc-update add pbr-split default
rc-service pbr-split start
```

### BSD (FreeBSD, OpenBSD, NetBSD, DragonFlyBSD)

Uses `pbr-split-bsd.sh` and Packet Filter. PF is in base on all four; no
custom kernel (`ROUTETABLES` / multiple FIBs) is required. The script:

- keeps the single default route in the main table as the primary
- discovers each other interface's gateway (dhclient/dhcpcd leases, or
  `/etc/pbr-split.conf`, or `PBR_GATEWAYS`)
- loads `route-to` / `reply-to` rules into the PF anchor `pbr-split`
- inserts `anchor "pbr-split"` into `pf.conf` once (backup:
  `pf.conf.pbr-split.bak`) and enables PF if needed

Gateway discovery order: `PBR_GATEWAYS` env → `/etc/pbr-split.conf`
(`<iface> <gw>` lines) → dhclient leases → dhcpcd leases. If leases are
not present (static config, or a stack that does not write them), set
them manually:

```sh
# /etc/pbr-split.conf
em1 10.0.1.1
em2 10.0.2.1
```

**FreeBSD / DragonFlyBSD:**

```sh
install -m 0755 pbr-split-bsd.sh /usr/local/sbin/
install -m 0755 pbr-split.freebsd /usr/local/etc/rc.d/pbr-split
sysrc pbr_split_enable=YES          # FreeBSD
# DragonFly: echo 'pbr_split_enable="YES"' >> /etc/rc.conf
service pbr-split start             # logs: /var/log/pbr-split.log
```

**OpenBSD:**

```sh
install -m 0755 pbr-split-bsd.sh /usr/local/sbin/
install -m 0755 pbr-split.openbsd /etc/rc.d/pbr_split
rcctl enable pbr_split
rcctl start pbr_split
```

**NetBSD:**

```sh
install -m 0755 pbr-split-bsd.sh /usr/local/sbin/
install -m 0755 pbr-split.netbsd /etc/rc.d/pbr-split
echo 'pbr_split_enable=YES' >> /etc/rc.conf
service pbr-split start
```

Verify on a live BSD host:

```sh
pbr-split-bsd.sh status
pfctl -a pbr-split -s rules
# traffic from a secondary IP must exit via that subnet's gateway:
#   (setfib is not used; force a lookup that exercises route-to)
#   ping -S <secondary-ip> 8.8.8.8
#   or: sockstat / tcpdump -n on the secondary interface
```

Force re-apply / remove:

```sh
pbr-split-bsd.sh apply      # idempotent; also picks up new leases
pbr-split-bsd.sh restore    # flushes the pbr-split anchor only
pfctl -a pbr-split -F all   # same flush, manual
```

Notes:

- `selftest` is Linux-only (needs netns); on BSD use `status` and
  `pfctl -a pbr-split -s rules` after apply
- watch mode polls every `PBR_POLL_SECONDS` (default 15) with a state
  fingerprint — same latency class as the RouterOS scheduler
- IPv4 only; the script never rewrites your main routing table

### MikroTik CHR (RouterOS v7)

RouterOS has no cloud-init — install is a one-time manual import (or use
the REST API / Netinstall file push). The script uses the native v7
features: named routing tables (`/routing table`), rules
(`/routing/rule`), and a scheduler that re-applies every 15 s (state-guarded
fingerprint, so idle re-runs are a cheap no-op).

```
/system identity set name=chr-pbr   # optional, easier to spot in logs
# upload pbr-split.rsc (WebFig Files / scp / REST), then:
/import file-name=pbr-split.rsc
```

The script self-installs the scheduler `pbr-split-watch`
(`interval=15s`, `start-time=startup`), which is the RouterOS equivalent
of the Linux `watch` service: it re-applies after reboot, on DHCP changes
and on hot-plug, with ~15 s detection latency.

Give each WAN/dhcp-client a **distinct distance**
(`/ip dhcp-client set ... distance=N`) so the primary (unbound fallback)
is unambiguous; ties are logged.

Verify on a live CHR:

```
/routing rule print where comment="pbr-split"
/ip route print where routing-table~"^pbr-"
/tool traceroute address=8.8.8.8 src-address=<secondary-ip>
```

Force re-apply (e.g. after a manual default-route edit):

```
:global pbrSplitForce
:set pbrSplitForce true
/import file-name=pbr-split.rsc
```

Remove everything it created (rules, tables, scheduler):

```
/routing rule remove [find where comment="pbr-split"]
/ip route remove [find where routing-table~"^pbr-"]
/routing table remove [find where name~"^pbr-"]
/system scheduler remove pbr-split-watch
:global pbrSplitFp
:set pbrSplitFp ""
```

Notes:

- the main table's dynamic defaults are left untouched (RouterOS cannot
  move them); every non-primary default gets a **copy** in table
  `pbr-<interface>` with `gateway@main` resolution and a subnet-route
  copy so the gateway is resolvable inside the table
- RouterOS rules have no `out-interface` match (Linux `oif`); the split
  relies on `src-address` + `interface` rules, which covers the
  instance/multi-WAN use case
- tables need the `fib` flag; keep the filename `pbr-split.rsc` (the
  scheduler re-imports that exact path)
- **untested in this repo** — written against official MikroTik v7
  documentation; run `selftest`-style checks by hand on a lab CHR first

## Adding to an OS image with cloud-init

The service starts on every boot, waits up to 30 s for all subnet default
routes, applies the split once, then watches for changes for the rest of
the instance's life.

### Option A — files baked into the image (recommended)

Bake the platform files above into your image (Packer provisioner,
distrobuilder, diskimage-builder hook, ...):

```
/usr/local/sbin/pbr-split-routingtable.sh    mode 0755
/etc/systemd/system/pbr-split.service        mode 0644   (systemd distros)
/etc/init.d/pbr-split                        mode 0755   (Alpine)
```

then activate with cloud-init user-data:

```yaml
#cloud-config            (systemd distros)
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, pbr-split.service]
```

```yaml
#cloud-config            (Alpine / OpenRC)
runcmd:
  - [apk, add, bash, iproute2]
  - [rc-update, add, pbr-split, default]
  - [rc-service, pbr-split, start]
```

### Option B — fully self-contained user-data (no image baking)

Deliver the files themselves in user-data with `write_files` (paste the
complete file contents as the `content` values):

```yaml
#cloud-config
write_files:
  - path: /usr/local/sbin/pbr-split-routingtable.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # ... full contents of pbr-split-routingtable.sh ...
  - path: /etc/systemd/system/pbr-split.service   # skip on Alpine:
    permissions: '0644'                           # use pbr-split.openrc
    content: |                                   # at /etc/init.d/pbr-split
      [Unit]
      Description=Policy routing: split per-NIC default routes (OpenStack multi-port)
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      Environment=PBR_WAIT_SECONDS=30
      ExecStart=/usr/local/sbin/pbr-split-routingtable.sh watch
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]                 # systemd distros only
  - [systemctl, enable, --now, pbr-split.service]
  # Alpine instead:
  # - [apk, add, bash, iproute2]
  # - [rc-update, add, pbr-split, default]
  # - [rc-service, pbr-split, start]
```

## Hot-plug behaviour

Adding a Neutron port to a running instance:

| Stage | Result |
|---|---|
| immediately after hot-plug | existing IPs unaffected; new port works inside its own subnet; its cross-subnet traffic still uses the primary gateway (may be dropped by anti-spoofing) |
| `watch` sees the change (~1–3 s) | re-applies automatically: new port gets its own table + rules, its IP exits via its own gateway — **no manual step** |

Run `sudo pbr-split-routingtable.sh apply` manually instead if you are not
running the service.

## Selftest

```sh
sudo pbr-split-routingtable.sh selftest
```

Runs entirely in an isolated network namespace (needs root; only extra
kernel requirement is the `dummy` module). Covers: 3-port split, hot-plug
of a 4th port, bound/unbound traffic selection, idempotent double-apply
and full restore.

## Limitations

- IPv4 only (IPv6 not handled)
- a subnet **without** a gateway (no default route) is intentionally left
  in `main` — its own-subnet traffic keeps working
- designed for instances that originate/consume traffic; if the instance
  forwards routed traffic (`ip_forward=1` / `net.inet.ip.forwarding=1`),
  verify behaviour separately
- Linux rules are tagged `protocol 199`; BSD rules live only in the PF
  anchor `pbr-split`; RouterOS objects are tagged `comment=pbr-split` —
  `restore` removes exactly those and nothing else
- BSD/MikroTik/CHR paths are written against upstream docs and base-tool
  behaviour but are **untested in this repo** (no lab hardware here);
  exercise `apply` / `status` / `restore` on a lab host first
