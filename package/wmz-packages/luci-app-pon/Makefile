include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pon
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pon
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=Applications
  TITLE:=PON / XGSPON Management (BOSA/RI upload + LOID/SN)
  DEPENDS:=+luci-base
  PKGARCH:=all
endef

define Package/luci-app-pon/description
  Manage Airoha AN7581 XGSPON: edit LOID/password/SN, upload factory BOSA
  calibration and RI serial data into the UBI volumes, and view PON status.
endef

define Build/Compile
endef

define Package/luci-app-pon/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/pon.lua $(1)/usr/lib/lua/luci/controller/pon.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./luasrc/model/cbi/pon.lua $(1)/usr/lib/lua/luci/model/cbi/pon.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/pon
	$(INSTALL_DATA) ./luasrc/view/pon/calib.htm $(1)/usr/lib/lua/luci/view/pon/calib.htm
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./root/usr/sbin/pon-vol $(1)/usr/sbin/pon-vol
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-pon.json $(1)/usr/share/rpcd/acl.d/luci-app-pon.json
endef

$(eval $(call BuildPackage,luci-app-pon))
