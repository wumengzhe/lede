-- SPDX-License-Identifier: Apache-2.0
-- luci-app-pon: status / config / identity / diag tabs + activate/deactivate +
-- JSON status feed consumed by status.htm via setInterval().

local http = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

module("luci.controller.pon", package.seeall)

function index()
	entry({"admin", "status", "pon"},
		template("pon/status"), _("PON"), 90)

	entry({"admin", "network", "pon"},
		cbi("pon"), _("PON"), 90).dependent = false

	entry({"admin", "network", "pon", "identity"},
		template("pon/identity"), _("PON identity"), 91)
	entry({"admin", "network", "pon", "diag"},
		template("pon/diag"), _("PON diagnostics"), 92)

	entry({"admin", "network", "pon", "activate"},
		post("action_activate"), nil)
	entry({"admin", "network", "pon", "deactivate"},
		post("action_deactivate"), nil)

	-- JSON status feed (read-only) used by the status tab refresh loop.
	entry({"admin", "status", "pon", "json"},
		call("action_status_json"), nil)
	entry({"admin", "network", "pon", "json"},
		call("action_status_json"), nil)

	-- BOSA upload endpoint for the configuration tab.
	entry({"admin", "network", "pon", "upload_bosa"},
		call("action_upload_bosa"))
end

local function run_capture(cmd)
	local f = io.popen(cmd .. " 2>/dev/null")
	if not f then return "" end
	local out = f:read("*a") or ""
	f:close()
	return out
end

