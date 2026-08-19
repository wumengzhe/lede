module("luci.controller.policyroute", package.seeall)

local function json_ok(msg)
    luci.http.prepare_content("application/json")
    luci.http.write(luci.json.stringify(msg or {}))
end

local function parse_lines(out)
    local t = {}
    for l in (out or ""):gmatch("[^\n]+") do
        t[#t + 1] = l
    end
    return t
end

function index()
    entry({"admin", "network", "policyroute"},
        cbi("policyroute"),
        _("策略路由"), 60)

    entry({"admin", "network", "policyroute", "ifaces"}, call("action_ifaces")).leaf = true
    entry({"admin", "network", "policyroute", "devices"}, call("action_devices")).leaf = true
    entry({"admin", "network", "policyroute", "status"}, call("action_status")).leaf = true
    entry({"admin", "network", "policyroute", "apply"}, call("action_apply")).leaf = true
end

function action_ifaces()
    local out = luci.sys.exec("/usr/sbin/policyroute list-ifaces 2>/dev/null")
    local ifaces = {}
    for _, l in ipairs(parse_lines(out)) do
        local name, typ, gw = l:match("^(.-)|(.-)|(.*)$")
        if name and name ~= "" then
            ifaces[#ifaces + 1] = { name = name, type = typ, gateway = gw }
        end
    end
    json_ok({ ifaces = ifaces })
end

function action_devices()
    local out = luci.sys.exec("/usr/sbin/policyroute list-devices 2>/dev/null")
    local devs = {}
    for _, l in ipairs(parse_lines(out)) do
        local mac, ip, name = l:match("^(.-)|(.-)|(.*)$")
        if mac and mac ~= "" then
            devs[#devs + 1] = { mac = mac, ip = ip, name = name }
        end
    end
    json_ok({ devices = devs })
end

function action_status()
    local st = luci.sys.exec("/usr/sbin/policyroute status 2>/dev/null")
    json_ok({ status = parse_lines(st) })
end

function action_apply()
    local rc = luci.sys.call("/usr/sbin/policyroute apply >/dev/null 2>&1")
    json_ok({ ok = (rc == 0), code = rc })
end
