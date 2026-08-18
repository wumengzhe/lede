local uci = require "luci.model.uci".cursor()

local m = Map("policyroute", translate("策略路由"),
    translate("按设备 / 端口把流量导向指定出口（多拨 wan/wan1、WireGuard/OpenVPN、"
            .. "passwall/openclash 的 utun）。无需代理也可用——出口只是任意真实接口。"))

local s = m:section(NamedSection, "config", "policyroute", translate("通用"))
s.anonymous = false
s.addremove = false

local en = s:option(Flag, "enabled", translate("启用策略路由"))
en.rmempty = false

-- 当前生效状态（静态展示；刷新页面更新）
local st = luci.sys.exec("/usr/sbin/policyroute status 2>/dev/null")
if st and st ~= "" then
    local si = s:option(DummyValue, "_status", translate("当前生效状态"))
    si.rawhtml = true
    si.value = "<pre style='margin:0'>" .. st:gsub("[<>]", {["<"]="&lt;", [">"]="&gt;"}) .. "</pre>"
end

-- ---- 路由规则 ----
local r = m:section(TypedSection, "rule", translate("路由规则"))
r.template = "cbi/tblsection"
r.addremove = true
r.anonymous = false
r.sortable = true

r:option(Value, "name", translate("名称"))
r:option(Flag,  "enabled", translate("启用"))

local src = r:option(ListValue, "src", translate("源类型"))
src:value("mac", translate("MAC 地址"))
src:value("ip",  translate("IP 地址"))
src:value("host", translate("DHCP 主机名"))

r:option(Value, "value", translate("源值"))

local proto = r:option(ListValue, "proto", translate("协议"))
proto:value("", translate("不限"))
proto:value("tcp", "TCP")
proto:value("udp", "UDP")

local dport = r:option(Value, "dport", translate("目的端口"))
dport.datatype = "port"
dport.optional = true

local iface = r:option(ListValue, "iface", translate("出口接口"))
iface.optional = false
local out = luci.sys.exec("/usr/sbin/policyroute list-ifaces 2>/dev/null")
for l in (out or ""):gmatch("[^\n]+") do
    local name, typ, gw = l:match("^(.-)|(.-)|(.*)$")
    if name and name ~= "" then
        local label = name .. " (" .. (typ or "?") .. ")"
        if gw and gw ~= "" then label = label .. " gw " .. gw end
        iface:value(name, label)
    end
end

r:option(Value, "comment", translate("备注"))

-- ---- 保存后自动应用 ----
m.on_after_commit = function(self)
    -- 按 enabled 开关：开启则 apply，关闭则 stop
    local e = uci:get("policyroute", "config", "enabled")
    if e == "1" then
        luci.sys.call("/usr/sbin/policyroute apply >/dev/null 2>&1")
    else
        luci.sys.call("/usr/sbin/policyroute stop >/dev/null 2>&1")
    end
end

return m
