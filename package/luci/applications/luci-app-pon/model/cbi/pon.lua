-- SPDX-License-Identifier: Apache-2.0
-- luci-app-pon: 3-section configuration for both pon-manager and airoha-omcid
-- (UCI schema in tip ships `config pon config`; the XG/XGS-PON uci layout in
-- init.d/airoha-omcid expects `config pon xpon` and `config pon omci`).
-- A two-way write is performed in on_after_commit to keep both stacks in sync.

local uci_cursor = require "luci.model.uci".cursor()
local cbi_add_select = luci.cbi.add_select
local cbi_add_textvalue = luci.cbi.add_textvalue

m = Map("pon", translate("PON"), translate(
	"XGS-PON ONT provisioning. Applied on save; the OMCI daemon must be " ..
	"running for changes to take effect on the wire."))

-- section 1: legacy 'config' for pon-manager + omcid2 daemon
s = m:section(NamedSection, "config", "pon", translate("Provisioning"))
s.addremove = false

o = s:option(Flag, "enabled", translate("Enabled"))
o.default = 1

o = s:option(ListValue, "auth_method", translate("Authentication method"))
o:value("loid", translate("LOID"))
o:value("password", translate("Password"))
o:value("sn", translate("Serial number"))
o:value("hybrid", translate("Hybrid"))
o.default = "loid"

o = s:option(ListValue, "mode", translate("PON mode"))
o:value("xgspon", "XGS-PON (default)")
o:value("xgpon", "XG-PON")
o:value("auto", "Auto")
o.default = "xgspon"

o = s:option(ListValue, "fec", translate("FEC"))
o:value("0", translate("Off"))
o:value("1", translate("On"))
o.default = "0"

-- section 2: 'xpon line0' for airoha-omcid line instance
local x = m:section(NamedSection, "line0", "xpon",
	translate("PON line (airoha-omcid)"))
x.addremove = false

o = x:option(Value, "device", translate("PON interface"))
o.default = "pon0"
o.rmempty = false
o.readonly = true
o.width = "10em"

o = x:option(Value, "serial_number", translate("Serial number (SN)"),
	translate("ONU-G serial. Empty = use factory value."))
o.rmempty = true

o = x:option(Password, "registration_id", translate("Registration-ID"),
	translate("XGS-PON Registration-ID. Empty = device reports all zeros."))
o.rmempty = true

-- section 3: 'omci line0_omci' for airoha-omcid OMCI instance
local k = m:section(NamedSection, "line0_omci", "omci",
	translate("OMCI (airoha-omcid)"))
k.addremove = false

o = k:option(Value, "line", translate("XG-PON config"))
o.default = "line0"
o.readonly = true
o.width = "10em"

o = k:option(Value, "device", translate("OMCI interface"))
o.default = "omc0"
o.readonly = true
o.width = "10em"

o = k:option(Value, "loid", translate("LOID"))
o.rmempty = true

o = k:option(Password, "loid_password", translate("LOID password"))
o.rmempty = true

-- 光前端校准：bosa 单卷上传 (走 controller action_upload_bosa)
local c = m:section(SimpleSection, "_calib", "calib",
	translate("BOSA calibration"))
c.addremove = false
o = c:option(FileUpload, "bosa_bin", translate("PONI cal data"),
	translate("Upload the factory BOSA calibration backup (256 KiB). " ..
		"Reboot for the change to take effect."))
o.template = "cbi/upload_file"

-- 双写同步：legacy <-> airoha-omcid 字段，确保任一 PON 栈生效
function m.on_after_commit(self)
	local function sync(src_sec, src_opt, dst_sec, dst_opt)
		local v = uci_cursor:get("pon", src_sec, src_opt)
		if v then
			if (uci_cursor:get("pon", dst_sec, dst_opt) ~= v) then
				uci_cursor:set("pon", dst_sec, dst_opt, v)
			end
		end
	end

	if not uci_cursor:get("pon", "line0") then
		uci_cursor:set("pon", "line0", "xpon")
	end
	if not uci_cursor:get("pon", "line0_omci") then
		uci_cursor:set("pon", "line0_omci", "omci")
	end

	-- legacy -> xpon/omci
	sync("config", "lo_id", "line0_omci", "loid")
	sync("config", "password", "line0_omci", "loid_password")
	sync("config", "serial_no", "line0", "serial_number")
	-- xpon/omci -> legacy（retro-sync）
	sync("line0_omci", "loid", "config", "lo_id")
	sync("line0_omci", "loid_password", "config", "password")
	sync("line0", "serial_number", "config", "serial_no")

	uci_cursor:save("pon")
	uci_cursor:commit("pon")
end

return m
