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

-- 写 syslog（前端 dbg + 后端 logger 配对：ssh 上 tail -f /var/log/messages 就能看全链路）
-- 写 syslog（保护：pcall 兜底，logger/shellquote 自身崩不影响 action）
-- 不再走 luci.util.shellquote + string.format，改为单字符串拼接，
-- 避免 shell 注入或参数解析期抛错连带整个 controller 502。
local function slog(msg)
	msg = tostring(msg or "")
	-- shell 单引号转义：把 ' 换成 '''，外层再加 ' ... '
	local esc = msg:gsub("'", "'\\''")
	pcall(luci.sys.call, "logger -t wuxuroute-cgi '" .. esc .. "' 2>/dev/null")
end

local function run(cmd)
	local out = luci.sys.exec(cmd .. " 2>&1")
	return out or "", 0
end

-- 直接输出 JSON，避开 luci.http.write_json() 自带的 XSSI 前缀
--   <!--/*--><![CDATA[/*><!--*/-->...<!--*/-->
-- 让前端不用任何剥前缀逻辑（防劫持我们改用 HTTPS + 同源 X-Requested-With）。
-- 若上层 luci.json 不可用则降级到手工 JSON（严格按 RFC 8259 转义）。
--
-- *** 重要约定：源文件字节级不允许出现裸控制字符（0x00..0x1F / 0x7F）***
-- 之前一版在 fallback 里写 s:gsub('\b', ...) / s:gsub('\f', ...) / 长注释里
-- 嵌 "[0x01-0x19]"，结果源码字节里含 BS(0x08) / FF(0x0C) / 0x01 / 0x19。
-- LuCI 的 ucodebridge 加载 controller 时被这些字节干扰，报
-- "unexpected symbol near '<'"（uhttpd 502，浏览器 LuCI 全挂）。
-- 修复：fallback 手工 JSON 完全用 s:byte() 按字节遍历，
-- 不再用 string pattern，从根上杜绝控制字符进源码。
local function json_response(tbl)
	luci.http.prepare_content("application/json")
	local ok, enc = pcall(require("luci.json").encode, tbl or {})
	if ok and type(enc) == "string" then
		slog("resp enc_len=" .. #enc .. " head='" .. enc:sub(1, 80) .. "'")
		local wok, werr = pcall(luci.http.write, enc)
		if not wok then
			local emsg = tostring(werr):gsub("'", "'\\''")
			pcall(luci.sys.call, "logger -t wuxuroute-cgi 'json_response write FAIL: " .. emsg .. "' 2>/dev/null")
		end
		return
	end

	-- 退化：纯 byte 级 JSON 序列化（按 RFC 8259 转义）
	-- 永远不写 string pattern；逐字节处理，避免源码污染。
	local function qstr(s)
		s = tostring(s or "")
		local out = {}
		for i = 1, #s do
			local b = s:byte(i)
			if     b == 34 then out[#out+1] = '\\"'
			elseif b == 92 then out[#out+1] = '\\\\'
			elseif b == 10 then out[#out+1] = '\\n'
			elseif b == 13 then out[#out+1] = '\\r'
			elseif b ==  9 then out[#out+1] = '\\t'
			elseif b < 32 or b == 127 then out[#out+1] = ' '
			else out[#out+1] = s:sub(i, i)
			end
		end
		return '"' .. table.concat(out) .. '"'
	end
	local pieces = {}
	for k, v in pairs(tbl or {}) do
		if type(v) == "string"  then pieces[#pieces+1] = '"' .. tostring(k) .. '":' .. qstr(v)
		elseif type(v) == "boolean" then pieces[#pieces+1] = '"' .. tostring(k) .. '":' .. tostring(v)
		elseif type(v) == "number"  then pieces[#pieces+1] = '"' .. tostring(k) .. '":' .. tostring(v)
		elseif type(v) == "table"   then pieces[#pieces+1] = '"' .. tostring(k) .. '":' .. tostring(v.ok or "")
		end
	end
	local fenc = "{" .. table.concat(pieces, ",") .. "}"
	slog("json_response FALLBACK used, enc='" .. fenc:sub(1, 120) .. "'")
	local wok, werr = pcall(luci.http.write, fenc)
	if not wok then
		local emsg = tostring(werr):gsub("'", "'\\''")
		pcall(luci.sys.call, "logger -t wuxuroute-cgi 'json_response write FAIL: " .. emsg .. "' 2>/dev/null")
	end
end

-- 仅允许 MAC / IP / 主机名 / 厂商前缀 / cron 表达式 相关的字符，防注入
local function clean(s)
	if not s then return "" end
	return (s:gsub("[^%x%:%._%-/, 0-9a-zA-Z%*]", ""))
end

local function mac_ok(s)
	return s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

function action_gen_mac()
	slog("hit action_gen_mac oui=" .. clean(luci.http.formvalue("oui") or ""))
	local oui = clean(luci.http.formvalue("oui") or "")
	local cmd = "/usr/sbin/wuxuroute gen-mac"
	if oui ~= "" then
		cmd = cmd .. " --oui " .. oui
	end
	local out = run(cmd)
	slog("gen-mac out='" .. out:gsub("\n","\\n") .. "' (len=" .. #out .. ")")
	json_response({ mac = (out:gsub("%s+", "")) })
end

function action_gen_hostname()
	slog("hit action_gen_hostname")
	local out = run("/usr/sbin/wuxuroute gen-hostname")
	json_response({ hostname = (out:gsub("^%s+", ""):gsub("%s+$", "")) })
end

function action_get()
	slog("hit action_get")
	local out = run("/usr/sbin/wuxuroute get")
	local t = {}
	for k, v in string.gmatch(out, "([%w_]+)=([^\n]*)") do
		t[k] = v
	end
	json_response(t)
end

function action_list_wifi()
	slog("hit action_list_wifi")
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
	slog("hit action_status")
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
	local _wt = luci.http.formvaluetable("wifi_mac_") or {}
	local _wifi_n = 0
	for _ in pairs(_wt) do _wifi_n = _wifi_n + 1 end
	slog("hit action_apply wm=" .. clean(luci.http.formvalue("wan_mac") or "")
		.. " lmm=" .. clean(luci.http.formvalue("lan_mac") or "")
		.. " lip=" .. clean(luci.http.formvalue("lan_ip") or "")
		.. " hn="  .. clean(luci.http.formvalue("hostname") or "")
		.. " sched=" .. clean(luci.http.formvalue("schedule") or "")
		.. " wifi_n=" .. _wifi_n)
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

	local cmd = "/usr/sbin/wuxuroute apply " .. table.concat(args, " ")
	slog("apply cmd='" .. cmd .. "'")
	local out, code = run(cmd)
	slog("apply out='" .. out:gsub("\n","\\n") .. "' (len=" .. #out .. " code=" .. tostring(code) .. ")")
	json_response({ ok = (code == 0), log = out })
end

function action_reboot()
	slog("hit action_reboot")
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
	slog("hit action_factory_reset")
	local out, code = run("/usr/sbin/wuxuroute factory-reset")
	json_response({ ok = (code == 0), log = out })
end

-- 模块加载哨兵（运维必备：模块能不能被 luci 加载，靠这一行：logread -e wuxuroute-cgi）
pcall(luci.sys.call, "logger -t wuxuroute-cgi '[init] wuxuroute controller module LOADED ok' 2>/dev/null")