local function read_kv(text)
	local kv = {}
	for line in text:gmatch("[^\n]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then kv[k] = v end
	end
	return kv
end

local function read_sys(path, fallback)
	local f = io.open(path, "r")
	if not f then return fallback end
	local v = (f:read("*l") or ""):gsub("%s+$", "")
	f:close()
	return v ~= "" and v or fallback
end

local function read_sys_int(path, fallback)
	return tonumber(read_sys(path, "0")) or fallback
end

local function collect_status()
	local st = read_kv(run_capture("ponctl status"))
	local operstate = read_sys("/sys/class/net/pon0/operstate", "unknown")
	local carrier   = read_sys_int("/sys/class/net/pon0/carrier", 0)
	local mtu       = read_sys_int("/sys/class/net/pon0/mtu", 0)
	local rx_bytes  = read_sys_int("/sys/class/net/pon0/statistics/rx_bytes", 0)
	local tx_bytes  = read_sys_int("/sys/class/net/pon0/statistics/tx_bytes", 0)
	local tx_packets= read_sys_int("/sys/class/net/pon0/statistics/tx_packets", 0)
	local ponmgr    = run_capture("pgrep -a -x ponmgr"):gsub("%s+$", "")
	local omcid     = run_capture("pgrep -a -f airoha-omcid"):gsub("%s+$", "")
	local omcid2    = run_capture("pgrep -a -x omcid2"):gsub("%s+$", "")
	local mode_cfg  = uci:get("pon", "config", "mode") or "auto"

	local state = tonumber(st.state) or 0
	local states = {[0]="unknown", [1]="O1 (initial)", [2]="O2 (standby)",
		[3]="O3 (serial number)", [4]="O4 (ranging)", [5]="O5 (operation)"}
	local modes = {[0]="Auto", [1]="XG-PON", [7]="XGS-PON"}
	local onu_state = states[state] or "unknown"

	-- PON map (econet,ecnt-xpon + airoha,an7581-xpon-mac) bridges to o5;
	-- the standard netdev carrier reports link beat, the O5 figure reports
	-- OMCI registration. Treat operstate=up as the user-visible "link up".
	local phy_ready     = (operstate == "up") and "yes" or "no"
	local xgtc_sync     = (state >= 4) and "synchronized" or "not synchronized"
	local los_detection = (st.los == "1") and "no" or "yes"
	local data_path_ok  = (operstate == "up" and carrier == 1) and "yes" or "no"
	local service_ok    = (state >= 5 and carrier == 1) and "yes" or "no"
	local burst_ok      = (tx_packets > 0) and "yes" or "no"

	return {
		state = state,
		onu_state = onu_state,
		los = st.los == "1" and "yes" or "no",
		los_detection = los_detection,
		fec = st.fec == "1" and "on" or "off",
		laser = st.laser == "1" and "on" or "off",
		rx_power = tonumber(st.rx_power) or 0,
		tx_power = tonumber(st.tx_power) or 0,
		temperature = tonumber(st.temperature) or 0,
		bias = tonumber(st.bias) or 0,
		voltage = tonumber(st.voltage) or 0,
		tx_fault = st.tx_fault == "1" and "yes" or "no",
		mode_cfg = mode_cfg,
		mode_drv = modes[tonumber(st.mode) or 0] or (st.mode or "?"),
		phy_ready = phy_ready,
		xgtc_sync = xgtc_sync,
		data_path_ok = data_path_ok,
		service_ok = service_ok,
		burst_ok = burst_ok,
		operstate = operstate,
		carrier = carrier,
		mtu = mtu,
		rx_bytes = rx_bytes,
		tx_bytes = tx_bytes,
		tx_packets = tx_packets,
		ponmgr = (ponmgr ~= "") and "running" or "stopped",
		omcid  = (omcid ~= "") and "running" or "stopped",
		omcid2 = (omcid2 ~= "") and "running" or "stopped",
		applied = "applied",
	}
end

function action_status_json()
	http.prepare_content("application/json")
	local s = collect_status()
	http.write_json({
		state = s.state, onu_state = s.onu_state,
		los = s.los, los_detection = s.los_detection,
		fec = s.fec, laser = s.laser,
		rx_power = string.format("%.2f", s.rx_power / 100),
		tx_power = string.format("%.2f", s.tx_power / 100),
		temperature = string.format("%.2f", s.temperature / 100),
		bias = string.format("%.2f", s.bias / 100),
		voltage = s.voltage,
		tx_fault = s.tx_fault,
		mode_cfg = s.mode_cfg, mode_drv = s.mode_drv,
		phy_ready = s.phy_ready, xgtc_sync = s.xgtc_sync,
		data_path_ok = s.data_path_ok, service_ok = s.service_ok,
		burst_ok = s.burst_ok,
		operstate = s.operstate, carrier = (s.carrier == 1) and "yes" or "no",
		mtu = s.mtu, rx_bytes = s.rx_bytes, tx_bytes = s.tx_bytes,
		tx_packets = s.tx_packets,
		ponmgr = s.ponmgr, omcid = s.omcid, omcid2 = s.omcid2,
		applied = s.applied,
		now = os.time(),
	})
end

function action_activate()
	run_capture("ponctl activate")
	sys.call("/etc/init.d/airoha-omcid restart >/dev/null 2>&1 &")
	luci.http.redirect(luci.dispatcher.build_url("admin/status/pon"))
end

function action_deactivate()
	run_capture("ponctl deactivate")
	sys.call("/etc/init.d/airoha-omcid stop >/dev/null 2>&1 &")
	luci.http.redirect(luci.dispatcher.build_url("admin/status/pon"))
end

-- BOSA upload: drop the multipart body to /tmp/pon-upload.bin, validate
-- 256 KiB cap, then run a one-shot helper that writes via ubiupdatevol to
-- bosa (or equivalently dd to the dynamic ubi-volume-bosa node).  Only the
-- primary bosa volume is exposed in the UI as per upstream guidance.
function action_upload_bosa()
	local fp = io.open("/tmp/pon-upload.bin", "wb")
	if not fp then
		http.status(500, "upload open failed")
		http.write("{\"ok\":false,\"err\":\"open\"}")
		return
	end
	local body = http.content()
	if not body then
		fp:close()
		http.status(400, "missing body")
		http.write("{\"ok\":false,\"err\":\"body\"}")
		return
	end
	local total = 0
	while true do
		local chunk = body(64 * 1024)
		if not chunk or #chunk == 0 then break end
		fp:write(chunk)
		total = total + #chunk
		if total > 262144 then
			fp:close()
			os.remove("/tmp/pon-upload.bin")
			http.status(413, "exceeds 256 KiB")
			http.write("{\"ok\":false,\"err\":\"too_big\"}")
			return
		end
	end
	fp:close()

	local out = run_capture(
		"sh /usr/sbin/pon-vol write bosa /tmp/pon-upload.bin")
	http.prepare_content("application/json")
	if out:match("^OK") then
		http.write_json({ok = true, msg = "bosa written; reboot to take effect"})
	else
		http.write_json({ok = false, err = out:sub(1, 200)})
	end
	os.remove("/tmp/pon-upload.bin")
end
