-- LuCI controller for wuxuroute
-- 路径: admin/network/wuxuroute
-- 子命令:
--   /admin/network/wuxuroute/gen_mac        POST 单个随机 MAC（可选 oui=厂商前缀）
--   /admin/network/wuxuroute/gen_hostname   POST 随机主机名
--   /admin/network/wuxuroute/get            GET  当前值（含每个 WiFi SSID）
--   /admin/network/wuxuroute/list_wifi      GET  WiFi 接口列表
--   /admin/network/wuxuroute/status         GET  系统实际生效 MAC（配置值 vs 实际值）
--   /admin/network/wuxuroute/apply          POST 应用（不重启设备）
--   /admin/network/wuxuroute/reboot         POST 立即应用并重启
--   /admin/network/wuxuroute/factory_reset  POST 清空所有手动 macaddr（恢复出厂 MAC）

module("luci.controller.wuxuroute", package.seeall)

function index()
	entry({"admin", "network", "wuxuroute"},
		cbi("wuxuroute"),
		_("无序路由配置"),
		90).leaf = true

	entry({"admin", "network", "wuxuroute", "gen_mac"},
		call("action_gen_mac"))

	entry({"admin", "network", "wuxuroute", "gen_hostname"},
		call("action_gen_hostname"))

	entry({"admin", "network", "wuxuroute", "get"},
		call("action_get"))

	entry({"admin", "network", "wuxuroute", "list_wifi"},
		call("action_list_wifi"))

	entry({"admin", "network", "wuxuroute", "status"},
		call("action_status"))

	entry({"admin", "network", "wuxuroute", "apply"},
		call("action_apply"))

	entry({"admin", "network", "wuxuroute", "reboot"},
		call("action_reboot"))

	entry({"admin", "network", "wuxuroute", "factory_reset"},
		call("action_factory_reset"))
end

-- ---------- 工具 ----------

local function run(cmd)
	local out = luci.sys.exec(cmd .. " 2>&1")
	return out or "", 0
end

local function json_response(tbl)
	luci.http.prepare_content("application/json")
	luci.http.write_json(tbl or {})
end

-- 仅允许 MAC / IP / 主机名 / 厂商前缀 相关的字符，防注入
local function clean(s)
	if not s then return "" end
	return (s:gsub("[^%x%:%._%-/, 0-9a-zA-Z]", ""))
end

local function mac_ok(s)
	return s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

function action_gen_mac()
	local oui = clean(luci.http.formvalue("oui") or "")
	local cmd = "/usr/sbin/wuxuroute gen-mac"
	if oui ~= "" then
		cmd = cmd .. " --oui " .. oui
	end
	local out = run(cmd)
	json_response({ mac = (out:gsub("%s+", "")) })
end

function action_gen_hostname()
	local out = run("/usr/sbin/wuxuroute gen-hostname")
	json_response({ hostname = (out:gsub("^%s+", ""):gsub("%s+$", "")) })
end

function action_get()
	local out = run("/usr/sbin/wuxuroute get")
	local t = {}
	for k, v in string.gmatch(out, "([%w_]+)=([^\n]*)") do
		t[k] = v
	end
	json_response(t)
end

function action_list_wifi()
	local out = run("/usr/sbin/wuxuroute list-wifi")
	local list = {}
	for line in out:gmatch("[^\n]+") do
		local idx, sec, dev, ssid, mac, ifn = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		table.insert(list, {
			idx = idx,
			section = sec,
			device = dev,
			ssid = ssid,
			mac = mac,
			ifname = ifn
		})
	end
	json_response({ wifi = list })
end

function action_status()
	local out = run("/usr/sbin/wuxuroute status")
	local t = {}
	for k, v in string.gmatch(out, "([%w_]+)=([^\n]*)") do
		t[k] = v
	end
	json_response(t)
end

