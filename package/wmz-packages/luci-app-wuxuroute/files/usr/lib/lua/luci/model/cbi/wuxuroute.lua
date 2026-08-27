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

-- 2026-08-27 cbi6：渲染时读取当前值用于 input 预填
local uci = require "luci.model.uci".cursor()
local function ucig(cfg, sec, opt, def)
	local v = uci:get(cfg, sec, opt)
	return v or def or ""
end
local function esc(s)
	s = s or ""
	s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
	return s
end
-- 当前生效值（仅用于预填，缺省即空 = 未设置）
local cur_wan_mac = ucig("network", "wan", "macaddr", "")
local cur_lan_mac = ucig("network", "lan", "macaddr", "")
if cur_lan_mac == "" then cur_lan_mac = ucig("network", "@device[0]", "macaddr", "") end
local cur_lan_ip  = ucig("network", "lan", "ipaddr", "")
local cur_host    = ucig("system", "@system[0]", "hostname", "")

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
  <button type="button" id="qc-random-all" class="btn cbi-button-apply">]] .. translate("一键随机MAC") .. [[</button>
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
		// 2026-08-27 反馈：成功态右侧绿色「已生成 X」字样用户觉得碍眼，静默掉；错误/失败仍走红色提示。
		if (ok) return;
		var s = $('qc-status');
		if (!s) return;
		s.textContent = msg || '';
		s.style.color = '#c00';
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
		// cbid.wuxuroute.<sid>.wifi_mac_<sec_safe> 以 sec_safe 结尾，并非以 .wifi_mac_ 结尾，
		// 旧实现用 qcAll('.wifi_mac_','cbid.wuxuroute.') 取"以 .wifi_mac_ 结尾"的 input 永远匹配不到，
		// 导致「一键随机MAC」与 buildBody 的 WiFi 段永远为空、WiFi MAC 改了也不生效。
		// 改：前缀 cbid.wuxuroute. + 名称包含 .wifi_mac_。
		var all = qcAll('', 'cbid.wuxuroute.');
		var out = [];
		for (var i=0;i<all.length;i++){
			if (all[i].name && all[i].name.indexOf('.wifi_mac_') >= 0) out.push(all[i]);
		}
		return out;
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
	function isHostnameStr(s){ return /^PC-[A-Fa-f0-9]{6}$/.test(String(s == null ? '' : s)); }
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

	// ---------- cron 下次运行时间计算（2026-08-27 cbi3 实装） ----------
	// 5 段：分 时 日 月 周。每次输入更新 #qc-cron-hint：算出【下一次】具体运行时刻，
	//   空           → 灰色  「留空 = 关闭」
	//   合法 5 段     → 绿色  「下次运行：X 月 Y 日 HH:MM（约 N 小时后）」
	//   非法（非 5 段）→ 红色  「⚠ 需要 5 段（分 时 日 月 周），当前 N 段」
	// ---------- cron 下次运行时间计算 ----------
	// 5 段：分 时 日 月 周。算出【下一次】具体运行时刻并显示给用户。
	function cronNextRun(c){
		var p = c.split(/\s+/);
		if (p.length !== 5) return null;
		function parseField(spec, min, max){
			var set = {};
			if (spec === '*'){ for (var i=min;i<=max;i++) set[i]=true; return set; }
			var parts = spec.split(',');
			for (var k=0;k<parts.length;k++){
				var part = parts[k], step = 1, base = part;
				var sm = part.match(/^(.+)\/(\d+)$/);
				if (sm){ base = sm[1]; step = parseInt(sm[2],10); if (!(step>=1)) step=1; }
				var rmin=min, rmax=max;
				if (base !== '*'){
					var dm = base.match(/^(\d+)-(\d+)$/);
					if (dm){ rmin=parseInt(dm[1],10); rmax=parseInt(dm[2],10); }
					else { rmin=rmax=parseInt(base,10); }
				}
				for (var v=rmin; v<=rmax; v+=step){ if (v>=min && v<=max) set[v]=true; }
			}
			return set;
		}
		var mins = parseField(p[0],0,59);
		var hrs  = parseField(p[1],0,23);
		var doms = parseField(p[2],1,31);
		var mons = parseField(p[3],1,12);
		var dows = parseField(p[4],0,7);
		if (!Object.keys(mins).length || !Object.keys(hrs).length || !Object.keys(mons).length) return null;
		var domStar = (p[2]==='*');
		var dowStar = (p[4]==='*');
		function dayOk(date){
			var mo=date.getMonth()+1, d=date.getDate(), dw=date.getDay();
			if (!mons[mo]) return false;
			var domOk = domStar ? true : !!doms[d];
			var dowOk = dowStar ? true : (!!dows[dw] || (dw===0 && !!dows[7]));
			if (domStar || dowStar) return domOk && dowOk;
			return domOk || dowOk;
		}
		var now = new Date();
		var cur = new Date(now.getTime());
		cur.setSeconds(0,0); cur.setMinutes(cur.getMinutes()+1);
		var limit = new Date(now.getTime() + 2922*24*3600*1000); // 约 8 年：覆盖闰年 2/29 等稀疏 cron
		while (cur <= limit){
			if (dayOk(cur) && hrs[cur.getHours()] && mins[cur.getMinutes()]) return cur;
			cur.setMinutes(cur.getMinutes()+1);
		}
		return null;
	}
	function cronToHuman(c){
		var t = (c == null ? '' : String(c));
		t = t.trim();
		if (!t) return '';
		var p = t.split(/\s+/);
		if (p.length !== 5) return '⚠ 需要 5 段（分 时 日 月 周），当前 ' + p.length + ' 段';
		var next = cronNextRun(t);
		if (!next) return '⚠ 未来 8 年内无匹配时间（cron 可能过于特殊，如仅闰年 2/29）';
		var pad = function(n){ return (n<10?'0':'')+n; };
		var now = new Date();
		var diffMin = Math.round((next.getTime()-now.getTime())/60000);
		var when;
		if (diffMin < 1) when = '即将运行';
		else if (diffMin < 60) when = '约 ' + diffMin + ' 分钟后';
		else if (diffMin < 1440) when = '约 ' + Math.round(diffMin/60) + ' 小时后';
		else when = '约 ' + Math.round(diffMin/1440) + ' 天后';
		return '下次运行：' + (next.getMonth()+1) + ' 月 ' + pad(next.getDate()) + ' 日 '
			+ pad(next.getHours()) + ':' + pad(next.getMinutes()) + '（' + when + '）';
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
			// 2026-08-27 cbi6：回填后重新快照初始值，作为「变更摘要」基准
			snapshotInitial();
		});
		refreshStatus();
	}

	// ---------- 2026-08-27 cbi6：预填快照 / 内联校验 / 变更摘要 ----------
	function snapshotInitial(){
		var init = {
			wan_mac: getVal('wan_mac'),
			lan_mac: getVal('lan_mac'),
			lan_ip:  getVal('lan_ip'),
			hostname: getVal('hostname'),
			wifi: {}
		};
		var wfs = wifiFields();
		for (var i=0;i<wfs.length;i++){
			var m = wfs[i].name.match(/\.wifi_mac_(.+)$/);
			if (m){ var sec = m[1]; init.wifi[sec] = wfs[i].value; }
		}
		window.__qc_initial = init;
		dbg('snap', 'initial wan=' + init.wan_mac + ' wifi=' + (init.wifi ? Object.keys(init.wifi).length : 0));
	}
	function qcErrId(el){ return 'qc-err-' + el.name.replace(/[^a-zA-Z0-9]/g, '_'); }
	function validateOne(el){
		if (!el) return;
		var v = (el.value || '').trim();
		var msg = '';
		if (v !== ''){
			if (el.getAttribute('data-qc-mac') === '1'){ if (!isMacStr(v)) msg = 'MAC 应为 AA:BB:CC:DD:EE:FF'; }
			else if (el.getAttribute('data-qc-host') === '1'){ if (!isHostnameStr(v)) msg = '主机名应为 PC-XXXXXX'; }
		}
		if (msg){ el.style.borderColor = '#c0392b'; el.style.boxShadow = '0 0 0 1px #c0392b'; }
		else { el.style.borderColor = ''; el.style.boxShadow = ''; }
		var tip = document.getElementById(qcErrId(el));
		if (tip) tip.textContent = msg;
	}
	function bindInlineValidation(){
		var els = qcAll('', 'cbid.wuxuroute.');
		for (var i=0;i<els.length;i++){
			var el = els[i];
			if (!el.getAttribute) continue;
			if (el.getAttribute('data-qc-mac') === '1' || el.getAttribute('data-qc-host') === '1'){
				(function(node){ node.addEventListener('input', function(){ validateOne(node); }); })(el);
				validateOne(el);
			}
		}
	}
	function hasInvalidInput(){
		var els = qcAll('', 'cbid.wuxuroute.');
		for (var i=0;i<els.length;i++){
			var el = els[i];
			if (!el.getAttribute) continue;
			var v = (el.value || '').trim();
			if (v === '') continue;
			if (el.getAttribute('data-qc-mac') === '1' && !isMacStr(v)) return true;
			if (el.getAttribute('data-qc-host') === '1' && !isHostnameStr(v)) return true;
		}
		return false;
	}
	function diffRow(label, oldV, newV){
		if (!oldV && !newV) return null;
		if (oldV === newV) return '<li>' + escapeHtml(label) + '：<span style="color:#888">（未改动）</span></li>';
		return '<li>' + escapeHtml(label) + '：<b>' + escapeHtml(oldV || '（空）') + '</b> &rarr; <b>' + escapeHtml(newV || '（空）') + '</b></li>';
	}
	function buildChangeSummary(){
		var init = window.__qc_initial || {};
		var rows = [];
		var r;
		r = diffRow('WAN MAC', init.wan_mac, getVal('wan_mac')); if (r) rows.push(r);
		r = diffRow('LAN MAC', init.lan_mac, getVal('lan_mac')); if (r) rows.push(r);
		var oldIp = (init.lan_ip || '').trim(), newIp = (getVal('lan_ip')||'').trim();
		r = diffRow('LAN IP', oldIp, newIp); if (r) rows.push(r);
		r = diffRow('主机名', init.hostname, getVal('hostname')); if (r) rows.push(r);
		var wfs = wifiFields();
		for (var i=0;i<wfs.length;i++){
			var m = wfs[i].name.match(/\.wifi_mac_(.+)$/);
			if (!m) continue;
			var sec = m[1];
			var cur = wfs[i].value || '';
			var oldM = (init.wifi && init.wifi[sec]) || '';
			if (!cur && !oldM) continue;
			if (cur === oldM){ rows.push('<li>WiFi (' + escapeHtml(sec) + ') MAC：<span style="color:#888">（未改动）</span></li>'); }
			else { rows.push('<li>WiFi (' + escapeHtml(sec) + ') MAC：<b>' + escapeHtml(oldM||'（空）') + '</b> &rarr; <b>' + escapeHtml(cur||'（空）') + '</b></li>'); }
		}
		return { rows: rows, ipChanged: !!(oldIp && newIp && oldIp !== newIp), oldIp: oldIp, newIp: newIp };
	}

	window.addEventListener('DOMContentLoaded', function(){
		// 回填当前值 + 快照初始值 + 绑定内联校验
		reloadAll();
		snapshotInitial();
		bindInlineValidation();
		// 定时同步
		syncScheduleUI();
		loadWanList();
		// cron 下次运行时间（2026-08-27 cbi3 实装）
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
		// 2026-08-27 反馈：本按钮只随机化各 MAC（WAN/LAN/WiFi），不再含 IP（IP 变更会让
		// 客户端 DHCP 续约漂移，PC 卡在旧网关进不来新管理口）。主机名用其右侧「随机主机名」按钮。
		randomInto('wan_mac');
		randomInto('lan_mac');
		var wfs = wifiFields();
		for (var i=0; i<wfs.length; i++){
			var m = wfs[i].name.match(/\.wifi_mac_(.+)$/);
			if (m) randomInto('wifi_mac_' + m[1]);
		}
	});

	$('qc-apply') && $('qc-apply').addEventListener('click', function(){
		// 2026-08-27 cbi6：先内联校验格式，再弹「确认变更」摘要（old→new），IP 变更附客户端自救提示
		if (hasInvalidInput()){
			showModal({title:'输入有误', kind:'error', bodyHtml:'有 MAC / 主机名格式不正确（已红框标出），请先修正后再应用。'});
			return;
		}
		var sum = buildChangeSummary();
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
				if (sum.newIp)          rows.push('LAN IP：' + escapeHtml(sum.newIp) + (sum.ipChanged ? '（已变更）' : ''));
				if (getVal('hostname')) rows.push('主机名：' + escapeHtml(getVal('hostname')));
				var wfs = wifiFields();
				for (var i=0;i<wfs.length;i++){ if (wfs[i].value) rows.push('WiFi MAC：' + escapeHtml(wfs[i].value)); }
				var body = '<p style=\'margin:0 0 8px\'>配置已成功应用。</p>';
				if (rows.length) body += '<ul style=\'margin:0;padding-left:18px\'>' + rows.map(function(r){return '<li>'+r+'</li>';}).join('') + '</ul>';
				if (sum.ipChanged){
					var url = location.protocol + '//' + sum.newIp + (location.port ? ':' + location.port : '') + '/';
					body += '<p style=\'margin:10px 0 0\'>管理地址已变更为 <b>' + escapeHtml(sum.newIp) + '</b>，网络将短暂中断（通常 5-15 秒），随后自动跳转到新地址。</p>';
					showModal({title:'应用成功', kind:'ok', bodyHtml:body, okText:'前往新地址', cancelText:'留在本页',
						redirectUrl:url, countdown:12, onOk:function(){ setTimeout(function(){ window.location.href = url; }, 250); }});
				} else {
					body += '<p style=\'margin:10px 0 0\'>所有更改已生效。</p>';
					showModal({title:'应用成功', kind:'ok', bodyHtml:body, okText:'确定', onOk:function(){ reloadAll(); }});
					reloadAll();
				}
			});
		}
		if (sum.rows.length === 0){
			// 无字段变更：仍提交一次以保存开机/定时开关等
			doApply();
			return;
		}
		var body = '<p style=\'margin:0 0 8px\'>即将应用以下变更：</p><ul style=\'margin:0;padding-left:18px\'>' + sum.rows.join('') + '</ul>';
		if (sum.ipChanged){
			var url = location.protocol + '//' + sum.newIp + (location.port ? ':' + location.port : '') + '/';
			var sameSubnetHint = sum.newIp.replace(/\.\d+$/, '');
			var tmpStatic = sameSubnetHint + '.177';
			body += '<div style=\'margin:8px 0 0;background:#fff7e0;border:1px solid #f0d56a;padding:8px 12px;border-radius:4px;color:#5a4500\'><b>⚠ 管理地址将从 <code>' + escapeHtml(sum.oldIp) + '</code> 变更为 <code>' + escapeHtml(sum.newIp) + '</code></b>，客户端按以下顺序自救：'
				+ '<ol style=\'margin:6px 0 0;padding-left:20px;line-height:1.5\'>'
				+ '<li>Windows <code>ipconfig /release &amp;&amp; ipconfig /renew</code>；Linux <code>dhclient -r &amp;&amp; dhclient</code></li>'
				+ '<li>仍不通：换浏览器窗口或清缓存</li>'
				+ '<li>彻底不通：本机临时改静态 IP <code>' + escapeHtml(tmpStatic) + '</code>/24，网关 ' + escapeHtml(sum.newIp) + '</li>'
				+ '</ol></div>';
		}
		showModal({title:'确认变更', kind:'warn', bodyHtml:body, okText:'确认并应用', cancelText:'取消', onOk:doApply});
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

    $('qc-reip-btn') && $('qc-reip-btn').addEventListener('click', function(){
        var sel = $('qc-wan-iface');
        var iface = sel ? sel.value : '';
        if (!iface){
            showModal({title:'请选择 WAN 接口', kind:'error', bodyHtml:'请先在下拉框选择一个 WAN 接口。', okText:'确定'});
            return;
        }
        var rand = $('qc-reip-randmac') ? $('qc-reip-randmac').checked : false;
        var body = '<p style="margin:0 0 8px">即将对 WAN 接口 <b>'+escapeHtml(iface)+'</b> 执行重拨以更换公网 IP'+(rand?'（同时随机其 MAC）':'')+'。</p>'
            + '<div style="background:#fff7e0;border:1px solid #f0d56a;padding:8px 12px;border-radius:4px;color:#5a4500"><b>⚠ 重拨期间外网会短暂中断（通常 5–30 秒）</b>，所有联网设备将暂时断网。确定要继续吗？</div>';
        showModal({title:'确认重拨 WAN', kind:'warn', bodyHtml:body, okText:'确认重拨', cancelText:'取消',
            onOk:function(){
                var b = 'iface=' + encodeURIComponent(iface) + '&random_mac=' + (rand ? '1' : '');
                var st = $('qc-reip-status');
                if (st){ st.textContent = '重拨中...'; st.style.color = '#888'; }
                jsonCall(L.url('admin/network/wuxuroute/renew'), b, function(err, d){
                    if (st) st.textContent = '';
                    if (err){ showModal({title:'重拨失败', kind:'error', bodyHtml:'网络错误，请重试。'}); return; }
                    if (!d || !d.ok){ showModal({title:'重拨失败', kind:'error', bodyHtml: escapeHtml((d&&d.err)?d.err:'未知错误')}); return; }
                    showModal({title:'已发起重拨', kind:'ok', bodyHtml:'<p>正在重拨 <b>'+escapeHtml(iface)+'</b>，外网会短暂中断（5–30 秒）。完成后下方会刷新显示新的出口 IP。</p>', okText:'好的',
                        onOk:function(){ setTimeout(loadWanList, 12000); }});
                    setTimeout(loadWanList, 12000);
                });
            }
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
    function loadWanList(){
        jsonCall(L.url('admin/network/wuxuroute/list_wan'), '', function(err, d){
            if (err || !d) return;
            var sel = $('qc-wan-iface'); if (!sel) return;
            var list = (d.wan && d.wan.length) ? d.wan : [];
            sel.innerHTML = '';
            if (list.length === 0){
                var o0 = document.createElement('option'); o0.value=''; o0.textContent='（无可用 WAN 接口）'; sel.appendChild(o0);
            }
            var info = [];
            for (var i=0;i<list.length;i++){
                var w = list[i];
                var o = document.createElement('option'); o.value = w.name; o.textContent = w.name + (w.proto ? ' (' + w.proto + ')' : ''); sel.appendChild(o);
                info.push('<div>' + escapeHtml(w.name) + '：MAC ' + escapeHtml(w.mac || '-') + ' / 出口IP ' + escapeHtml(w.ip || '-') + '</div>');
            }
            var box = $('qc-reip-list'); if (box) box.innerHTML = info.join('');
        });
    }


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

-- 解耦：编辑字段不再绑定 UCI，避免"未保存却随其它页面保存而落盘"（bug #4）。
-- 改成纯 HTML input，name 仍按 cbid.wuxuroute.config.<opt> 约定，JS 的 getVal/setVal/buildBody 照常工作。
wan_mac = s:option(DummyValue, "_wan_mac", translate("WAN 口 MAC 地址"))
wan_mac.description = translate("当前 WAN MAC（也可手动输入新值）。")
	.. [[<br><input type="text" name="cbid.wuxuroute.config.wan_mac" value="]] .. esc(cur_wan_mac) .. [[" size="20" style="width:18em;margin-right:.4em" data-qc-mac="1">]]
	.. [[<span class="qc-err" id="qc-err-cbid_wuxuroute_config_wan_mac" style="color:#c0392b;font-size:12px;margin-left:.4em"></span>]]
	.. [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="wan_mac">]] .. translate("随机 MAC 地址") .. [[</button>]]

-- ===== LAN 设置 =====
s = m:section(TypedSection, "config", translate("LAN 口设置"))
s.anonymous = true
s.addremove = false

lan_ip = s:option(DummyValue, "_lan_ip", translate("LAN IP 地址"))
lan_ip.description = translate("路由 LAN 侧（管理后台）网关 IP。修改后管理地址会变，请牢记新 IP。")
	.. translate("本工具仅管理此主 LAN IP；访客 / 其他独立网段（如 IoT 子网）的网关 IP 不在管理范围，保持原样即可。")
	.. [[<br><input type="text" name="cbid.wuxuroute.config.lan_ip" value="]] .. esc(cur_lan_ip) .. [[" size="16" style="width:14em;margin-right:.4em">]]
	.. [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_lan_ip">]] .. translate("随机 IP 地址") .. [[</button>]]

lan_mac = s:option(DummyValue, "_lan_mac", translate("LAN 口 MAC 地址"))
lan_mac.description = [[<input type="text" name="cbid.wuxuroute.config.lan_mac" value="]] .. esc(cur_lan_mac) .. [[" size="20" style="width:18em;margin-right:.4em" data-qc-mac="1">]]
	.. [[<span class="qc-err" id="qc-err-cbid_wuxuroute_config_lan_mac" style="color:#c0392b;font-size:12px;margin-left:.4em"></span>]]
	.. [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="lan_mac">]] .. translate("随机 MAC 地址") .. [[</button>]]

-- ===== 换出口 IP / 重拨 WAN =====
s = m:section(TypedSection, "config", translate("换出口 IP / 重拨 WAN"))
s.anonymous = true
s.addremove = false
s.description = [[
<div id="qc-reip" style="margin:.4em 0">
  <p style="margin:0 0 .6em">重拨指定 WAN 接口（或同时随机其 MAC）以更换公网 IP，用于绕过基于 IP 的封禁。注意：重拨会<b>短暂断开外网</b>（通常 5–30 秒），请确认后再操作。</p>
  <div style="display:flex;flex-wrap:wrap;align-items:center;gap:.6em">
    <label>WAN 接口：
      <select id="qc-wan-iface"><option value="">加载中...</option></select>
    </label>
    <label><input type="checkbox" id="qc-reip-randmac"> 同时随机该 WAN 的 MAC（强制换新 IP）</label>
    <button type="button" id="qc-reip-btn" class="btn cbi-button-apply">换出口 IP（重拨）</button>
    <span id="qc-reip-status" style="margin-left:.4em"></span>
  </div>
  <div id="qc-reip-list" style="margin-top:.6em;color:#666;font-size:12px"></div>
</div>
]]


-- ===== WiFi 设置（多 SSID 动态生成，按 radio 分组折叠）=====
s = m:section(TypedSection, "config", translate("WiFi 设置（多 SSID）"))
s.anonymous = true
s.addremove = false
s.description = [[
<div id="qc-warning"><b>提示：</b>如已在 LuCI 自带「网络→无线→编辑→MAC 地址」里选择过「随机生成」（即写入了 <code>macaddr='random'</code>），
保存并应用时本工具会把它覆盖为固定 MAC。如需保留上游「每次重配/重启重新随机」的行为，请先在 LuCI 那里把它改回「驱动默认（留空）」再来本页面操作。</div>
<p style="margin:0">每个 SSID 可单独设置 MAC。按射频（radio）分组，点击各组标题可折叠/展开。无论几个信号都会自动读取列出。</p>
]]

if #wifi_lines > 0 then
	-- 按设备（radio0/radio1/...）分组，多 SSID 时便于折叠
	local groups = {}
	local order = {}
	local seen = {}
	for _, line in ipairs(wifi_lines) do
		local idx, sec, dev, ssid, mac, ifn = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		local sec_safe = sec and sec:gsub("[^%w_]", "_") or ("idx" .. (idx or "?"))
		local field = "wifi_mac_" .. sec_safe
		local label = ((ssid and #ssid > 0) and ssid or (sec or ("SSID#" .. (idx or "?"))))
			.. " #" .. (idx or "?")
			.. " @ " .. ((dev and #dev > 0) and dev or "?")
		local cur = (mac and #mac > 0) and mac or translate("（未设置，使用硬件地址）")
		local macv = (mac and #mac > 0 and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$")) and mac or ""
		local g = (dev and #dev > 0) and dev or "?"
		if not seen[g] then seen[g] = true; table.insert(order, g) end
		if not groups[g] then groups[g] = {} end
		table.insert(groups[g], { label = label, field = field, cur = cur, macv = macv })
	end
	local html = {}
	for _, g in ipairs(order) do
		local items = groups[g] or {}
		table.insert(html, '<details open class="qc-wifi-group" style="margin:.4em 0;border:1px solid rgba(127,127,127,.25);border-radius:6px">')
		table.insert(html, '<summary style="cursor:pointer;padding:.5em .7em;font-weight:bold">' .. esc(g) .. '（' .. #items .. ' 个 SSID）</summary>')
		table.insert(html, '<div style="padding:.3em .7em .6em">')
		for _, it in ipairs(items) do
			table.insert(html, '<div style="display:flex;flex-wrap:wrap;align-items:center;gap:.4em;margin:.4em 0">')
			table.insert(html, '<span style="min-width:15em;font-weight:bold">' .. esc(it.label) .. '</span>')
			table.insert(html, '<input type="text" name="cbid.wuxuroute.config.' .. it.field .. '" value="' .. esc(it.macv) .. '" size="20" style="width:18em" data-qc-mac="1">')
			table.insert(html, '<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="' .. it.field .. '">' .. translate("随机 MAC 地址") .. '</button>')
			table.insert(html, '<span style="color:#888;font-size:12px">当前：' .. esc(it.cur) .. '</span>')
			table.insert(html, '<span class="qc-err" id="qc-err-cbid_wuxuroute_config_' .. it.field .. '" style="color:#c0392b;font-size:12px;margin-left:.4em"></span>')
			table.insert(html, '</div>')
		end
		table.insert(html, '</div></details>')
	end
	s.description = s.description .. table.concat(html)
else
	s.description = translate("未检测到 WiFi 接口（wifi-iface）。如有 WiFi 请先在“网络 → 无线”中配置。")
end

-- ===== 主机名 =====
s = m:section(TypedSection, "config", translate("主机名"))
s.anonymous = true
s.addremove = false

hostname = s:option(DummyValue, "_hostname", translate("主机名"))
hostname.description = translate("设置路由器的设备名称（hostname）。")
	.. [[<br><input type="text" name="cbid.wuxuroute.config.hostname" value="]] .. esc(cur_host) .. [[" size="14" style="width:14em;margin-right:.4em" data-qc-host="1">]]
	.. [[<span class="qc-err" id="qc-err-cbid_wuxuroute_config_hostname" style="color:#c0392b;font-size:12px;margin-left:.4em"></span>]]
	.. [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_hostname">]] .. translate("随机 PC 主机名") .. [[</button>]]

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

-- cron 下次运行时间（2026-08-27 cbi3）：
-- description 含 hint 容器；JS 监听 .schedule 的 input 事件，把 5 段 cron
-- 表达式实时算成"下次运行：X 月 Y 日 HH:MM（约 N 小时后）"。非法 5 段格式
-- 用红字标。空值保持灰字提示"留空 = 关闭"。
schedule = s:option(Value, "schedule", translate("cron 表达式"),
	[[<span id="qc-cron-hint" style="margin-left:.5em;color:#888;font-style:italic">]] .. translate("（5 段：分 时 日 月 周，输入后实时显示下次运行时间）") .. [[</span>]]
	.. [[<div style="margin-top:.4em;color:#666;font-size:12px;line-height:1.5"><b>常用示例：</b>]]
	.. [[<code style="background:rgba(127,127,127,.18);padding:0 4px;border-radius:3px">0 4 * * *</code> 每天 04:00 · ]]
	.. [[<code style="background:rgba(127,127,127,.18);padding:0 4px;border-radius:3px">0 4 * * 1-5</code> 工作日 04:00 · ]]
	.. [[<code style="background:rgba(127,127,127,.18);padding:0 4px;border-radius:3px">0 4 * * 6,0</code> 周末 04:00 · ]]
	.. [[<code style="background:rgba(127,127,127,.18);padding:0 4px;border-radius:3px">*/15 * * * *</code> 每 15 分钟 · ]]
	.. [[<code style="background:rgba(127,127,127,.18);padding:0 4px;border-radius:3px">30 2 1 * *</code> 每月 1 号 02:30]]
	.. [[</div>]])
schedule.optional = true
schedule.rmempty = true

return m