# pbr-split.rsc - policy routing split of default routes for MikroTik CHR
# (RouterOS v7+) - the native RouterOS equivalent of the Linux script
# pbr-split-routingtable.sh.
#
# What it does: for every active default route in the main table except the
# primary one (lowest distance), it creates a dedicated routing table with
# that port's default + subnet routes, and adds rules so traffic sourced
# from / arriving on that port uses its own table. The main table keeps ALL
# original defaults untouched, so unbound traffic always works.
#
# Install (one time):
#   1. upload this file (WebFig Files menu / scp / REST API)
#   2. /import file-name=pbr-split.rsc
#   The script self-installs a scheduler (pbr-split-watch, every 15s,
#   start-time=startup) that re-applies automatically after reboot, on
#   hot-plug and on DHCP changes. Keep the filename as pbr-split.rsc.
#
# Force re-apply:
#   :global pbrSplitForce
#   :set pbrSplitForce true
#   /import file-name=pbr-split.rsc
#
# Verify:
#   /routing rule print where comment="pbr-split"
#   /ip route print where routing-table~"^pbr-"
#   /tool traceroute address=8.8.8.8 src-address=<secondary-ip>
#
# Requirements / notes:
#   - RouterOS v7+ (named tables, /routing/rule). Written against official
#     MikroTik v7 documentation - verify on your CHR before production use.
#   - give each default route a DISTINCT distance (dhcp-client distance=)
#     so the primary (unbound fallback) is unambiguous; ties are logged.
#   - IPv4 only. RouterOS rules have no out-interface match (Linux oif);
#     src-address + interface rules cover the instance use case.
#   - tables are named pbr-<interface>; rules are tagged comment=pbr-split.

:local tag "pbr-split"
:local watchName "pbr-split-watch"
:local tablePrefix "pbr-"
:local tblRe ("^" . $tablePrefix)

:global pbrSplitFp
:global pbrSplitForce

# ---------------------------------------------------------------------------
# fingerprint of the current network state; the split is re-applied only
# when it changed (main table is never modified by us, so this is stable)
# ---------------------------------------------------------------------------
:local fp ""
:foreach rid in=[/ip route find where dst-address=0.0.0.0/0 and routing-table=main] do={
    :local gw [:tostr [/ip route get $rid gateway]]
    :local ifn [:tostr [/ip route get $rid interface]]
    :if ([:len $gw] > 0 && [:len $ifn] > 0) do={
        :set fp ($fp . $gw . "|" . $ifn . "|" . [:tostr [/ip route get $rid distance]] . ";")
    }
}
:foreach aid in=[/ip address find] do={
    :set fp ($fp . [:tostr [/ip address get $aid address]] . "@" . [:tostr [/ip address get $aid interface]] . ";")
}

:local ruleCount [:len [/routing rule find where comment=$tag]]
:local defCount 0
:foreach rid in=[/ip route find where dst-address=0.0.0.0/0 and routing-table=main] do={
    :local gw [:tostr [/ip route get $rid gateway]]
    :local ifn [:tostr [/ip route get $rid interface]]
    :if ([:len $gw] > 0 && [:len $ifn] > 0) do={
        :set defCount ($defCount + 1)
    }
}

:local needApply false
:if ($fp != $pbrSplitFp) do={ :set needApply true }
:if ($pbrSplitForce = true) do={ :set needApply true }
:if ($defCount >= 2 && $ruleCount = 0) do={ :set needApply true }
:if ($defCount < 2 && $ruleCount > 0) do={ :set needApply true }

