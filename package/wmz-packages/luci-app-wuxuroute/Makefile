include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wuxuroute
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=wumengzhe
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=Wuxu Route Config (MAC / hostname randomizer)
LUCI_DESCRIPTION:=Randomize WAN/LAN/WiFi MAC addresses, LAN IP and hostname. Optional auto-randomize on boot.
LUCI_DEPENDS:=+luci-base +uci +coreutils
LUCI_PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=$(LUCI_PKGARCH)
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
	$(INSTALL_BIN)  ./files/usr/sbin/wuxuroute              $(1)/usr/sbin/
	$(INSTALL_BIN)  ./files/etc/init.d/wuxuroute            $(1)/etc/init.d/
	$(INSTALL_DATA) ./files/etc/config/wuxuroute            $(1)/etc/config/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/wuxuroute.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/wuxuroute.lua  $(1)/usr/lib/lua/luci/model/cbi/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/wuxuroute enable 2>/dev/null || true
}
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/wuxuroute stop 2>/dev/null || true
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
