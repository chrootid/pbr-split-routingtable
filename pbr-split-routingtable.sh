#!/bin/bash
# tested: ubuntu, almalinux
function _require_root {
if [[ $(id -u) -ne 0 ]];then 
	echo "require root or sudo"
	exit
fi
}

function _main_program {
if [[ $(ip route list|awk '/default/ {print $5}'|wc -l) -gt 1 ]];then
	ROUTINGTABLEID=1
	SKIPNIC=$(ip route list|awk '/default/ {print $5}'|sort -V|head -n1);
	_clear_routing_table_port
	ip route list|awk '/default/ {print $5}'|sort -V|grep -Ev "$SKIPNIC"|while read -r NIC;do 
		IP=$(ip -4 addr sh|grep $NIC|awk '/inet/ {print $2}'|cut -d\/ -f1);
		echo "$ROUTINGTABLEID port_$NIC" >> /etc/iproute2/rt_tables;
		ip route |grep $NIC|while read -r ROUTE;do 
			ip route add $ROUTE table port_$NIC;
			ip route del $ROUTE;
		done;
		ip rule add from $IP/32 lookup port_$NIC;
		ip rule add oif $NIC table port_$NIC;
		ip rule add iif $NIC table port_$NIC;
		ROUTINGTABLEID=$((ROUTINGTABLEID + 1))
	done
fi
}

function _clear_routing_table_port {
	if [[ ! -d /etc/iproute2 ]] ;then 
		mkdir -p /etc/iproute2
	fi
	touch /etc/iproute2/rt_tables
	sed '/[0-9]* port_*/d' -i /etc/iproute2/rt_tables
}

_require_root
_main_program
