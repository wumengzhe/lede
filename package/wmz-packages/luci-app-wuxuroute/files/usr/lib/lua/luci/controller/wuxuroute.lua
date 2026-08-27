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

	entry({"admin", "network", "wuxuroute", "list_wan"},
		call("action_list_wan"))

	entry({"admin", "network", "wuxuroute", "renew"},
		call("action_renew"))
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

-- JSON 输出统一走 luci.http.write_json（LuCI 官方接口，内部已含
-- prepare_content + 编码 + write，各版本行为一致）。它自带的 XSSI 前缀
-- 由前端 parseLuciJSON 自动剥离，无需手工处理。
--
-- 重要约定：源文件字节级不允许出现裸控制字符（0x00..0x1F / 0x7F）。
-- 之前一版在 fallback 里写 s:gsub(...) 并嵌注释，导致源码字节含
-- BS(0x08) / FF(0x0C) / 0x01 / 0x19，ucodebridge 加载时报
-- unexpected symbol near '<'，浏览器 LuCI 全挂。本版全程用 s:byte()
-- 按字节遍历，且转义一律用 string.char()，从根上杜绝特殊字符进源码。
--
-- 手写 prepare_content + 手工 encode 在部分 luci 版本会抛错导致 ajax 500，
-- 故统一用 write_json。整段包 xpcall，任何异常都落 syslog，绝不让 uhttpd 兜底成 500。

