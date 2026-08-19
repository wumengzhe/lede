include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-policyroute
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=wumengzhe
PKG_LICENSE:=MIT

LUCI_TITLE:=Policy Route (per-device / per-port egress, anti-association)
LUCI_DESCRIPTION:=Source-based policy routing. Route traffic by device MAC/IP/host \
	or destination port to any egress (multi-WAN, WireGuard, OpenVPN, passwall/openclash utun). \
	Exit-agnostic: no proxy required.
LUCI_DEPENDS:=+luci-base +nftables +ip-full +kmod-nft-core

PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_nftables \
	CONFIG_PACKAGE_ip-full

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  $(strip $(LUCI_DESCRIPTION))
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_BIN)  ./files/usr/sbin/policyroute              $(1)/usr/sbin/
	$(INSTALL_BIN)  ./files/etc/init.d/policyroute            $(1)/etc/init.d/
	$(INSTALL_DATA) ./files/etc/config/policyroute            $(1)/etc/config/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/policyroute.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/policyroute.lua  $(1)/usr/lib/lua/luci/model/cbi/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/policyroute enable 2>/dev/null || true
}
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/policyroute stop 2>/dev/null || true
endef

# Pure Lua/shell package: nothing to configure or compile.
define Build/Configure
endef

define Build/Compile
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
