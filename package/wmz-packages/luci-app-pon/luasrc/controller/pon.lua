module("luci.controller.pon", package.seeall)

local fs = require "nixio.fs"
local json = require "luci.jsonc"

function index()
	entry({"admin", "network", "pon"}, cbi("pon"),
		_("PON / XGSPON"), 60).dependent = false
	entry({"admin", "network", "pon", "calib"}, template("pon/calib"),
		_("BOSA / RI 校准"), 61).dependent = false
	entry({"admin", "network", "pon", "upload"}, call("action_upload"), nil).leaf = true
	entry({"admin", "network", "pon", "status"}, call("action_status"), nil).leaf = true
end

local function run(cmd)
	local f = io.popen(cmd .. " 2>&1")
	local out = f:read("*a")
	f:close()
	return out or ""
end

function action_status()
	local data = {}
	data.omcid = run("pgrep -x omcid2 >/dev/null && echo running || echo stopped")
	data.ponmgr = run("pgrep -x ponmgr >/dev/null && echo running || echo stopped")
	data.pon_vol = run("/usr/sbin/pon-vol status")
	data.pon0 = run("ip -br link show pon0 2>/dev/null | head -1")
	data.dmesg = run("dmesg | grep -iE 'xpon|omci|airoha' | tail -10")
	luci.http.prepare_content("application/json")
	luci.http.write_json(data)
end

function action_upload()
	local vol = luci.http.formvalue("vol") or ""
	local tmp = luci.http.formvalue("file")
	local res = {}
	if vol ~= "bosa" and vol ~= "ri" then
		res.ok = false
		res.msg = "unknown volume: " .. vol
	elseif not tmp or not fs.access(tmp) then
		res.ok = false
		res.msg = "no file uploaded"
	else
		local out = run("/usr/sbin/pon-vol " .. vol .. " " .. tmp)
		res.ok = (out:match("^OK:") ~= nil)
		res.msg = out
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json(res)
end
