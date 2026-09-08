local sys = require "luci.sys"

m = Map("pon", translate("PON / XGSPON 设置"))
m.description = translate("配置 Airoha AN7581 XGSPON 注册凭证。保存后将重启 PON 服务使配置生效。BOSA/RI 校准数据请在“BOSA / RI 校准”页上传。")

s = m:section(NamedSection, "config", "pon", translate("PON 注册凭证"))

o = s:option(Flag, "enabled", translate("启用 PON"))
o.default = o.enabled or "1"

o = s:option(ListValue, "auth_method", translate("认证方式"))
o:value("loid", translate("LOID"))
o:value("password", translate("Password"))
o:value("sn", translate("SN"))
o:value("hybrid", translate("Hybrid"))

o = s:option(Value, "lo_id", translate("LOID / SLID"))
o.datatype = "string"
o.placeholder = "如 5912519971"

o = s:option(Value, "password", translate("LOID 密码 (PLOAM)"))
o.datatype = "string"
o.password = false

o = s:option(Value, "serial_no", translate("ONU SN (4字母+8字符)"))
o.datatype = "string"
o.placeholder = "如 NBELB45F6727"

o = s:option(ListValue, "mode", translate("模式"))
o:value("xgpon", translate("XG-PON"))
o:value("xgspon", translate("XGSPON"))
o:value("auto", translate("Auto"))

o = s:option(Flag, "fec", translate("FEC"))
o.default = "0"

function m.on_after_save(self)
	sys.call("/etc/init.d/pon restart >/dev/null 2>&1")
end

return m