:if ($needApply) do={

    # --- restore: remove everything we created (rules, routes, tables) ---
    /routing rule remove [find where comment=$tag]
    :foreach rid in=[/ip route find where routing-table~$tblRe] do={
        /ip route remove $rid
    }
    :foreach tid in=[/routing table find where name~$tblRe] do={
        /routing table remove $tid
    }

    # --- detect default routes in main (same predicate as fingerprint) ---
    :local gws {}
    :local ifs {}
    :local dists {}
    :foreach rid in=[/ip route find where dst-address=0.0.0.0/0 and routing-table=main] do={
        :local gw [:tostr [/ip route get $rid gateway]]
        :local ifn [:tostr [/ip route get $rid interface]]
        :if ([:len $gw] > 0 && [:len $ifn] > 0) do={
            :set gws ($gws, $gw)
            :set ifs ($ifs, $ifn)
            :set dists ($dists, [/ip route get $rid distance])
        }
    }
    :local n [:len $gws]

    # --- primary = default with the lowest distance; it stays in main ---
    :local pIdx -1
    :local pDist 99999
    :local ties 0
    :if ($n > 0) do={
        :for i from=0 to=($n - 1) do={
            :local d [:pick $dists $i]
            :if ($d < $pDist) do={
                :set pDist $d
                :set pIdx $i
                :set ties 1
            } else={
                :if ($d = $pDist) do={ :set ties ($ties + 1) }
            }
        }
        :if ($ties > 1) do={
            /log warning "pbr-split: several defaults share the lowest distance - set distinct distances (ip dhcp-client distance=) so the primary is unambiguous"
        }
    }

    # --- split every non-primary default into its own table ---
    :if ($n > 0) do={
        :for i from=0 to=($n - 1) do={
            :if ($i != $pIdx) do={
                :local gw [:pick $gws $i]
                :local ifn [:pick $ifs $i]
                :local dist [:pick $dists $i]
                :local tbl ($tablePrefix . $ifn)

                :if ([:len [/routing table find where name=$tbl]] = 0) do={
                    /routing table add name=$tbl fib
                }

                # subnet route(s) in the table, so the gateway is resolvable
                # inside the table (official MikroTik pattern)
                :foreach aid in=[/ip address find where interface=$ifn] do={
                    :local addrStr [:tostr [/ip address get $aid address]]
                    :local slash [:find $addrStr "/"]
                    :if ($slash != nil) do={
                        :local mask [:pick $addrStr $slash [:len $addrStr]]
                        :local net [:tostr [/ip address get $aid network]]
                        /ip route add dst-address=($net . $mask) gateway=$ifn routing-table=$tbl
                    }
                }

                # default route copy; plain IP gateways are resolved via main
                # (v7 gateway@table pattern) as additional safety
                :local gwSpec $gw
                :if ([:typeof [:toip $gw]] = "ip") do={
                    :if ([:find $gw "@"] = nil) do={
                        :set gwSpec ($gw . "@main")
                    }
                }
                /ip route add dst-address=0.0.0.0/0 gateway=$gwSpec distance=$dist routing-table=$tbl

                # rules: one source rule per IPv4 address of the port ...
                :foreach aid in=[/ip address find where interface=$ifn] do={
                    :local addrStr [:tostr [/ip address get $aid address]]
                    :local slash [:find $addrStr "/"]
                    :local ipPart $addrStr
                    :if ($slash != nil) do={ :set ipPart [:pick $addrStr 0 $slash] }
                    /routing rule add src-address=($ipPart . "/32") action=lookup table=$tbl comment=$tag
                }
                # ... plus one for traffic arriving on the port (Linux iif)
                /routing rule add interface=$ifn action=lookup table=$tbl comment=$tag

                /log info ("pbr-split: split " . $ifn . " -> table " . $tbl)
            }
        }
    }

    # --- commit state; only reached when every step above succeeded ---
    :set pbrSplitFp $fp
    :set pbrSplitForce false
    /log info ("pbr-split: applied, defaults=" . $n . ", rules=" . [:len [/routing rule find where comment=$tag]] . ", tables=" . [:len [/routing table find where name~$tblRe]])
}

# ---------------------------------------------------------------------------
# watch: re-apply every 15s (state-guarded, so normally a cheap no-op)
# and at boot (start-time=startup == systemd enable / OpenRC default)
# ---------------------------------------------------------------------------
:if ([:len [/system scheduler find where name=$watchName]] = 0) do={
    /system scheduler add name=$watchName interval=15s start-time=startup on-event="/import file-name=pbr-split.rsc"
    /log info "pbr-split: watch scheduler installed (pbr-split-watch)"
}
