#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2014-2018 ANSSI. All Rights Reserved.

# netmonitor.sh - periodically checks network status
# Copyright (C) 2009-2015 SGDSN/ANSSI
# Authors: Florent Chabaud <clipos@ssi.gouv.fr>
#          Mickaël Salaün <clipos@ssi.gouv.fr>
#          Vincent Strubel <clipos@ssi.gouv.fr>
#          Yves-Alexis Perez <clipos@ssi.gouv.fr>
#
# All rights reserved.

source /lib/rc/net/common || exit 1

PIDFILE="${MONITOR_PIDFILE}"
NOIPSEC="pas de tunnel actif"
WAIT="30"
IPSEC_CONF="/var/run/ipsec.conf"
IPSEC_LIST="/var/run/ipsec_gw.list"
IPSEC_CONFIGS="$(cat ${IPSEC_LIST})"
IPSEC_MAIN_CONFIG="$(head -n 1 ${IPSEC_LIST})"

reset_status() {
	write_lock "type: ${MODE}\nlevel: 0"
	update_lock ipsec "${NOIPSEC}"
}

exit_trap() {
	reset_status
	rm -f -- "${PIDFILE}" 2>/dev/null
	exit
}

exit_error() {
	echo "usage: $0 <interface-name> wired|wifi|umts" >&2
	exit_trap
}

log() {
	logger -p daemon.info "net-monitor: ${1}"
}

warn() {
	logger -p daemon.warning "net-monitor: ${1}"
}


[[ $# -ne 2 ]] && exit_error
IFACE="${1}"
MODE="${2}" 

if [[ -e "${PIDFILE}" ]]; then
	kill -- "$(head -c 5 -- "${PIDFILE}")" 2>/dev/null
	kill -9 -- "$(head -c 5 -- "${PIDFILE}")" 2>/dev/null
	rm -f -- "${PIDFILE}" 2>/dev/null
fi

trap exit_trap EXIT
echo "$$" >"${PIDFILE}"


ipsec_conn_status() {
	local config="${1}"
	[[ -n "${config}" ]] || return 1
	local cmdout="$(ipsec status)"
	local myid="$(echo "${cmdout}" | sed -nr "s/^\s*${config}[0-9]+\[[0-9]+\]: +ESTABLISHED[^,]*,[^[]*\[([^]]*)\]\.\.\..*/\1/p")"
	if echo "${cmdout}" | grep -qE "^ *${config}[0-9]+\{[0-9]+\}: +INSTALLED, TUNNEL, ESP "; then
		echo -n "IKE/ESP [${config}]"
	fi
}

ipsec_conn_setup() {
	local config="${1}"
	local num=0
	while true; do 
		if grep -q "^conn ${config}${num}" "${IPSEC_CONF}"; then
			log "trying to bring up ipsec connection ${config}${num}"
			ipsec up "${config}${num}" 1>/dev/null
			if [[ -n "$(ipsec_conn_status "${config}")" ]]; then
				log "ipsec connection ${config}${num} successfully brought up"
				return 0
			fi
		else
			warn "failed to bring any ${config} ipsec connection"
			return 1
		fi
		let "num+=1"
	done
}

ipsec_update() {
	local initiator="${1}"
	local first="y"

	for config in ${IPSEC_CONFIGS}; do
		local state="$(ipsec_conn_status "${config}")"
		if [[ -z "${state}" ]]; then 
			if [[ "${initiator}" != "no" ]]; then
				ipsec_conn_setup "${config}" && state="$(ipsec_conn_status "${config}")"
			fi
		fi

		if [[ -n "${first}" ]]; then
			if [[ -n "${state}" ]]; then
				update_lock ipsec "${state}"
				[[ -c "/dev/leds/ipsec" ]] && echo 1 > "/dev/leds/ipsec"
			else
				update_lock ipsec "${NOIPSEC}"
				[[ -c "/dev/leds/ipsec" ]] && echo 0 > "/dev/leds/ipsec"
			fi
			first=""
		fi
	done
}

INITIATOR="yes"
import_conf_noerr "${CONFLINK}/ipsec" "yes|no" "INITIATOR" 

case "${MODE}" in
wired)
	update_lock type wired
	sleep 5 # we have to wait for a while for the RUNNING state to be updated
	while true; do
		LVL=0
		if [[ -e "/var/run/nonetwork" ]]; then
			LVL=0
		else
			ip link show "${IFACE}" | grep -q LOWER_UP && LVL=1 
		fi
		update_lock level "${LVL}"
		ipsec_update "${INITIATOR}"
		sleep "${WAIT}"
	done
	;;

wifi)
	while true; do
		ESSID="$(iwconfig "${IFACE}" 2>/dev/null | sed -nr "s/^${IFACE}\s+IEEE 802\.11[^ ]+\s+ESSID:\"(.*)\"\s+?$/\1/p")"
		LEVEL="$(iwconfig "${IFACE}" 2>/dev/null | sed -nr 's/^\s+Link Quality=([0-9]+)\/70\s.*/\1/p')"
		BANDWIDTH="$(iwconfig "${IFACE}" 2>/dev/null | sed -nr 's/^\s+Bit Rate=([0-9\.]+)\s.*/\1/p')"
		if [[ -z "${LEVEL}" ]]; then
			reset_status
		else
			LVL="$((${LEVEL} / 14 ))"
			LEVEL="$((${LEVEL} * 100 / 70))"
			ADDR=""
			[[ -e "/var/run/${IFACE}_dhcp" ]] && ADDR="\n$(cat "/var/run/${IFACE}_dhcp")"
			write_lock "type: wifi\nlevel: ${LVL}\n${ESSID} (${BANDWIDTH} Mb/s ; ${LEVEL} %)${ADDR}"
			ipsec_update "${INITIATOR}"
		fi
		sleep "${WAIT}"
	done
	;;

umts)
	while true; do
		umts_type=$(basename $(readlink "/sys/class/net/${IFACE}/device/driver"))
		ipsec_status="$(ipsec_conn_status "${IPSEC_MAIN_CONFIG}")"
		[[ -n "${ipsec_status}" ]] || ipsec_status="${NOIPSEC}"
		/sbin/umts_config "${NET_STATUS}" "${umts_type}" "${IFACE}" "check" "${ipsec_status}"
		ipsec_update "${INITIATOR}"
		sleep "${WAIT}"
	done
	;;

*)
	exit_error
	;;
esac

reset_status
