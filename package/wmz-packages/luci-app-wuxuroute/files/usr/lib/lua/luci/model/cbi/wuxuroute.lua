-- LuCI CBI model for wuxuroute
-- UCI config: wuxuroute @config[0]
-- 字段: wan_mac / lan_mac / lan_ip / hostname
-- 动态: wifi_mac_<idx>  (每个 WiFi SSID 一个，数量不固定)
-- 选项: auto_wan_mac / auto_lan_mac / auto_wifi / auto_hostname / auto_lan_ip
-- 定时: _preset / _time / schedule (cron 表达式)

m = Map("wuxuroute", translate("无序路由配置"),
	translate("一键配置 WAN/LAN/WiFi MAC 地址、LAN IP、主机名。支持多 SSID 逐个设置，可设置开机或定时自动重置。"))

m.pageaction = false
m.submitbutton = false
m.resetbutton = false
m.chain = "cbi"

-- 渲染时枚举 WiFi 接口（数量不固定）
local wifi_lines = {}
local raw = luci.sys.exec("/usr/sbin/wuxuroute list-wifi 2>/dev/null") or ""
for line in raw:gmatch("[^\n]+") do
	table.insert(wifi_lines, line)
end

-- ===== 顶部工具栏：随机 / 应用 / 重启 / 恢复出厂 / 厂商伪装 =====
tb = m:section(TypedSection, "config", translate("快捷操作"))
tb.anonymous = true
tb.addremove = false
tb.description = [[
<div id="qc-toolbar" style="margin-bottom:1em">
  <button type="button" id="qc-random-all" class="btn cbi-button-apply">]] .. translate("一键随机全部") .. [[</button>
  <button type="button" id="qc-apply" class="btn cbi-button-apply">]] .. translate("保存并应用") .. [[</button>
  <button type="button" id="qc-reboot" class="btn cbi-button-reset">]] .. translate("保存并重启") .. [[</button>
  <button type="button" id="qc-factory" class="btn cbi-button-apply">]] .. translate("恢复出厂 MAC") .. [[</button>
  <label style="margin-left:1em">]] .. translate("MAC 厂商伪装") .. [[
    <select id="qc-oui">
      <option value="">]] .. translate("随机（默认）") .. [[</option>
      <option value="AC:BC:32">Apple</option>
      <option value="94:FE:3B">Xiaomi</option>
      <option value="3C:8D:20">Huawei</option>
      <option value="8C:BF:A6">Samsung</option>
      <option value="A4:2B:B0">TP-Link</option>
      <option value="52:54:00">PC (Realtek)</option>
    </select>
  </label>
  <span id="qc-status" style="margin-left:1em"></span>
</div>
<div id="qc-status-box" style="margin-bottom:1em"></div>
<pre id="qc-debug" style="display:none;max-height:200px;overflow:auto;background:#f5f5f5;border:1px solid #ddd;padding:6px;font-size:11px;white-space:pre-wrap;margin-bottom:1em"></pre>
<script type="text/javascript">
(function(){
	function $(id){return document.getElementById(id);}
	function status(msg, ok){
		var s = $('qc-status');
		if (!s) return;
		s.textContent = msg || '';
		s.style.color = ok ? '#0a0' : '#c00';
	}
	// ---------- 调试日志：写 UI + console（便于 ssh tail /var/log/messages 配合） ----------
	function dbg(tag, info){
		var line = '[' + new Date().toISOString().substr(11,8) + '] ' + tag + ': ' + info;
		try { console.log(line); } catch(e){}
		var box = $('qc-debug');
		if (box){
			var t = box.textContent || '';
			var lines = t.split('\n');
			if (lines.length > 60) lines = lines.slice(-60);
			box.textContent = lines.join('\n') + (t ? '\n' : '') + line;
			box.style.display = 'block';
		}
	}
	// 解析 JSON：见下方 parseLuciJSON（关键 1）
	function parseLuciJSON(text){
		// 不依赖任何特定 XSSI 形状（不同 luci 版本形状不同）：
		// 直接定位首/尾最近的 JSON 边界（{ ... } 或 [ ... ]），
		// 把中间的子串交回 JSON.parse。
		var s = (text == null ? '' : String(text));
		var a = s.indexOf('{'), b = s.indexOf('[');
		var start = -1;
		if (a >= 0 && (b < 0 || a < b)) start = a;
		else if (b >= 0) start = b;
		if (start < 0) return JSON.parse(s);
		var ea = s.lastIndexOf('}'), eb = s.lastIndexOf(']');
		var end = Math.max(ea, eb);
		if (end <= start) return JSON.parse(s);
		return JSON.parse(s.substring(start, end + 1));
	}
	function jsonCall(url, body, cb){
		var xhr = new XMLHttpRequest();
		xhr.open('POST', url, true);
		xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
		xhr.onreadystatechange = function(){
			if (xhr.readyState !== 4) return;
			dbg('xhr', url + ' status=' + xhr.status + ' body=' + (xhr.responseText||'').slice(0, 200));
			try { cb(null, parseLuciJSON(xhr.responseText)); }
			catch (e) { dbg('parse', e.toString() + ' raw=' + (xhr.responseText||'').slice(0, 200)); cb(e, null); }
		};
		xhr.onerror = function(){ dbg('xhr-err', url + ' net fail'); cb(new Error('network error'), null); };
		xhr.send(body || '');
	}
	// ---------- 关键 2：按 field 名后缀匹配 input（不依赖 sec_ref） ----------
	// CBI 渲染时不同 anonymous section 是不同的段引用（secA/secB/secC/...）。
	// 之前用 querySelector('input[name^="cbid.wuxuroute."]') 抓第一个就把 SEC_REF
	// 锁死在「WAN 口设置」section，其他 section 字段（lan_ip/lan_mac/hostname/wifi_mac_*）
	// 拼出来的 name 都不存在，setVal 抛 TypeError → 「生成失败」/ 不显示。
	// 改：按 field 后缀（input[name$=".<field>"]）匹配，跨 section 通用。
	function setVal(field, v){
		var inp = document.querySelector('input[name$=".' + field + '"]');
		if (inp){ inp.value = v; dbg('set', field + '=' + v + ' (input=' + inp.name + ')'); }
		else   { dbg('set-miss', field + ' -> no input[name$=".' + field + '"]'); }
	}
	function getVal(field){
		var inp = document.querySelector('input[name$=".' + field + '"]');
		return inp ? inp.value : '';
	}
	function checkbox(field){
		var inp = document.querySelector('input[type="checkbox"][name$=".' + field + '"]');
		return inp ? inp.checked : false;
	}
	function wifiFields(){
		return document.querySelectorAll('input[name*=".wifi_mac_"][name^="cbid.wuxuroute."]');
	}
	// (旧 setVal/getVal/checkbox/wifiFields 已重定义)
	function curOui(){
		var sel = $('qc-oui');
		return (sel && sel.value) ? sel.value : '';
	}
	function reqMac(cb){
		var oui = curOui();
		var body = oui ? ('oui=' + encodeURIComponent(oui)) : '';
		jsonCall(L.url('admin/network/wuxuroute/gen_mac'), body, cb);
	}
	function randomInto(target){
		dbg('rand', 'target=' + target);
		if (target === 'hostname') {
			jsonCall(L.url('admin/network/wuxuroute/gen_hostname'), '', function(err, d){
				if (!err && d && d.hostname) setVal('hostname', d.hostname);
				else { dbg('rand-fail', 'hostname: ' + (err ? err.toString() : JSON.stringify(d))); }
			});
		} else {
			reqMac(function(err, d){
				if (!err && d && d.mac) setVal(target, d.mac);
				else { dbg('rand-fail', target + ': ' + (err ? err.toString() : JSON.stringify(d))); }
			});
		}
	}
	function buildBody(includeAuto){
		var body = 'wan_mac=' + encodeURIComponent(getVal('wan_mac')) +
			'&lan_mac=' + encodeURIComponent(getVal('lan_mac')) +
			'&hostname=' + encodeURIComponent(getVal('hostname')) +
			'&lan_ip=' + encodeURIComponent(getVal('lan_ip'));
		var wfs = wifiFields();
		for (var i=0; i<wfs.length; i++){
			var m = wfs[i].name.match(/wifi_mac_(\d+)$/);
			if (m && wfs[i].value) body += '&wifi_mac_' + m[1] + '=' + encodeURIComponent(wfs[i].value);
		}
		if (includeAuto){
			body += '&auto_wan_mac=' + (checkbox('auto_wan_mac') ? '1' : '');
			body += '&auto_lan_mac=' + (checkbox('auto_lan_mac') ? '1' : '');
			body += '&auto_wifi=' + (checkbox('auto_wifi') ? '1' : '');
			body += '&auto_hostname=' + (checkbox('auto_hostname') ? '1' : '');
			body += '&auto_lan_ip=' + (checkbox('auto_lan_ip') ? '1' : '');
		}
		// 定时：直接送 cron 表达式（也兼容旧 0/1/2）
		var sched = getVal('schedule');
		body += '&schedule=' + encodeURIComponent(sched || '');
		dbg('body', body);
		return body;
	}

	// ---------- 定时辅助：预设 ↔ cron 双向同步 ----------
	function pad2(n){ n = parseInt(n, 10) || 0; return (n < 10 ? '0' : '') + n; }
	function parseCron(c){
		if (!c || c.trim() === '') return { preset:'', time:'' };
		// daily:    "M H * * *"
		var dm = c.match(/^(\d+)\s+(\d+)\s+\*\s+\*\s+\*$/);
		if (dm) return { preset:'daily',   time: pad2(dm[2]) + ':' + pad2(dm[1]) };
		// weekday:  "M H * * 1-5"
		var wm = c.match(/^(\d+)\s+(\d+)\s+\*\s+\*\s+1-5$/);
		if (wm) return { preset:'weekday', time: pad2(wm[2]) + ':' + pad2(wm[1]) };
		// weekend:  "M H * * 6,0"
		var em = c.match(/^(\d+)\s+(\d+)\s+\*\s+\*\s+6,0$/);
		if (em) return { preset:'weekend', time: pad2(em[2]) + ':' + pad2(em[1]) };
		// legacy 0/1/2 (旧 schema)
		if (c === '1') return { preset:'daily',   time:'04:00' };
		if (c === '2') return { preset:'weekday', time:'04:00' };
		return { preset:'__custom__', time:'' };
	}
	function buildCron(preset, time){
		var parts = (time || '04:00').split(':');
		var h = parseInt(parts[0], 10) || 0;
		var m = parseInt(parts[1], 10) || 0;
		if (preset === 'daily')   return m + ' ' + h + ' * * *';
		if (preset === 'weekday') return m + ' ' + h + ' * * 1-5';
		if (preset === 'weekend') return m + ' ' + h + ' * * 6,0';
		return null;  // 自定义：让用户直接编辑 cron
	}
	function syncScheduleUI(){
		var cronEl  = document.querySelector('input[name$=".schedule"]');
		var presEl  = document.querySelector('select[name$="._preset"]');
		var timeEl  = document.querySelector('input[name$="._time"]');
		if (!cronEl || !presEl) return;
		var init = parseCron(cronEl.value);
		// ListValue 的 "" 与 "__custom__" 都需要落到"自定义"，但 UI 里没显示"自定义"项
		// 这里给 select 加一个临时 option 表示"自定义"
		var customVal = '__custom__';
		if (!presEl.querySelector('option[value="' + customVal + '"]')){
			var opt = document.createElement('option');
			opt.value = customVal;
			opt.textContent = '自定义 cron';
			opt.style.display = 'none';  // 不可选，但程序可设
			presEl.appendChild(opt);
		}
		presEl.value = init.preset || '';
		if (timeEl && init.time) timeEl.value = init.time;
		function refreshCron(){
			var p = presEl.value;
			if (p === '') { cronEl.value = ''; return; }  // 关闭 = 清空 cron
			if (p === customVal) return;  // 自定义：不动 cron
			var c = buildCron(p, timeEl ? timeEl.value : '04:00');
			if (c != null) cronEl.value = c;
		}
		presEl.addEventListener('change', refreshCron);
		if (timeEl) timeEl.addEventListener('change', refreshCron);
		cronEl.addEventListener('change', function(){
			var cur = parseCron(cronEl.value);
			presEl.value = cur.preset || customVal;
			if (timeEl && cur.time) timeEl.value = cur.time;
		});
	}

	window.addEventListener('DOMContentLoaded', function(){
		// 回填当前值
		jsonCall(L.url('admin/network/wuxuroute/get'), '', function(err, data){
			if (err || !data) return;
			if (data.wan_mac)    setVal('wan_mac',  data.wan_mac);
			if (data.lan_mac)    setVal('lan_mac',  data.lan_mac);
			if (data.hostname)   setVal('hostname', data.hostname);
			if (data.lan_ip)     setVal('lan_ip',   data.lan_ip);
			var count = parseInt(data.wifi_count || '0', 10);
			for (var i=0; i<count; i++){
				if (data['wifi_' + i + '_mac']) setVal('wifi_mac_' + i, data['wifi_' + i + '_mac']);
			}
		});
		// 实时状态
		jsonCall(L.url('admin/network/wuxuroute/status'), '', function(err, d){
			if (err || !d) return;
			function row(k, v){ return '<tr><td style="padding:2px 8px;font-weight:bold">' + k + '</td><td style="padding:2px 8px">' + v + '</td></tr>'; }
			var html = '<table class="cbi-table" style="border-collapse:collapse">';
			html += row('WAN', d.wan_mac || '-');
			html += row('LAN', d.lan_mac || '-');
			html += row('主机名', d.hostname || '-');
			html += row('LAN IP', d.lan_ip || '-');
			var c = parseInt(d.wifi_count || '0', 10);
			for (var i=0; i<c; i++){
				var s = d['wifi_' + i + '_ssid'] || ('SSID#' + i);
				var cm = d['wifi_' + i + '_config_mac'] || '未设置';
				var em = d['wifi_' + i + '_effective_mac'] || '未知';
				html += row(s, '配置: ' + cm + ' / 实际: ' + em);
			}
			html += '</table>';
			var box = $('qc-status-box');
			if (box) box.innerHTML = html;
		});
		// 定时同步
		syncScheduleUI();
	});

	// 随机按钮（动态生成的 WiFi 行 + 固定字段）
	document.addEventListener('click', function(e){
		var t = e.target;
		if (!t || t.tagName !== 'BUTTON') return;
		var v = t.getAttribute('data-qc-action');
		if (!v) return;
		if (v === 'random_mac') {
			var target = t.getAttribute('data-qc-target');
			reqMac(function(err, d){
				if (err || !d || !d.mac) { status('生成失败', false); return; }
				setVal(target, d.mac);
				status('已生成 ' + d.mac, true);
			});
		} else if (v === 'random_hostname') {
			jsonCall(L.url('admin/network/wuxuroute/gen_hostname'), '', function(err, d){
				if (err || !d || !d.hostname) { status('生成失败', false); return; }
				setVal('hostname', d.hostname);
				status('已生成 ' + d.hostname, true);
			});
		} else if (v === 'random_lan_ip') {
			var n = (Math.floor(Math.random() * 200) + 2);
			var ip = '192.168.' + n + '.1';
			setVal('lan_ip', ip);
			status('已生成 ' + ip + '（请牢记新 IP！）', true);
		}
	});

	$('qc-random-all') && $('qc-random-all').addEventListener('click', function(){
		randomInto('wan_mac');
		randomInto('lan_mac');
		randomInto('hostname');
		var n = (Math.floor(Math.random() * 200) + 2);
		setVal('lan_ip', '192.168.' + n + '.1');
		var wfs = wifiFields();
		for (var i=0; i<wfs.length; i++){
			var m = wfs[i].name.match(/wifi_mac_(\d+)$/);
			if (m) randomInto('wifi_mac_' + m[1]);
		}
		status('已随机生成所有字段，点"保存并应用"生效', true);
	});

	$('qc-apply') && $('qc-apply').addEventListener('click', function(){
		jsonCall(L.url('admin/network/wuxuroute/apply'), buildBody(true), function(err, d){
			if (err) { status('应用失败: ' + err, false); return; }
			status(d && d.log ? d.log : '应用成功', d && d.ok);
		});
	});

	$('qc-reboot') && $('qc-reboot').addEventListener('click', function(){
		if (!confirm('确定要写入配置并 3 秒后重启设备吗？')) return;
		jsonCall(L.url('admin/network/wuxuroute/reboot'), buildBody(false), function(err, d){
			status(d && d.log ? d.log : '正在重启...', d && d.ok);
		});
	});

	$('qc-factory') && $('qc-factory').addEventListener('click', function(){
		if (!confirm('确定清空所有手动 MAC，恢复出厂硬件地址吗？')) return;
		jsonCall(L.url('admin/network/wuxuroute/factory_reset'), '', function(err, d){
			status(d && d.log ? d.log : '已恢复出厂 MAC', d && d.ok);
			setTimeout(function(){ window.location.reload(); }, 1500);
		});
	});
})();
</script>
]]

