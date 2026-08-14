#!/bin/sh
# netifd `pon` protocol handler. The PON data plane is `pon0` (gdm2/pon_pcs);
# bring-up of the optical link is driven by ponmgr over the driver genl/char
# interfaces, so this handler mostly keeps netifd's view in sync.
# shellcheck disable=SC2034

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. /lib/functions/network.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_pon_init_config() {
	no_device=1
	available=1
	proto_config_add_string device
	proto_config_add_int metric
}

proto_pon_setup() {
	local config="$1"
	local device metric state

	json_get_vars device metric

	# ponctl reports the PON state machine (O1..O5). Only O5 means the link
	# is usable; anything else is reported as down so netifd does not raise
	# a WAN that cannot pass traffic. If ponmgr is not running, also down.
	if ! command -v ponctl >/dev/null 2>&1; then
		proto_notify_error "$config" "NO_PONMGR"
		proto_block_restart "$config"
		return
	fi

	state=$(ponctl status 2>/dev/null | sed -n 's/.*state=\([0-9]*\).*/\1/p')
	if [ "$state" = "5" ]; then
		proto_init_update "$device" 1
	else
		proto_init_update "$device" 0
	fi
	proto_add_ipv4_address 0.0.0.0 0
	proto_send_update "$config"
}

proto_pon_teardown() {
	local config="$1"
	proto_kill_command "$config" 2>/dev/null
}

[ -n "$INCLUDE_ONLY" ] || add_protocol pon