-- 退化用：纯 byte 级 JSON 序列化（RFC 8259 转义），仅当 write_json 失败时使用。
local function manual_json(tbl)
	local BS = string.char(92)
	local DQ = string.char(34)
	local function qstr(s)
		s = tostring(s or "")
		local out = {}
		for i = 1, #s do
			local b = s:byte(i)
			if     b == 34 then out[#out+1] = BS .. DQ
			elseif b == 92 then out[#out+1] = BS .. BS
			elseif b == 10 then out[#out+1] = BS .. string.char(110)
			elseif b == 13 then out[#out+1] = BS .. string.char(114)
			elseif b ==  9 then out[#out+1] = BS .. string.char(116)
			elseif b < 32 or b == 127 then out[#out+1] = string.char(32)
			else out[#out+1] = s:sub(i, i)
			end
		end
		return DQ .. table.concat(out) .. DQ
	end
	local pieces = {}
	for k, v in pairs(tbl or {}) do
		if     type(v) == "string"  then pieces[#pieces+1] = DQ .. tostring(k) .. DQ .. ":" .. qstr(v)
		elseif type(v) == "boolean" then pieces[#pieces+1] = DQ .. tostring(k) .. DQ .. ":" .. tostring(v)
		elseif type(v) == "number"  then pieces[#pieces+1] = DQ .. tostring(k) .. DQ .. ":" .. tostring(v)
		elseif type(v) == "table"   then pieces[#pieces+1] = DQ .. tostring(k) .. DQ .. ":" .. tostring(v.ok or "")
		else pieces[#pieces+1] = DQ .. tostring(k) .. DQ .. ":" .. DQ .. DQ
		end
	end
	return "{" .. table.concat(pieces, ",") .. "}"
end

local function json_response(tbl)
	local function log_err(msg)
		local m = tostring(msg)
		slog("json_response ERR: " .. m)
	end
	local ok = xpcall(function()
		local wok, werr = pcall(luci.http.write_json, tbl or {})
		if not wok then
			log_err("write_json failed: " .. tostring(werr) .. " -- fallback manual")
			pcall(luci.http.prepare_content, "application/json")
			pcall(luci.http.write, manual_json(tbl))
		else
			slog("json_response OK (write_json)")
		end
	end, function(e) log_err("THREW: " .. tostring(e)) end)
	if not ok then
		pcall(luci.http.write, "{" .. DQ .. "ok" .. DQ .. ":false," .. DQ .. "err" .. DQ .. ":" .. DQ .. "internal" .. DQ .. "}")
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
	-- 二次校验（防御层 2026-08-27）：必须为合法 MAC 格式。
	-- 作用：挡住"shell 解释器 stderr 漏到 stdout" 这类污染。
	-- 后端 rand_hex 已修（去 od 依赖），但万一再撞上同类问题（比如未来
	-- 引入新 busybox applet），UI 至少不会把错误串当 MAC 写到 input 然后
	-- 假装"已生成"。校验不通过 → {ok=false,err="..."}，前端 randomInto
	-- 看到 !d.ok 立即 status('后端忙，请重试')，不会盲目回填。
	local mac = (out:gsub("%s+", ""))
	if not mac:match("^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]$") then
		slog("gen-mac REJECTED (not MAC format): '" .. out:gsub("\n","\\n") .. "'")
		json_response({ ok = false, err = "后端忙，请稍后重试" })
		return
	end
	json_response({ mac = mac })
end

function action_gen_hostname()
	slog("hit action_gen_hostname")
	local out = run("/usr/sbin/wuxuroute gen-hostname")
	-- 二次校验（防御层 2026-08-27）：hostname 必须是 PC- 开头 + 6 位大写 hex。
	-- 否则拒回，避免 shell stderr（如 'od: not found\nPC-000000'）污染前端。
	local hn = (out:gsub("^%s+", ""):gsub("%s+$", ""))
	-- 修 cbi3 遗留 bug：旧正则 [A-F0-9] 只接大写 hex，但后端 rand_hex 用 tr -dc '0-9a-f'
	-- 输出小写 → 一键随机主机名 100% 被 REJECTED（log 实锤：e0bc46 / be3f2d 全被拒）。
	-- 放宽为 %x（匹配任意十六位 a-fA-F0-9）。
	if not hn:match("^PC%-%x%x%x%x%x%x$") then
		slog("gen-hostname REJECTED (not PC-XXXXXX): '" .. out:gsub("\n","\\n") .. "'")
		json_response({ ok = false, err = "后端忙，请稍后重试" })
		return
	end
	json_response({ hostname = hn })
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
-- 抢救文章：
-- "保存简化模式"的路由
-- ：让 uhttpd 自带的 error500 错误页替换
-- 为我们自己有的有效递 JSON。
-- 在任何 action_* 函数里赌出的异常
-- 都要给 json_response。

local function save_flags()
	-- 重点是 uci 游标必须每次请求
	-- 新建（cursor 有状态，不能横向
	-- 共享）。其他 LuCI 模块也不注
	-- 入这个全局；不加这一句
	-- 就会抛 attempt to index a nil value (global ‘uci’)。
	local uci = require("luci.model.uci").cursor()
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

-- 收集所有 wifi_mac_<sec> 表单值，拼成 --wifi <sec> <mac> 参数
-- 字段名约定：cbi 把字段名编为 `wifi_mac_<sec_safe>`（sec_safe 规则见 cbi.lua），
-- 浏览器 POST 的表单键是 cbid.wuxuroute.config.wifi_mac_<sec_safe>。
-- 关键修复（2026-08-27）：此前用 formvaluetable("wifi_mac_") 做【裸前缀】匹配，
-- 而实际表单键带 cbid. 前缀，永远匹配不到 → wifi_n=0 → 命令行丢失 --wifi → WiFi 不生效。
-- 改：枚举 wireless 的 wifi-iface 段，对每段用 luci.http.formvalue("wifi_mac_"..sec_safe)
-- （无点号 name，带 cbid 兜底，可匹配 cbid.*.<name>）。同时与当前配置比对，未变化的跳过，
-- 避免无谓的 wifi down/up 重建。
local function collect_wifi_args(args)
	local uci = require("luci.model.uci").cursor()
	local err = nil
	uci:foreach("wireless", "wifi-iface", function(s)
		if err then return end
		local sec = s[".name"] or ""
		if sec == "" then return end
		-- 与 cbi.lua 的 sec_safe 规则一致：非字母数字下划线 -> _
		local sec_safe = sec:gsub("[^%w_]", "_")
		-- 浏览器 POST 的键是 cbid.wuxuroute.config.wifi_mac_<sec_safe>；
		-- formvalue(无点号) 带 cbid 兜底，能匹配 cbid.*.<name>
		local val = luci.http.formvalue("wifi_mac_" .. sec_safe)
		if not val or val == "" then return end
		val = clean(val)
		if not mac_ok(val) then
			err = "WiFi MAC 格式错误 (" .. sec .. "): " .. val
			return
		end
		-- 与当前配置比对，未变化的跳过（避免无谓的 wifi down/up 重建）
		local cur = uci:get("wireless", sec, "macaddr") or ""
		if val == cur then return end
		table.insert(args, "--wifi")
		table.insert(args, sec)
		table.insert(args, val)
	end)
	if err then
		json_response({ ok = false, err = err })
		return false
	end
	return true
end

function action_apply()
	slog("hit action_apply wm=" .. clean(luci.http.formvalue("wan_mac") or "")
		.. " lmm=" .. clean(luci.http.formvalue("lan_mac") or "")
		.. " lip=" .. clean(luci.http.formvalue("lan_ip") or "")
		.. " hn="  .. clean(luci.http.formvalue("hostname") or "")
		.. " sched=" .. clean(luci.http.formvalue("schedule") or ""))

	-- 整体包 xpcall：任何异常
	-- (uci 未定义、子脚本闪退、
	-- uci:commit 失败等等)都会落到 syslog，
	-- 并由设备的 catch 在出发一
	-- 个 {ok=false,err="..."} 的就地 JSON，
	-- 绝不会再被 uhttpd 充效成 500。
	local function body()
		local wm  = clean(luci.http.formvalue("wan_mac") or "")
		local lmm = clean(luci.http.formvalue("lan_mac") or "")
		local hn  = clean(luci.http.formvalue("hostname") or "")
		local lip = clean(luci.http.formvalue("lan_ip") or "")
		local oldip = (luci.sys.exec("uci -q get network.lan.ipaddr 2>/dev/null") or ""):gsub("%s+", "")
		local schedule = clean(luci.http.formvalue("schedule") or "")

		if wm ~= "" and not mac_ok(wm) then json_response({ ok = false, err = "WAN MAC 格式错误" }); return end
		if lmm ~= "" and not mac_ok(lmm) then json_response({ ok = false, err = "LAN MAC 格式错误" }); return end
		if lip ~= "" and not lip:match("^%d+%.%d+%.%d+%.%d+$") then json_response({ ok = false, err = "LAN IP 格式错误" }); return end

		local args = {}
		if wm  ~= "" then table.insert(args, "--wan-mac");  table.insert(args, wm) end
		if lmm ~= "" then table.insert(args, "--lan-mac");  table.insert(args, lmm) end
		if lip ~= "" then table.insert(args, "--lan-ip");   table.insert(args, lip) end
		if hn  ~= "" then table.insert(args, "--hostname"); table.insert(args, hn) end
		slog("apply step1 args_built n=" .. #args)

		if not collect_wifi_args(args) then return end
		slog("apply step2 wifi_collected n=" .. #args)

		save_flags()
		slog("apply step3 flags_saved")

		if schedule ~= "" then
			table.insert(args, "--schedule")
			table.insert(args, schedule)
		end

		local cmd = "/usr/sbin/wuxuroute apply " .. table.concat(args, " ")
		slog("apply cmd='" .. cmd .. "'")
		local out, code = run(cmd)
		slog("apply out='" .. out:gsub("\n","\\n") .. "' (len=" .. #out .. " code=" .. tostring(code) .. ")")
		json_response({ ok = (code == 0), log = out,
			old_lan_ip = oldip,
			new_lan_ip = (lip ~= "" and lip or oldip) })
	end

	local ok, err = xpcall(body, function(e) slog("action_apply THREW: " .. tostring(e)) end)
	if not ok then
		json_response({ ok = false, err = tostring(err) })
	end
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

function action_list_wan()
    slog("hit action_list_wan")
    local out = run("/usr/sbin/wuxuroute list-wan")
    local t = { wan = {} }
    local cur = {}
    for k, v in string.gmatch(out, "([%w_]+)=([^\n]*)") do
        local m = k:match("^wan_(%d+)_name$")
        if m then
            cur = { name = v }
            table.insert(t.wan, cur)
        else
            local idx, fld = k:match("^wan_(%d+)_(%w+)$")
            if idx and cur and cur.name and fld then
                cur[fld] = v
            end
        end
    end
    json_response(t)
end

function action_renew()
    local iface = clean(luci.http.formvalue("iface") or "")
    local all = luci.http.formvalue("all")
    local random_mac = luci.http.formvalue("random_mac")
    local mac = clean(luci.http.formvalue("mac") or "")
    slog("hit action_renew iface=" .. iface .. " all=" .. (all or "") .. " random_mac=" .. (random_mac or "") .. " mac=" .. mac)
    local args = {}
    if all and all ~= "" then
        table.insert(args, "--all")
    elseif iface ~= "" then
        table.insert(args, "--iface"); table.insert(args, iface)
    else
        table.insert(args, "--iface"); table.insert(args, "wan")
    end
    if random_mac and random_mac ~= "" and random_mac ~= "0" then
        table.insert(args, "--random-wan-mac")
    elseif mac ~= "" then
        if not mac_ok(mac) then json_response({ ok = false, err = "WAN MAC 格式错误" }); return end
        table.insert(args, "--wan-mac"); table.insert(args, mac)
    end
    local cmd = "/usr/sbin/wuxuroute renew " .. table.concat(args, " ")
    slog("renew cmd='" .. cmd .. "'")
    local out, code = run(cmd)
    slog("renew out='" .. out:gsub("\n","\\n") .. "' (code=" .. tostring(code) .. ")")
    json_response({ ok = (code == 0), log = out })
end


-- 2026-08-27 BUILD_ID：固化源码版本到 init syslog；实机自检只需
-- `logread -e wuxuroute-cgi | head`，首行不匹配这条说明 ipk 没装最新。
-- 本轮 BUILD_ID 改用"日期-特性"标识（不再依赖两次 commit SHA），更稳定：
--   wmz-lede          = @2026-08-27-rng+od-free
--   wmz-lede-multisize = @2026-08-27-rng+od-free
-- 含义：实机反馈"一键随机 → input.value 出现路径/错误串"的根因修复（= 弃
-- 用 od 依赖、改 head+tr、controller 二次校验 + 前端 JS 三重防御 + OUI
-- 占位范例 + cron 表达式实时翻译）。
local BUILD_ID = "wmz-lede@2026-08-27-rng+od-free+cbi7"
pcall(luci.sys.call, "logger -t wuxuroute-cgi '[init] build=" .. BUILD_ID .. " wuxuroute controller module LOADED ok' 2>/dev/null")