-- ===== WAN 设置 =====
s = m:section(TypedSection, "config", translate("WAN 口设置"))
s.anonymous = true
s.addremove = false

wan_mac = s:option(Value, "wan_mac", translate("WAN 口 MAC 地址"),
	translate("当前 WAN MAC（也可手动输入新值）。"))
wan_mac.datatype = "macaddr"
wan_mac.rmempty = true
wan_mac.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="wan_mac">]] .. translate("随机 MAC 地址") .. [[</button>]]

-- ===== LAN 设置 =====
s = m:section(TypedSection, "config", translate("LAN 口设置"))
s.anonymous = true
s.addremove = false

lan_ip = s:option(Value, "lan_ip", translate("LAN IP 地址"),
	translate("路由 LAN 侧网关 IP。修改后路由器管理后台地址会变，请牢记新 IP。"))
lan_ip.datatype = "ip4addr"
lan_ip.default = "192.168.2.1"
lan_ip.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_lan_ip">]] .. translate("随机 IP 地址") .. [[</button>]]

lan_mac = s:option(Value, "lan_mac", translate("LAN 口 MAC 地址"))
lan_mac.datatype = "macaddr"
lan_mac.rmempty = true
lan_mac.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="lan_mac">]] .. translate("随机 MAC 地址") .. [[</button>]]

