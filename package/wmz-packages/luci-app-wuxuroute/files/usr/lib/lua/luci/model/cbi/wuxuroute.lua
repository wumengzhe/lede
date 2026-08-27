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
      <option value="00:1A:2B">Cisco</option>
      <option value="B0:7F:B9">Netgear</option>
      <option value="00:1F:3B">Intel</option>
      <option value="F4:F5:D8">Google</option>
      <option value="68:37:E9">Amazon</option>
      <option value="04:D4:C4">ASUS</option>
      <option value="1C:7E:E5">D-Link</option>
      <option value="00:1D:0D">Sony</option>
      <option value="AC:22:0B">Microsoft</option>
      <option value="CC:FB:65">Nintendo</option>
      <option value="00:0C:29">VMware</option>
      <option value="00:50:56">VMware (v2)</option>
      <option value="D8:9C:67">Google Nest</option>
    </select>
  </label>
  <label style="margin-left:.4em">]] .. translate("自定义 OUI") .. [[
    <input type="text" id="qc-oui-custom" placeholder="Apple f0:18:98 / Google 3c:5a:b4 / Samsung 9c:65:ee / Microsoft 50:1b:c5 / Cisco 00:1a:2f（不区分大小写、可带 : 或 -）" size="14" style="width:18em">
  </label>
  <span id="qc-status" style="margin-left:1em"></span>
</div>
<div id="qc-status-box" style="margin-bottom:1em"></div>
<style>
#qc-modal .cbi-button-apply, #qc-modal .cbi-button-reset { padding:6px 16px; cursor:pointer; font-size:14px; }
#qc-modal .cbi-button-apply { background:var(--c1,var(--luci-theme-color,#2e8b57)); color:#fff; border:1px solid var(--c1-darker,var(--luci-theme-color-darker,#26734a)); }
#qc-modal .cbi-button-apply:hover { background:var(--c1-darker,var(--luci-theme-color-darker,#26734a)); }
#qc-modal .cbi-button-reset { background:var(--c-button-bg,#eee); color:var(--c-button-fg,#333); border:1px solid var(--c-button-bd,#ccc); }
#qc-modal .cbi-button-reset:hover { background:var(--c-button-bd-hover,#e0e0e0); }
#qc-modal ul { margin:8px 0; }
#qc-modal b { color:inherit; }
#qc-modal-card { background:var(--c-card-bg,var(--luci-card-bg,#fff)); color:var(--c-card-fg,var(--luci-card-fg,#222)); }
#qc-modal-progress { display:none; background:rgba(127,127,127,.18); height:4px; width:100%; overflow:hidden; }
#qc-modal-progress-bar { height:100%; background:var(--c1,var(--luci-theme-color,#2e8b57)); width:0; transition:width 1s linear; }
#qc-warning { background:var(--c-warn-bg,#fff7e0); border:1px solid var(--c-warn-bd,#f0d56a); color:var(--c-warn-fg,#5a4500); padding:8px 12px; border-radius:4px; margin:0 0 8px; line-height:1.5; }
#qc-warning b { color:inherit; }
#qc-warning code { background:rgba(127,127,127,.18); padding:0 4px; border-radius:3px; }
@media (prefers-color-scheme: dark) {
  #qc-modal-card { box-shadow:0 8px 30px rgba(0,0,0,.55); }
  #qc-modal .cbi-button-apply { background:var(--c1,var(--luci-theme-color,#1f6f43)); border-color:var(--c1-darker,#155030); }
  #qc-modal .cbi-button-apply:hover { background:var(--c1-darker,#155030); }
  #qc-modal .cbi-button-reset { background:#2a2a2a; color:#eee; border-color:#444; }
  #qc-modal .cbi-button-reset:hover { background:#333; }
  #qc-warning { background:#3a2e10; border-color:#5a4500; color:#f0d56a; }
}
</style>
<div id="qc-modal" style="display:none;position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.45);align-items:center;justify-content:center">
  <div id="qc-modal-card" style="border-radius:8px;max-width:480px;width:92%;box-shadow:0 8px 30px rgba(0,0,0,.3);font-family:inherit">
    <div id="qc-modal-title" style="padding:14px 18px;font-size:16px;font-weight:bold;color:#fff;border-top-left-radius:8px;border-top-right-radius:8px"></div>
    <div id="qc-modal-body" style="padding:16px 18px;font-size:14px;line-height:1.6"></div>
    <div id="qc-modal-progress"><div id="qc-modal-progress-bar"></div></div>
    <div id="qc-modal-foot" style="padding:12px 18px;border-top:1px solid rgba(127,127,127,.2);text-align:right;display:flex;gap:10px;justify-content:flex-end"></div>
  </div>
</div>
<script type='text/javascript'>
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
	/* 页面不再显示日志，调试信息仅输出到浏览器控制台 */
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
	// 之前用 querySelector 抓第一个 cbid.wuxuroute. 段，把 SEC_REF 锁死在
	// WAN 口设置 section，其他 section 字段（lan_ip/lan_mac/hostname/wifi_mac_*）
	// 拼出来的 name 都不存在，setVal 抛 TypeError → 生成失败 / 不显示。
	// 改：按 field 后缀匹配，跨 section 通用。
	// 注意：刻意不用 querySelector 属性选择器（input[name$=...]），
	// 因其内嵌双引号在传输中常被改写成弯引号，导致选择器静默失效。
	// 改用遍历标签 + 比较 name 后缀/前缀的纯单引号写法，规避弯引号陷阱。
	function qcAll(suffix, prefix){
		var tags = ['input','select','textarea'];
		var out = [];
		for (var t = 0; t < tags.length; t++){
			var els = document.getElementsByTagName(tags[t]);
			for (var i = 0; i < els.length; i++){
				var nm = els[i].name || '';
				var okSuf = suffix ? (nm.length >= suffix.length && nm.lastIndexOf(suffix) === nm.length - suffix.length) : true;
				var okPre = prefix ? (nm.indexOf(prefix) === 0) : true;
				if (okSuf && okPre) out.push(els[i]);
			}
		}
		return out;
	}
	function qcOne(suffix, prefix){
		var a = qcAll(suffix, prefix);
		return a.length ? a[0] : null;
	}
	function setVal(field, v){
		var inp = qcOne('.' + field);
		if (inp){ inp.value = v; dbg('set', field + '=' + v + ' (input=' + inp.name + ')'); }
		else   { dbg('set-miss', field + ' -> no input suffix .' + field); }
	}
	function getVal(field){
		var inp = qcOne('.' + field);
		return inp ? inp.value : '';
	}
	function checkbox(field){
		var inp = qcOne('.' + field);
		return inp ? inp.checked : false;
	}
	function wifiFields(){
		return qcAll('.wifi_mac_', 'cbid.wuxuroute.');
	}
	// (旧 setVal/getVal/checkbox/wifiFields 已重定义)
	function curOui(){
		var custom = $('qc-oui-custom');
		if (custom && custom.value.trim() !== '') return custom.value.trim();
		var sel = $('qc-oui');
		return (sel && sel.value) ? sel.value : '';
	}
	function reqMac(cb){
		var oui = curOui();
		var body = oui ? ('oui=' + encodeURIComponent(oui)) : '';
		jsonCall(L.url('admin/network/wuxuroute/gen_mac'), body, cb);
	}
	function isMacStr(s){ return /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(String(s == null ? '' : s)); }
	function isHostnameStr(s){ return /^PC-[A-F0-9]{6}$/.test(String(s == null ? '' : s)); }
	function randomInto(target){
		dbg('rand', 'target=' + target);
		if (target === 'hostname') {
			jsonCall(L.url('admin/network/wuxuroute/gen_hostname'), '', function(err, d){
				if (err || !d){ dbg('rand-fail', 'hostname: ' + (err ? err.toString() : JSON.stringify(d))); status('生成失败', false); return; }
				if (d.ok === false){ dbg('rand-fail', 'hostname: ' + JSON.stringify(d)); status('生成失败：' + (d.err || '后端忙'), false); return; }
				if (!d.hostname){ dbg('rand-fail', 'hostname empty'); status('生成失败（后端无返回）', false); return; }
				if (!isHostnameStr(d.hostname)){ dbg('rand-fail', 'hostname NOT PC-XXXXXX: ' + d.hostname); status('后端返回异常，请重试', false); return; }
				setVal('hostname', d.hostname);
				status('已生成 ' + d.hostname, true);
			});
		} else {
			reqMac(function(err, d){
				if (err || !d){ dbg('rand-fail', target + ': ' + (err ? err.toString() : JSON.stringify(d))); status('生成失败', false); return; }
				if (d.ok === false){ dbg('rand-fail', target + ': ' + JSON.stringify(d)); status('生成失败：' + (d.err || '后端忙'), false); return; }
				if (!d.mac){ dbg('rand-fail', target + ' mac empty'); status('生成失败（后端无返回）', false); return; }
				if (!isMacStr(d.mac)){ dbg('rand-fail', target + ' NOT MAC: ' + d.mac); status('后端返回异常，请重试', false); return; }
				setVal(target, d.mac);
				status('已生成 ' + d.mac, true);
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
			// 字段名以 sec（ucli 段名）为 key（兼容命名段），不再是数字 idx
			var m = wfs[i].name.match(/\.wifi_mac_(.+)$/);
			if (m && wfs[i].value) body += '&wifi_mac_' + encodeURIComponent(m[1]) + '=' + encodeURIComponent(wfs[i].value);
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
		// daily:    M H * * *
		var dm = c.match(/^(\d+)\s+(\d+)\s+\*\s+\*\s+\*$/);
		if (dm) return { preset:'daily',   time: pad2(dm[2]) + ':' + pad2(dm[1]) };
		// weekday:  M H * * 1-5
		var wm = c.match(/^(\d+)\s+(\d+)\s+\*\s+\*\s+1-5$/);
		if (wm) return { preset:'weekday', time: pad2(wm[2]) + ':' + pad2(wm[1]) };
		// weekend:  M H * * 6,0
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
		var cronEl  = qcOne('.schedule');
		var presEl  = qcOne('._preset');
		var timeEl  = qcOne('._time');
		if (!cronEl || !presEl) return;
		var init = parseCron(cronEl.value);
		// ListValue 的 空串 与 __custom__ 都需要落到「自定义」，但 UI 里没显示「自定义」项
		// 这里给 select 加一个临时 option 表示「自定义」
		var customVal = '__custom__';
		var hasCustom = false;
		for (var oi = 0; oi < presEl.options.length; oi++){
			if (presEl.options[oi].value === customVal){ hasCustom = true; break; }
		}
		if (!hasCustom){
			var opt = document.createElement('option');
			opt.value = customVal;
			opt.textContent = '自定义 cron';
			opt.style.display = 'none';
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

	// ---------- cron 表达式实时翻译（仿 GitHub Actions 工作流） ----------
	// 5 段：分 时 日 月 周。每次输入更新 #qc-cron-hint 的文本与颜色：
	//   空           → 灰色  「留空 = 关闭」
	//   合法 5 段     → 绿色  「在 HH:MM 运行，每周X、Y，每月Z号」
	//   非法（非 5 段）→ 红色  「⚠ 需要 5 段（分 时 日 月 周），当前 N 段」
	function cronToHuman(c){
		var t = (c == null ? '' : String(c));
		t = t.trim();
		if (!t) return '';
		var p = t.split(/\s+/);
		if (p.length !== 5) return '⚠ 需要 5 段（分 时 日 月 周），当前 ' + p.length + ' 段';
		var min = p[0], hh = p[1], dom = p[2], mon = p[3], dow = p[4];
		function pad(n){ n = String(n); return n.length < 2 ? '0' + n : n; }
		var dowName = { '0':'周日','1':'周一','2':'周二','3':'周三','4':'周四','5':'周五','6':'周六','7':'周日' };
		function rangeDow(v){
			if (v === '*') return '每天';
			if (/^\d+$/.test(v)) return dowName[v] || ('周' + v);
			if (v.indexOf(',') >= 0) return v.split(',').map(function(x){ return dowName[x] || x; }).join('、');
		var r = v.match(/^(\d+)-(\d+)$/);
		if (r){
			var i1 = r[1], i2 = r[2];
			var a = dowName[i1] || i1;
			var b = dowName[i2] || i2;
			return a + ' ~ ' + b;
		}
			return v;
		}
		var monName = ['','1 月','2 月','3 月','4 月','5 月','6 月','7 月','8 月','9 月','10 月','11 月','12 月'];
		function rangeMon(v){
			if (v === '*') return '每月';
			if (/^\d+$/.test(v)) return monName[parseInt(v,10)] || ('月' + v);
			if (v.indexOf(',') >= 0) return v.split(',').map(function(x){ return monName[parseInt(x,10)] || x; }).join('、');
			var r = v.match(/^(\d+)-(\d+)$/);
			if (r) return (monName[parseInt(r[1],10)] || r[1]) + ' ~ ' + (monName[parseInt(r[2],10)] || r[2]);
			return v;
		}
		function rangeDom(v){
			if (v === '*') return '每天';
			if (/^\d+$/.test(v)) return '每月 ' + v + ' 号';
			var m = v.match(/^\*\/(\d+)$/);
			if (m) return '每 ' + m[1] + ' 天';
			if (v.indexOf(',') >= 0) return v.split(',').map(function(x){return /\d+/.test(x) ? (x + ' 号') : x; }).join('、');
			var r = v.match(/^(\d+)-(\d+)$/);
			if (r) return r[1] + ' 号 ~ ' + r[2] + ' 号';
			return v;
		}
		var hhNum = parseInt(hh, 10);
		var minNum = (min === '*') ? 0 : parseInt(min, 10);
		// 几种最常见的快捷模式优先描述
		if (hh !== '*' && /^0?\d+$/.test(min) && /^0?\d+$/.test(hh) && dom === '*' && mon === '*' && dow === '*') {
			return ('每天 ' + pad(hh) + ':' + pad(minNum) + ' 运行');
		}
		if (hh !== '*' && /^0?\d+$/.test(min) && /^0?\d+$/.test(hh) && dom === '*' && mon === '*' && dow !== '*') {
			return ('在 ' + pad(hh) + ':' + pad(minNum) + ' 运行（' + rangeDow(dow) + '）');
		}
		if (min === '0' && hh !== '*' && dom === '*' && mon === '*' && dow === '*') {
			return ('每小时整点（' + pad(hh) + ':00）都跑一次 | ' + rangeDom(dom) + ' | ' + rangeMon(mon));
		}
		return ('在 HH:MM = ' + pad(hh) + ':' + pad(minNum) + ' 运行 | ' + rangeDom(dom) + ' | ' + rangeMon(mon) + ' | ' + rangeDow(dow));
	}
	function updateCronHint(){
		var el = qcOne('.schedule');
		var hint = document.getElementById('qc-cron-hint');
		if (!el || !hint) return;
		function refresh(){
			var trimmed = (el.value || '').trim();
			var text = cronToHuman(el.value);
			if (!trimmed){ hint.textContent = '（留空 = 关闭）'; hint.style.color = '#888'; hint.style.fontWeight = 'normal'; }
			else if (text.indexOf('⚠') === 0){ hint.textContent = text; hint.style.color = '#c0392b'; hint.style.fontWeight = 'bold'; }
			else { hint.textContent = '→ ' + text; hint.style.color = '#1a7f37'; hint.style.fontWeight = 'bold'; }
		}
		el.addEventListener('input', refresh);
		el.addEventListener('change', refresh);
		refresh();
	}

	// ---------- 重新拉取 /usr/sbin/wuxuroute get，刷新所有 input + 状态框 ----------
	// 入口：页面加载、apply 成功后。
	function reloadAll(){
		jsonCall(L.url('admin/network/wuxuroute/get'), '', function(err, data){
			if (err || !data) return;
			if (data.wan_mac)    setVal('wan_mac',  data.wan_mac);
			if (data.lan_mac)    setVal('lan_mac',  data.lan_mac);
			if (data.hostname)   setVal('hostname', data.hostname);
			if (data.lan_ip)     setVal('lan_ip',   data.lan_ip);
			window.__qc_lan_ip   = data.lan_ip || '';
			var count = parseInt(data.wifi_count || '0', 10);
			for (var i=0; i<count; i++){
				var field = data['wifi_' + i + '_field'];
				if (!field) continue;
				var mac = data['wifi_' + i + '_mac'];
				if (mac) setVal(field, mac);
			}
		});
		refreshStatus();
	}

	window.addEventListener('DOMContentLoaded', function(){
		// 回填当前值
		reloadAll();
		// 定时同步
		syncScheduleUI();
		// cron 实时翻译（仿 GitHub Actions 工作流；2026-08-27 实装）
		updateCronHint();
	});

	// 随机按钮（动态生成的 WiFi 行 + 固定字段）
	document.addEventListener('click', function(e){
		var t = e.target;
		if (!t || t.tagName !== 'BUTTON') return;
		var v = t.getAttribute('data-qc-action');
		if (!v) return;
		if (v === 'random_mac') {
			randomInto(t.getAttribute('data-qc-target'));
		} else if (v === 'random_hostname') {
			randomInto('hostname');
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
			var m = wfs[i].name.match(/\.wifi_mac_(.+)$/);
			if (m) randomInto('wifi_mac_' + m[1]);
		}
		status('已随机生成所有字段，点「保存并应用」生效', true);
	});

	$('qc-apply') && $('qc-apply').addEventListener('click', function(){
		var oldIp = window.__qc_lan_ip || '';
		var newIp = (getVal('lan_ip') || '').trim();
		var ipChanged = (newIp && oldIp && newIp !== oldIp);
		function doApply(){
			jsonCall(L.url('admin/network/wuxuroute/apply'), buildBody(true), function(err, d){
				if (err){ showModal({title:'应用失败', kind:'error', bodyHtml:'网络错误，请重试。'}); return; }
				if (!d || !d.ok){
					showModal({title:'应用失败', kind:'error', bodyHtml: escapeHtml((d && d.err) ? d.err : '未知错误')});
					return;
				}
				var rows = [];
				if (getVal('wan_mac'))  rows.push('WAN MAC：' + escapeHtml(getVal('wan_mac')));
				if (getVal('lan_mac'))  rows.push('LAN MAC：' + escapeHtml(getVal('lan_mac')));
				if (newIp)              rows.push('LAN IP：' + escapeHtml(newIp) + (ipChanged ? '（已变更）' : ''));
				if (getVal('hostname')) rows.push('主机名：' + escapeHtml(getVal('hostname')));
				var wfs = wifiFields();
				for (var i=0;i<wfs.length;i++){ if (wfs[i].value) rows.push('WiFi MAC：' + escapeHtml(wfs[i].value)); }
				var body = '<p style=\'margin:0 0 8px\'>配置已成功应用。</p>';
				if (rows.length) body += '<ul style=\'margin:0;padding-left:18px\'>' + rows.map(function(r){return '<li>'+r+'</li>';}).join('') + '</ul>';
				if (ipChanged){
					var url = location.protocol + '//' + newIp + (location.port ? ':' + location.port : '') + '/';
					body += '<p style=\'margin:10px 0 0\'>管理地址已变更为 <b>' + escapeHtml(newIp) + '</b>，网络将短暂中断（通常 5-15 秒），随后自动跳转到新地址。</p>';
					showModal({title:'应用成功', kind:'ok', bodyHtml:body, okText:'前往新地址', cancelText:'留在本页',
						redirectUrl:url, countdown:12, onOk:function(){ setTimeout(function(){ window.location.href = url; }, 250); }});
				} else {
					body += '<p style=\'margin:10px 0 0\'>所有更改已生效。</p>';
					showModal({title:'应用成功', kind:'ok', bodyHtml:body, okText:'确定', onOk:function(){ reloadAll(); }});
					// 弹窗一出来就立刻从 uci 回填一次（后端 commit 已完成，读到的是新值）
					reloadAll();
				}
			});
		}
		if (ipChanged){
			var url = location.protocol + '//' + newIp + (location.port ? ':' + location.port : '') + '/';
			var cbody = '<p style=\'margin:0 0 8px\'>你正在将路由器管理地址从 <b>' + escapeHtml(oldIp) + '</b> 变更为 <b>' + escapeHtml(newIp) + '</b>。</p>'
				+ '<p style=\'margin:0 0 8px;color:#a04000\'><b>⚠ 应用后管理口会立即断开 5-15 秒</b>，等后台重新拉起新 IP 后会自动跳转。</p>'
				+ '<p style=\'margin:0\'>新地址：<b>' + escapeHtml(url) + '</b>。是否继续？</p>';
			showModal({title:'确认修改管理地址', kind:'warn', bodyHtml:cbody, okText:'继续并应用', cancelText:'取消', onOk:doApply});
		} else {
			doApply();
		}
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

	// ---------- 当前生效状态刷新（供弹窗与状态框复用） ----------
	function escapeHtml(s){
		return String(s == null ? '' : s)
			.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
			.replace(new RegExp(String.fromCharCode(34),'g'),'&quot;').replace(/'/g,'&#39;');
	}
	function refreshStatus(){
		jsonCall(L.url('admin/network/wuxuroute/status'), '', function(err, d){
			if (err || !d) return;
			function row(k, v){ return '<tr><td style=\'padding:2px 8px;font-weight:bold\'>'+escapeHtml(k)+'</td><td style=\'padding:2px 8px\'>'+escapeHtml(v)+'</td></tr>'; }
			var html = '<table class=\'cbi-table\' style=\'border-collapse:collapse\'>';
			html += row('WAN', d.wan_mac || '-');
			html += row('LAN', d.lan_mac || '-');
			html += row('主机名', d.hostname || '-');
			html += row('LAN IP', d.lan_ip || '-');
			window.__qc_lan_ip = (d.lan_ip || '');
			var c = parseInt(d.wifi_count || '0', 10);
			for (var i=0;i<c;i++){
				var s = d['wifi_' + i + '_ssid'] || ('SSID#' + i);
				var cm = d['wifi_' + i + '_config_mac'] || '未设置';
				var em = d['wifi_' + i + '_effective_mac'] || '未知';
				html += row(s, '配置: ' + cm + ' / 实际: ' + em);
			}
			html += '</table>';
			var box = $('qc-status-box');
			if (box) box.innerHTML = html;
		});
	}

	// ---------- 结果弹窗（替代页面内日志） ----------
	function showModal(opts){
		opts = opts || {};
		var ov = $('qc-modal'); if (!ov) return;
		var title = $('qc-modal-title'), body = $('qc-modal-body'), foot = $('qc-modal-foot');
		var prog = $('qc-modal-progress'), progBar = $('qc-modal-progress-bar');
		title.textContent = opts.title || '';
		title.style.background = (opts.kind === 'error') ? '#c0392b' : (opts.kind === 'warn' ? '#e67e22' : '#2e8b57');
		body.innerHTML = opts.bodyHtml || '';
		foot.innerHTML = '';
		if (prog) prog.style.display = 'none';
		if (progBar) progBar.style.width = '0%';
		var autoTimer = null, probeTimer = null, jumped = false;
		function clearTimers(){
			if (autoTimer){ clearTimeout(autoTimer); autoTimer = null; }
			if (probeTimer){ clearTimeout(probeTimer); probeTimer = null; }
		}
		function addBtn(label, primary, fn){
			var b = document.createElement('button');
			b.type = 'button';
			b.className = 'btn ' + (primary ? 'cbi-button-apply' : 'cbi-button-reset');
			b.textContent = label;
			b.addEventListener('click', function(){
				clearTimers();
				if (fn) fn();
				closeModal();
			});
			foot.appendChild(b);
		}
		if (opts.cancelText) addBtn(opts.cancelText, false, opts.onCancel);
		if (opts.okText)     addBtn(opts.okText, true, opts.onOk);
		// 倒计时模式：自动跳转到新地址（改 LAN IP 场景）
		if (opts.countdown && opts.redirectUrl){
			var total = opts.countdown, remain = total;
			var pri = foot.querySelector('.cbi-button-apply');
			var base = opts.okText || '确定';
			if (prog) prog.style.display = 'block';
			// +5 秒按钮
			var moreBtn = document.createElement('button');
			moreBtn.type = 'button';
			moreBtn.className = 'btn cbi-button-reset';
			moreBtn.textContent = '+5 秒';
			moreBtn.addEventListener('click', function(){
				clearTimers();
				total += 5; remain += 5;
				if (progBar) progBar.style.width = ((total - remain) / total) * 100 + '%';
				tick();
			});
			foot.appendChild(moreBtn);
			// 归零时先 head 探活新地址，OK 直接跳；超时 2.5s / 1.5s 兜底
			function doRedirect(){
				if (jumped) return; jumped = true;
				clearTimers();
				var target = opts.redirectUrl;
				dbg('redirect', 'probing ' + target);
				try {
					var xhr = new XMLHttpRequest();
					xhr.open('GET', target, true);
					xhr.timeout = 2500;
					xhr.onload = function(){
						dbg('redirect', 'probe ok, jumping to ' + target);
						window.location.href = target;
					};
					xhr.onerror  = function(){ dbg('redirect', 'probe err'); };
					xhr.ontimeout = function(){ dbg('redirect', 'probe timeout'); };
					xhr.send();
					probeTimer = setTimeout(function(){
						dbg('redirect', 'force-jump fallback');
						window.location.href = target;
					}, 1500);
				} catch(e) {
					dbg('redirect', 'probe threw ' + e.toString());
					window.location.href = target;
				}
			}
			function tick(){
				if (pri) pri.textContent = base + ' (' + remain + 's)';
				if (progBar) progBar.style.width = ((total - remain) / total) * 100 + '%';
				if (remain <= 0){ doRedirect(); return; }
				remain--;
				autoTimer = setTimeout(tick, 1000);
			}
			tick();
		}
		ov.style.display = 'flex';
	}
	function closeModal(){ var ov = $('qc-modal'); if (ov) ov.style.display = 'none'; }
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
s.description = [[
<div id="qc-warning"><b>提示：</b>如已在 LuCI 自带「网络→无线→编辑→MAC 地址」里选择过「随机生成」（即写入了 <code>macaddr='random'</code>），
保存并应用时本工具会把它覆盖为固定 MAC。如需保留上游「每次重配/重启重新随机」的行为，请先在 LuCI 那里把它改回「驱动默认（留空）」再来本页面操作。</div>
<p style="margin:0">每个 SSID 可单独设置 MAC 地址。无论你有几个 WiFi 信号，都会自动读取并列出。</p>
]]

if #wifi_lines > 0 then
	for _, line in ipairs(wifi_lines) do
		local idx, sec, dev, ssid, mac, ifn = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		-- UCI 段名规则限制在 [A-Za-z0-9_]，所有可枚举的 wifi-iface 段都符合。
		-- 字段名以 sec 为 key，配合 controller 的 collect_wifi_args，把 sec 直接透传给
		-- 后端 `uci set wireless.${sec}.macaddr`，兼容 OpenWrt 默认为命名段
		-- （如 `default_radio0`）的场景。
		local sec_safe = sec and sec:gsub("[^%w_]", "_") or ("idx" .. (idx or "?"))
		local field = "wifi_mac_" .. sec_safe
		-- 展示用前缀：便于用户在 label 看到这是第几个 SSID
		local label = ((ssid and #ssid > 0) and ssid or (sec or ("SSID#" .. (idx or "?"))))
			.. " #" .. (idx or "?")
			.. " @ " .. ((dev and #dev > 0) and dev or "?")
		local cur = (mac and #mac > 0) and mac or translate("（未设置，使用硬件地址）")
		local opt = s:option(Value, field,
			label,
			translate("当前 MAC: ") .. cur .. " / sec=" .. (sec or "?"))
		opt.datatype = "macaddr"
		opt.rmempty = true
		opt.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="]] .. field .. [[">]] .. translate("随机 MAC 地址") .. [[</button>]]
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

-- cron 实时翻译（仿 GitHub Actions 工作流，2026-08-27）：
-- description 含 hint 容器；JS 监听 .schedule 的 input 事件，把 5 段 cron
-- 表达式实时翻译成"在 HH:MM 运行，每周X、Y，每月Z号"形式。非法 5 段格式
-- 用红字标。空值保持灰字提示"留空 = 关闭"。
schedule = s:option(Value, "schedule", translate("cron 表达式"),
	[[<span id="qc-cron-hint" style="margin-left:.5em;color:#888;font-style:italic">]] .. translate("（5 段：分 时 日 月 周，输入实时翻译）") .. [[</span>]])
schedule.optional = true
schedule.rmempty = true

return m