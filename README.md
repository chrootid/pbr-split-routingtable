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
| FreeBSD | not supported | different stack (no netlink / `ip rule` / rt_tables) — would need a separate FIB-based implementation |

IPv4 only. The script touches nothing distro-specific beyond `iproute2`.

## Files

| File | Purpose |
|---|---|
| `pbr-split-routingtable.sh` | the script (`apply` / `watch` / `restore` / `status` / `selftest`) |
| `pbr-split.service` | systemd unit (runs `watch`) |
| `pbr-split.openrc` | OpenRC unit for Alpine (runs `watch`) |

## Usage

```sh
sudo pbr-split-routingtable.sh [apply]   # (re)apply the split — idempotent (default)
sudo pbr-split-routingtable.sh watch     # apply, then auto re-apply on changes
sudo pbr-split-routingtable.sh restore   # undo: routes back to main, rules removed
sudo pbr-split-routingtable.sh status    # show defaults, rules and split tables
sudo pbr-split-routingtable.sh selftest  # offline functional test in a netns
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
  forwards routed traffic (`ip_forward=1`), verify behaviour separately
- rules are tagged `protocol 199`; `restore` removes everything this
  script created, nothing else
