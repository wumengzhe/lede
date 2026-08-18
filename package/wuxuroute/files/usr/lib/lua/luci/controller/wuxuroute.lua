-- LuCI controller for wuxuroute
-- 路径: admin/network/wuxuroute
-- 子命令:
--   /admin/network/wuxuroute/random       POST 一次性生成 4 个 MAC + 主机名（仅输出）
--   /admin/network/wuxuroute/gen_mac       POST 单个随机 MAC
--   /admin/network/wuxuroute/gen_hostname  POST 随机主机名
--   /admin/network/wuxuroute/get           GET  当前值（用于表单回填）
--   /admin/network/wuxuroute/apply         POST 应用（不重启设备）
--   /admin/network/wuxuroute/reboot        POST 立即应用并重启
--   /admin/network/wuxuroute/factory_reset POST 清空所有手动 macaddr（恢复出厂 MAC）

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

	entry({"admin", "network", "wuxuroute", "apply"},
		call("action_apply"))

	entry({"admin", "network", "wuxuroute", "reboot"},
		call("action_reboot"))

	entry({"admin", "network", "wuxuroute", "factory_reset"},
		call("action_factory_reset"))
end

-- ---------- 子命令 ----------

local function run(cmd)
	-- luci.sys.exec 在 LuCI 中是首选（基于 C 的 popen，跨平台稳定）
	local out = luci.sys.exec(cmd .. " 2>&1")
	return out or "", 0
end

local function json_response(tbl)
	luci.http.prepare_content("application/json")
	luci.http.write_json(tbl or {})
end

function action_gen_mac()
	local out = run("/usr/sbin/wuxuroute gen-mac")
	json_response({ mac = (out:gsub("%s+", "")) })
end

function action_gen_hostname()
	local out = run("/usr/sbin/wuxuroute gen-hostname")
	json_response({ hostname = (out:gsub("^%s+", ""):gsub("%s+$", "")) })
end

function action_get()
	local out = run("/usr/sbin/wuxuroute get")
	-- 解析 key=value
	local t = {}
	for k, v in string.gmatch(out, "([%w_]+)=([^\n]+)") do
		t[k] = v
	end
	json_response(t)
end

function action_apply()
	-- 从 POST 取 6 个值
	local wm   = luci.http.formvalue("wan_mac")     or ""
	local lmm  = luci.http.formvalue("lan_mac")     or ""
	local w2m  = luci.http.formvalue("wifi2g_mac")  or ""
	local w5m  = luci.http.formvalue("wifi5g_mac")  or ""
	local hn   = luci.http.formvalue("hostname")    or ""
	local lip  = luci.http.formvalue("lan_ip")      or ""

	-- 简单校验 MAC / IP 格式，避免注入
	local function ok(s) return (not s) or s:match("^[%x%:%-%.,_/ 0-9a-zA-Z]+$") ~= nil end
	if not (ok(wm) and ok(lmm) and ok(w2m) and ok(w5m) and ok(hn) and ok(lip)) then
		json_response({ ok = false, err = "参数含非法字符" })
		return
	end

	-- 过滤空值，让 wuxuroute 内部决定是否更新
	local args = {}
	if wm  ~= "" then table.insert(args, wm) end
	if lmm ~= "" then table.insert(args, lmm) end
	if w2m ~= "" then table.insert(args, w2m) end
	if w5m ~= "" then table.insert(args, w5m) end
	if hn  ~= "" then table.insert(args, hn) end
	if lip ~= "" then table.insert(args, lip) end

	-- 把 auto_* 选项也带过来
	if luci.http.formvalue("auto_wan_mac")    then uci:set("wuxuroute", "@config[0]", "auto_wan_mac",    "1") end
	if luci.http.formvalue("auto_lan_mac")    then uci:set("wuxuroute", "@config[0]", "auto_lan_mac",    "1") end
	if luci.http.formvalue("auto_wifi2g_mac") then uci:set("wuxuroute", "@config[0]", "auto_wifi2g_mac", "1") end
	if luci.http.formvalue("auto_wifi5g_mac") then uci:set("wuxuroute", "@config[0]", "auto_wifi5g_mac", "1") end
	if luci.http.formvalue("auto_hostname")   then uci:set("wuxuroute", "@config[0]", "auto_hostname",   "1") end
	if luci.http.formvalue("auto_lan_ip")     then uci:set("wuxuroute", "@config[0]", "auto_lan_ip",     "1") end
	uci:save("wuxuroute")
	uci:commit("wuxuroute")

	-- 同时把"立即应用"用的值记到 last_*，方便 reboot
	uci:set("wuxuroute", "@config[0]", "last_wan_mac",    wm)
	uci:set("wuxuroute", "@config[0]", "last_lan_mac",    lmm)
	uci:set("wuxuroute", "@config[0]", "last_wifi2g_mac", w2m)
	uci:set("wuxuroute", "@config[0]", "last_wifi5g_mac", w5m)
	uci:set("wuxuroute", "@config[0]", "last_hostname",   hn)
	uci:set("wuxuroute", "@config[0]", "last_lan_ip",     lip)
	uci:save("wuxuroute")
	uci:commit("wuxuroute")

	local out, code = run("/usr/sbin/wuxuroute apply " .. table.concat(args, " "))
	json_response({ ok = code == 0, log = out })
end

function action_reboot()
	-- 立即应用 + 3 秒后重启
	local wm   = luci.http.formvalue("wan_mac")     or ""
	local lmm  = luci.http.formvalue("lan_mac")     or ""
	local w2m  = luci.http.formvalue("wifi2g_mac")  or ""
	local w5m  = luci.http.formvalue("wifi5g_mac")  or ""
	local hn   = luci.http.formvalue("hostname")    or ""
	local lip  = luci.http.formvalue("lan_ip")      or ""

	local args = {}
	if wm  ~= "" then table.insert(args, wm) end
	if lmm ~= "" then table.insert(args, lmm) end
	if w2m ~= "" then table.insert(args, w2m) end
	if w5m ~= "" then table.insert(args, w5m) end
	if hn  ~= "" then table.insert(args, hn) end
	if lip ~= "" then table.insert(args, lip) end

	-- 后台执行 reboot，3 秒延迟不阻塞 HTTP 响应
	luci.sys.exec("(/usr/sbin/wuxuroute apply-and-reboot " .. table.concat(args, " ") .. " >/dev/null 2>&1) &")
	json_response({ ok = true, log = "将在 3 秒后重启设备" })
end

function action_factory_reset()
	local out, code = run("/usr/sbin/wuxuroute factory-reset")
	json_response({ ok = code == 0, log = out })
end
