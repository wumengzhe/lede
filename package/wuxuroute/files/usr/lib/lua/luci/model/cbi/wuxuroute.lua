-- LuCI CBI model for wuxuroute
-- UCI config: wuxuroute @config[0]
-- 字段: wan_mac / lan_mac / wifi2g_mac / wifi5g_mac / lan_ip / hostname
--       auto_wan_mac / auto_lan_mac / auto_wifi2g_mac / auto_wifi5g_mac / auto_hostname / auto_lan_ip

m = Map("wuxuroute", translate("无序路由配置"),
	translate("一键配置 WAN/LAN/WiFi MAC 地址、LAN IP、主机名。可设置每次开机自动重置。"))

m.pageaction = false
m.submitbutton = false
m.resetbutton = false
m.chain = "cbi"

-- ===== 顶部工具栏：随机 / 应用 / 重启（纯 JS） =====
tb = m:section(TypedSection, "config", translate("快捷操作"))
tb.anonymous = true
tb.addremove = false
tb.description = [[
<div id="qc-toolbar" style="margin-bottom:1em">
  <button type="button" id="qc-random-all" class="btn cbi-button-apply">]] .. translate("一键随机全部") .. [[</button>
  <button type="button" id="qc-apply" class="btn cbi-button-apply">]] .. translate("保存并应用") .. [[</button>
  <button type="button" id="qc-reboot" class="btn cbi-button-reset">]] .. translate("保存并重启") .. [[</button>
  <span id="qc-status" style="margin-left:1em"></span>
</div>
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
	window.addEventListener('DOMContentLoaded', function(){
		jsonCall(L.url('admin/network/wuxuroute/get'), '', function(err, data){
			if (err || !data) return;
			if (data.wan_mac)    setVal('cbid.wuxuroute.config.0.wan_mac', data.wan_mac);
			if (data.lan_mac)    setVal('cbid.wuxuroute.config.0.lan_mac', data.lan_mac);
			if (data.wifi2g_mac) setVal('cbid.wuxuroute.config.0.wifi2g_mac', data.wifi2g_mac);
			if (data.wifi5g_mac) setVal('cbid.wuxuroute.config.0.wifi5g_mac', data.wifi5g_mac);
			if (data.hostname)   setVal('cbid.wuxuroute.config.0.hostname', data.hostname);
			if (data.lan_ip)     setVal('cbid.wuxuroute.config.0.lan_ip', data.lan_ip);
		});
	});
	document.addEventListener('click', function(e){
		var t = e.target;
		if (!t || t.tagName !== 'BUTTON') return;
		var v = t.getAttribute('data-qc-action');
		if (!v) return;
		if (v === 'random_mac') {
			var target = t.getAttribute('data-qc-target');
			jsonCall(L.url('admin/network/wuxuroute/gen_mac'), '', function(err, d){
				if (err || !d || !d.mac) { status('生成失败', false); return; }
				setVal('cbid.wuxuroute.config.0.' + target, d.mac);
				status('已生成 ' + d.mac, true);
			});
		} else if (v === 'random_hostname') {
			jsonCall(L.url('admin/network/wuxuroute/gen_hostname'), '', function(err, d){
				if (err || !d || !d.hostname) { status('生成失败', false); return; }
				setVal('cbid.wuxuroute.config.0.hostname', d.hostname);
				status('已生成 ' + d.hostname, true);
			});
		} else if (v === 'random_lan_ip') {
			var n = (Math.floor(Math.random() * 200) + 2);
			var ip = '192.168.' + n + '.1';
			setVal('cbid.wuxuroute.config.0.lan_ip', ip);
			status('已生成 ' + ip + '（请牢记新 IP！）', true);
		}
	});
	$('qc-random-all') && $('qc-random-all').addEventListener('click', function(){
		jsonCall(L.url('admin/network/wuxuroute/gen_hostname'), '', function(err, d1){
			jsonCall(L.url('admin/network/wuxuroute/gen_mac'), '', function(err, d2){
				jsonCall(L.url('admin/network/wuxuroute/gen_mac'), '', function(err, d3){
					jsonCall(L.url('admin/network/wuxuroute/gen_mac'), '', function(err, d4){
						jsonCall(L.url('admin/network/wuxuroute/gen_mac'), '', function(err, d5){
							if (d2 && d2.mac) setVal('cbid.wuxuroute.config.0.wan_mac', d2.mac);
							if (d3 && d3.mac) setVal('cbid.wuxuroute.config.0.lan_mac', d3.mac);
							if (d4 && d4.mac) setVal('cbid.wuxuroute.config.0.wifi2g_mac', d4.mac);
							if (d5 && d5.mac) setVal('cbid.wuxuroute.config.0.wifi5g_mac', d5.mac);
							if (d1 && d1.hostname) setVal('cbid.wuxuroute.config.0.hostname', d1.hostname);
							status('已随机生成所有字段，点"保存并应用"生效', true);
						});
					});
				});
			});
		});
	});
	$('qc-apply') && $('qc-apply').addEventListener('click', function(){
		var body = 'wan_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.wan_mac')) +
			'&lan_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.lan_mac')) +
			'&wifi2g_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.wifi2g_mac')) +
			'&wifi5g_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.wifi5g_mac')) +
			'&hostname=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.hostname')) +
			'&lan_ip=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.lan_ip')) +
			'&auto_wan_mac=' + (checkbox('cbid.wuxuroute.config.0.auto_wan_mac') ? '1' : '') +
			'&auto_lan_mac=' + (checkbox('cbid.wuxuroute.config.0.auto_lan_mac') ? '1' : '') +
			'&auto_wifi2g_mac=' + (checkbox('cbid.wuxuroute.config.0.auto_wifi2g_mac') ? '1' : '') +
			'&auto_wifi5g_mac=' + (checkbox('cbid.wuxuroute.config.0.auto_wifi5g_mac') ? '1' : '') +
			'&auto_hostname=' + (checkbox('cbid.wuxuroute.config.0.auto_hostname') ? '1' : '') +
			'&auto_lan_ip=' + (checkbox('cbid.wuxuroute.config.0.auto_lan_ip') ? '1' : '');
		jsonCall(L.url('admin/network/wuxuroute/apply'), body, function(err, d){
			if (err) { status('应用失败: ' + err, false); return; }
			status(d && d.log ? d.log : '应用成功', d && d.ok);
		});
	});
	$('qc-reboot') && $('qc-reboot').addEventListener('click', function(){
		if (!confirm('确定要写入配置并 3 秒后重启设备吗？')) return;
		var body = 'wan_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.wan_mac')) +
			'&lan_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.lan_mac')) +
			'&wifi2g_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.wifi2g_mac')) +
			'&wifi5g_mac=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.wifi5g_mac')) +
			'&hostname=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.hostname')) +
			'&lan_ip=' + encodeURIComponent(getVal('cbid.wuxuroute.config.0.lan_ip'));
		jsonCall(L.url('admin/network/wuxuroute/reboot'), body, function(err, d){
			status(d && d.log ? d.log : '正在重启...', d && d.ok);
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

-- ===== WiFi 设置 =====
s = m:section(TypedSection, "config", translate("WiFi 设置"))
s.anonymous = true
s.addremove = false

wifi2g_mac = s:option(Value, "wifi2g_mac", translate("2.4G WiFi MAC 地址"))
wifi2g_mac.datatype = "macaddr"
wifi2g_mac.rmempty = true
wifi2g_mac.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="wifi2g_mac">]] .. translate("随机 MAC 地址") .. [[</button>]]

