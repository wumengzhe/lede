-- SPDX-License-Identifier: Apache-2.0
-- luci-app-pon: status + activate/deactivate actions

module("luci.controller.pon", package.seeall)

function index()
	entry({"admin", "status", "pon"}, template("pon/status"), _("PON"), 90)
	entry({"admin", "network", "pon"}, cbi("pon"), _("PON"), 90).dependent = false
	entry({"admin", "network", "pon", "activate"}, post("action_activate"), nil)
	entry({"admin", "network", "pon", "deactivate"}, post("action_deactivate"), nil)
end

function ponctl(args)
	local f = io.popen("ponctl " .. args .. " 2>/dev/null")
	if not f then
		return nil
	end
	local out = f:read("*a")
	f:close()
	return out
end

function action_activate()
	ponctl("activate")
	luci.http.redirect(luci.dispatcher.build_url("admin/network/pon"))
end

function action_deactivate()
	ponctl("deactivate")
	luci.http.redirect(luci.dispatcher.build_url("admin/network/pon"))
end
