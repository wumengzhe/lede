-- LuCI CBI model for wuxuroute
-- UCI config: wuxuroute @config[0]
-- 字段: wan_mac / lan_mac / lan_ip / hostname
-- 动态: wifi_mac_<idx>  (每个 WiFi SSID 一个，数量不固定)
-- 选项: auto_wan_mac / auto_lan_mac / auto_wifi / auto_hostname / auto_lan_ip / schedule

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
<script type="text/javascript">
(function(){
	function $(id){return document.getElementById(id);}
	function status(msg, ok){
		var s = $('qc-status');
		if (!s) return;
		s.textContent = msg || '';
		s.style.color = ok ? '#0a0' : '#c00';
	}
	function setVal(name, v){
		var inputs = document.querySelectorAll('input[name="' + name + '"]');
		if (inputs && inputs[0]) inputs[0].value = v;
	}
	function getVal(name){
		var inputs = document.querySelectorAll('input[name="' + name + '"]');
		return (inputs && inputs[0]) ? inputs[0].value : '';
	}
	function checkbox(name){
		var inputs = document.querySelectorAll('input[type="checkbox"][name="' + name + '"]');
		return (inputs && inputs[0]) ? inputs[0].checked : false;
	}
	function jsonCall(url, body, cb){
		var xhr = new XMLHttpRequest();
		xhr.open('POST', url, true);
		xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
		xhr.onreadystatechange = function(){
			if (xhr.readyState !== 4) return;
			try { cb(null, JSON.parse(xhr.responseText)); }
			catch (e) { cb(e); }
		};
		xhr.send(body || '');
	}
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
		if (target === 'hostname') {
			jsonCall(L.url('admin/network/wuxuroute/gen_hostname'), '', function(err, d){
				if (!err && d && d.hostname) setVal('cbid.wuxuroute.config.0.hostname', d.hostname);
			});
		} else {
			reqMac(function(err, d){
				if (!err && d && d.mac) setVal('cbid.wuxuroute.config.0.' + target, d.mac);
			});
		}
	}
	function qcName(base){ return 'cbid.wuxuroute.config.0.' + base; }
	function wifiFields(){
		return document.querySelectorAll('input[name^="cbid.wuxuroute.config.0.wifi_mac_"]');
	}
	function buildBody(includeAuto){
		var body = 'wan_mac=' + encodeURIComponent(getVal(qcName('wan_mac'))) +
			'&lan_mac=' + encodeURIComponent(getVal(qcName('lan_mac'))) +
			'&hostname=' + encodeURIComponent(getVal(qcName('hostname'))) +
			'&lan_ip=' + encodeURIComponent(getVal(qcName('lan_ip')));
		var wfs = wifiFields();
		for (var i=0; i<wfs.length; i++){
			var m = wfs[i].name.match(/wifi_mac_(\d+)$/);
			if (m && wfs[i].value) body += '&wifi_mac_' + m[1] + '=' + encodeURIComponent(wfs[i].value);
		}
		if (includeAuto){
			body += '&auto_wan_mac=' + (checkbox(qcName('auto_wan_mac')) ? '1' : '');
			body += '&auto_lan_mac=' + (checkbox(qcName('auto_lan_mac')) ? '1' : '');
			body += '&auto_wifi=' + (checkbox(qcName('auto_wifi')) ? '1' : '');
			body += '&auto_hostname=' + (checkbox(qcName('auto_hostname')) ? '1' : '');
			body += '&auto_lan_ip=' + (checkbox(qcName('auto_lan_ip')) ? '1' : '');
			var sch = document.querySelector('select[name="cbid.wuxuroute.config.0.schedule"]');
			if (sch) body += '&schedule=' + encodeURIComponent(sch.value);
		}
		return body;
	}

	window.addEventListener('DOMContentLoaded', function(){
		// 回填当前值
		jsonCall(L.url('admin/network/wuxuroute/get'), '', function(err, data){
			if (err || !data) return;
			if (data.wan_mac)    setVal(qcName('wan_mac'), data.wan_mac);
			if (data.lan_mac)    setVal(qcName('lan_mac'), data.lan_mac);
			if (data.hostname)   setVal(qcName('hostname'), data.hostname);
			if (data.lan_ip)     setVal(qcName('lan_ip'), data.lan_ip);
			var count = parseInt(data.wifi_count || '0', 10);
			for (var i=0; i<count; i++){
				if (data['wifi_' + i + '_mac']) setVal(qcName('wifi_mac_' + i), data['wifi_' + i + '_mac']);
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
				setVal(qcName(target), d.mac);
				status('已生成 ' + d.mac, true);
			});
		} else if (v === 'random_hostname') {
			jsonCall(L.url('admin/network/wuxuroute/gen_hostname'), '', function(err, d){
				if (err || !d || !d.hostname) { status('生成失败', false); return; }
				setVal(qcName('hostname'), d.hostname);
				status('已生成 ' + d.hostname, true);
			});
		} else if (v === 'random_lan_ip') {
			var n = (Math.floor(Math.random() * 200) + 2);
			var ip = '192.168.' + n + '.1';
			setVal(qcName('lan_ip'), ip);
			status('已生成 ' + ip + '（请牢记新 IP！）', true);
		}
	});

	$('qc-random-all') && $('qc-random-all').addEventListener('click', function(){
		randomInto('wan_mac');
		randomInto('lan_mac');
		randomInto('hostname');
		var n = (Math.floor(Math.random() * 200) + 2);
		setVal(qcName('lan_ip'), '192.168.' + n + '.1');
		var wfs = wifiFields();
		for (var i=0; i<wfs.length; i++){
			var m = wfs[i].name.match(/wifi_mac_(\d+)$/);
			if (m) randomInto('wifi_mac_' + m[1]);
		}
		status('已随机生成所有字段，点“保存并应用”生效', true);
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

-- ===== 开机 / 定时自动更新 =====
s = m:section(TypedSection, "config", translate("重启自动更新"))
s.anonymous = true
s.addremove = false
s.description = translate("勾选后，每次路由器开机 / 重启时会自动重新生成下列项。配合下方“定时更新”可周期性自动更换。")

auto_wan_mac    = s:option(Flag, "auto_wan_mac",    translate("开机更新 WAN MAC"))
auto_lan_mac    = s:option(Flag, "auto_lan_mac",    translate("开机更新 LAN MAC"))
auto_wifi       = s:option(Flag, "auto_wifi",       translate("开机更新全部 WiFi SSID MAC"))
auto_hostname   = s:option(Flag, "auto_hostname",   translate("开机更新主机名"))
auto_lan_ip     = s:option(Flag, "auto_lan_ip",     translate("开机保留 LAN IP（不随机）"))
auto_lan_ip.default = "1"
auto_lan_ip.description = translate("LAN IP 默认不随机（避免忘记新 IP 进不了后台）。如要随机生成，取消勾选。")

schedule = s:option(ListValue, "schedule", translate("定时自动更新"),
	translate("除开机外，按周期自动重新生成“重启自动更新”中勾选的项。依赖系统 cron（多数固件已带）。"))
schedule:value("0", translate("关闭"))
schedule:value("1", translate("每天 04:00"))
schedule:value("2", translate("每周一 04:00"))

return m