wifi5g_mac = s:option(Value, "wifi5g_mac", translate("5G WiFi MAC 地址"))
wifi5g_mac.datatype = "macaddr"
wifi5g_mac.rmempty = true
wifi5g_mac.description = [[<button type="button" class="btn cbi-button-apply" data-qc-action="random_mac" data-qc-target="wifi5g_mac">]] .. translate("随机 MAC 地址") .. [[</button>]]

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
s = m:section(TypedSection, "config", translate("重启自动更新"))
s.anonymous = true
s.addremove = false
s.description = translate("勾选后，每次路由器开机 / 重启时会自动重新生成下列项。")

auto_wan_mac    = s:option(Flag, "auto_wan_mac",    translate("开机更新 WAN MAC"))
auto_lan_mac    = s:option(Flag, "auto_lan_mac",    translate("开机更新 LAN MAC"))
auto_wifi2g_mac = s:option(Flag, "auto_wifi2g_mac", translate("开机更新 2.4G WiFi MAC"))
auto_wifi5g_mac = s:option(Flag, "auto_wifi5g_mac", translate("开机更新 5G WiFi MAC"))
auto_hostname   = s:option(Flag, "auto_hostname",   translate("开机更新主机名"))
auto_lan_ip     = s:option(Flag, "auto_lan_ip",     translate("开机保留 LAN IP（不随机）"))
auto_lan_ip.default = "1"
auto_lan_ip.description = translate("LAN IP 默认不随机（避免忘记新 IP 进不了后台）。如要随机生成，取消勾选。")

return m
