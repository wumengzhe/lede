local uci = require "luci.model.uci".cursor()

local m = Map("policyroute", translate("Policy Route"),
    translate("Source-based policy routing. Steer each device / port out a chosen egress "
            .. "(multi-WAN, WireGuard, OpenVPN, or passwall/openclash utun). No proxy required "
            .. "&mdash; the egress just has to be a real interface."))

local s = m:section(NamedSection, "config", "policyroute", translate("General"))
s.anonymous = false
s.addremove = false

local en = s:option(Flag, "enabled", translate("Enable Policy Route"))
en.rmempty = false

-- current live state (static; reload page to refresh)
local st = luci.sys.exec("/usr/sbin/policyroute status 2>/dev/null")
if st and st ~= "" then
    local si = s:option(DummyValue, "_status", translate("Live state"))
    si.rawhtml = true
    si.value = "<pre style='margin:0'>" .. st:gsub("[<>]", {["<"]="&lt;", [">"]="&gt;"}) .. "</pre>"
end

-- ---- routing rules ----
local r = m:section(TypedSection, "rule", translate("Routing Rules"))
r.template = "cbi/tblsection"
r.addremove = true
r.anonymous = false
r.sortable = true

r:option(Value, "name", translate("Name"))
r:option(Flag,  "enabled", translate("Enabled"))

local src = r:option(ListValue, "src", translate("Source type"))
src:value("mac", translate("MAC address"))
src:value("ip",  translate("IP address"))
src:value("host", translate("DHCP hostname"))

r:option(Value, "value", translate("Source value"))

local proto = r:option(ListValue, "proto", translate("Protocol"))
proto:value("", translate("Any"))
proto:value("tcp", "TCP")
proto:value("udp", "UDP")

local dport = r:option(Value, "dport", translate("Dest port"))
dport.datatype = "port"
dport.optional = true

local iface = r:option(ListValue, "iface", translate("Egress interface"))
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

r:option(Value, "comment", translate("Comment"))

-- ---- apply hook ----
m.on_after_commit = function(self)
    -- reflect enabled flag: apply when on, stop when off
    local e = uci:get("policyroute", "config", "enabled")
    if e == "1" then
        luci.sys.call("/usr/sbin/policyroute apply >/dev/null 2>&1")
    else
        luci.sys.call("/usr/sbin/policyroute stop >/dev/null 2>&1")
    end
end

return m