-- 把 auto_* / schedule 保存到 wuxuroute 配置段
local function save_flags()
	local function flag(name)
		if luci.http.formvalue(name) then
			uci:set("wuxuroute", "@config[0]", name, "1")
		end
	end
	flag("auto_wan_mac")
	flag("auto_lan_mac")
	flag("auto_wifi")
	flag("auto_hostname")
	flag("auto_lan_ip")
	local sch = clean(luci.http.formvalue("schedule") or "")
	if sch ~= "" then
		uci:set("wuxuroute", "@config[0]", "schedule", sch)
	end
	uci:save("wuxuroute")
	uci:commit("wuxuroute")
end

-- 收集所有 wifi_mac_<idx> 表单值，拼成 --wifi idx mac 参数
local function collect_wifi_args(args)
	local wt = luci.http.formvaluetable("wifi_mac_") or {}
	for idx, mac in pairs(wt) do
		mac = clean(mac)
		if mac ~= "" then
			if not mac_ok(mac) then
				json_response({ ok = false, err = "WiFi MAC 格式错误: " .. mac })
				return false
			end
			table.insert(args, "--wifi")
			table.insert(args, tostring(idx))
			table.insert(args, mac)
		end
	end
	return true
end

function action_apply()
	local wm  = clean(luci.http.formvalue("wan_mac") or "")
	local lmm = clean(luci.http.formvalue("lan_mac") or "")
	local hn  = clean(luci.http.formvalue("hostname") or "")
	local lip = clean(luci.http.formvalue("lan_ip") or "")
	local schedule = clean(luci.http.formvalue("schedule") or "")

	if wm ~= "" and not mac_ok(wm) then json_response({ ok = false, err = "WAN MAC 格式错误" }); return end
	if lmm ~= "" and not mac_ok(lmm) then json_response({ ok = false, err = "LAN MAC 格式错误" }); return end
	if lip ~= "" and not lip:match("^%d+%.%d+%.%d+%.%d+$") then json_response({ ok = false, err = "LAN IP 格式错误" }); return end

	local args = {}
	if wm  ~= "" then table.insert(args, "--wan-mac");  table.insert(args, wm) end
	if lmm ~= "" then table.insert(args, "--lan-mac");  table.insert(args, lmm) end
	if lip ~= "" then table.insert(args, "--lan-ip");   table.insert(args, lip) end
	if hn  ~= "" then table.insert(args, "--hostname"); table.insert(args, hn) end

	if not collect_wifi_args(args) then return end

	save_flags()
	if schedule ~= "" then
		table.insert(args, "--schedule")
		table.insert(args, schedule)
	end

	local out, code = run("/usr/sbin/wuxuroute apply " .. table.concat(args, " "))
	json_response({ ok = (code == 0), log = out })
end

function action_reboot()
	local wm  = clean(luci.http.formvalue("wan_mac") or "")
	local lmm = clean(luci.http.formvalue("lan_mac") or "")
	local hn  = clean(luci.http.formvalue("hostname") or "")
	local lip = clean(luci.http.formvalue("lan_ip") or "")

	if wm ~= "" and not mac_ok(wm) then json_response({ ok = false, err = "WAN MAC 格式错误" }); return end
	if lmm ~= "" and not mac_ok(lmm) then json_response({ ok = false, err = "LAN MAC 格式错误" }); return end
	if lip ~= "" and not lip:match("^%d+%.%d+%.%d+%.%d+$") then json_response({ ok = false, err = "LAN IP 格式错误" }); return end

	local args = {}
	if wm  ~= "" then table.insert(args, "--wan-mac");  table.insert(args, wm) end
	if lmm ~= "" then table.insert(args, "--lan-mac");  table.insert(args, lmm) end
	if lip ~= "" then table.insert(args, "--lan-ip");   table.insert(args, lip) end
	if hn  ~= "" then table.insert(args, "--hostname"); table.insert(args, hn) end

	if not collect_wifi_args(args) then return end

	luci.sys.exec("(/usr/sbin/wuxuroute apply-and-reboot " .. table.concat(args, " ") .. " >/dev/null 2>&1) &")
	json_response({ ok = true, log = "将在 3 秒后重启设备" })
end

function action_factory_reset()
	local out, code = run("/usr/sbin/wuxuroute factory-reset")
	json_response({ ok = (code == 0), log = out })
end