-- ===== WiFi 设置（多 SSID 动态生成）=====
s = m:section(TypedSection, "config", translate("WiFi 设置（多 SSID）"))
s.anonymous = true
s.addremove = false
s.description = translate("每个 SSID 可单独设置 MAC 地址。无论你有几个 WiFi 信号，都会自动读取并列出。")

if #wifi_lines > 0 then
	for _, line in ipairs(wifi_lines) do
		local idx, sec, dev, ssid, mac, ifn = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		local label = (ssid and #ssid > 0 and ssid or ("SSID#" .. idx)) .. " @ " .. (dev and #dev > 0 and dev or "?")
		local cur = (mac and #mac > 0 and mac or translate("（未设置，使用硬件地址）"))
		local opt = s:option(Value, "wifi_mac_" .. idx,
			label,
			translate("当前 MAC: ") .. cur)
		opt.datatype = "macaddr"
		opt.rmempty = true
		opt.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="wifi_mac_]] .. idx .. [[">]] .. translate("随机 MAC 地址") .. [[</button>]]
	end
else
	s.description = translate("未检测到 WiFi 接口（wifi-iface）。如有 WiFi 请先在“网络 → 无线”中配置。")
end

-- ===== 主机名 =====
s = m:section(TypedSection, "config", translate("主机名"))
s.anonymous = true
s.addremove = false

