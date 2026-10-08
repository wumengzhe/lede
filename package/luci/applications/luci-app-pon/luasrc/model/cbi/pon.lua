-- SPDX-License-Identifier: Apache-2.0
-- luci-app-pon: configuration (LOID / password / SN / auth method / FEC)
-- stored in /etc/config/pon

m = Map("pon", translate("PON"), translate(
	"XGS-PON ONT provisioning. Activate on the Status page after applying."))

s = m:section(NamedSection, "config", "pon", translate("Provisioning"))
s.addremove = false

o = s:option(Flag, "enabled", translate("Enabled"),
	translate("Start ponmgr and apply provisioning on boot"))
o.default = 1

o = s:option(Value, "lo_id", translate("LOID"),
	translate("Logical ONU ID (optional)"))
o.rmempty = true

o = s:option(Value, "password", translate("Password"),
	translate("ONU password (optional)"))
o.rmempty = true

o = s:option(Value, "serial_no", translate("Serial number"),
	translate("ONU serial number (optional)"))
o.rmempty = true

o = s:option(ListValue, "auth_method", translate("Authentication method"))
o:value("loid", translate("LOID"))
o:value("password", translate("Password"))
o:value("sn", translate("Serial number"))
o:value("hybrid", translate("Hybrid"))
o.default = "loid"

o = s:option(ListValue, "mode", translate("PON mode"),
	translate("Select XGS-PON (10G symmetric) or XG-PON (10G/2.5G). Most new deployments use XGS-PON."))
o:value("xgspon", translate("XGS-PON (default)"))
o:value("xgpon", translate("XG-PON"))
o.default = "xgspon"

o = s:option(ListValue, "fec", translate("FEC"),
	translate("Forward error correction (XGS-PON)"))
o:value("0", translate("Off"))
o:value("1", translate("On"))
o.default = "0"

return m