hostname = s:option(Value, "hostname", translate("主机名"),
	translate("设置路由器的设备名称（hostname）。"))
hostname.datatype = "hostname"
hostname.rmempty = true
hostname.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_hostname">]] .. translate("随机 PC 主机名") .. [[</button>]]

-- ===== 开机自动更新 =====
s = m:section(TypedSection, "config", translate("开机自动更新"))
s.anonymous = true
s.addremove = false
s.description = translate("勾选后，每次路由器开机 / 重启时会自动重新生成下列项。配合下方“定时更新”可周期性自动更换。")

auto_wan_mac    = s:option(Flag, "auto_wan_mac",    translate("开机更新 WAN MAC"))
auto_lan_mac    = s:option(Flag, "auto_lan_mac",    translate("开机更新 LAN MAC"))
auto_wifi       = s:option(Flag, "auto_wifi",       translate("开机更新全部 WiFi SSID MAC"))
auto_hostname   = s:option(Flag, "auto_hostname",   translate("开机更新主机名"))
auto_lan_ip     = s:option(Flag, "auto_lan_ip",     translate("开机更新 LAN IP"))
auto_lan_ip.default = "1"
auto_lan_ip.description = translate("LAN IP 默认不随机（避免忘记新 IP 进不了后台）。如要随机生成，取消勾选。")

-- ===== 定时自动更新（cron 表达式）=====
s = m:section(TypedSection, "config", translate("定时自动更新"))
s.anonymous = true
s.addremove = false
s.description = translate("周期性重新生成“开机自动更新”中勾选的项。依赖系统 cron（多数固件已带）。")

preset = s:option(ListValue, "_preset", translate("快捷预设"),
	translate("选预设会自动填充下方的 cron 表达式；选空白则关闭；选其它则直接编辑 cron。"))
preset:value("",     translate("关闭"))
preset:value("daily",   translate("每天 HH:MM"))
preset:value("weekday", translate("工作日（周一至周五）HH:MM"))
preset:value("weekend", translate("周末（周六、周日）HH:MM"))

time_opt = s:option(Value, "_time", translate("时间 (HH:MM)"))
time_opt.default = "04:00"
time_opt.datatype = "string"
time_opt.rmempty = true
time_opt.description = translate("对“每天 / 工作日 / 周末”预设生效；自定义 cron 时忽略。格式 HH:MM，如 04:00 / 23:30。")

schedule = s:option(Value, "schedule", translate("cron 表达式"),
	translate("标准 5 段 cron：分 时 日 月 周。留空 = 关闭。"))
schedule.optional = true
schedule.rmempty = true

return m