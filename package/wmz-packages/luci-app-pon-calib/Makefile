include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pon-calib
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pon-calib
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=Applications
  TITLE:=PON BOSA/RI calibration upload (AN7581 XGSPON)
  DEPENDS:=+luci-base
  PKGARCH:=all
endef

define Package/luci-app-pon-calib/description
  Upload factory BOSA calibration and RI serial data into the UBI volumes of
  the Airoha AN7581 XGSPON (Nokia XG-040G-MD), and view PON volume/link status.
  PON registration credentials (LOID/password/SN) are handled by luci-app-pon.
endef

define Build/Compile
endef

define Package/luci-app-pon-calib/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/pon_calib.lua $(1)/usr/lib/lua/luci/controller/pon_calib.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/pon_calib
	$(INSTALL_DATA) ./luasrc/view/pon_calib/calib.htm $(1)/usr/lib/lua/luci/view/pon_calib/calib.htm
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./root/usr/sbin/pon-vol $(1)/usr/sbin/pon-vol
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-pon-calib.json $(1)/usr/share/rpcd/acl.d/luci-app-pon-calib.json
endef

$(eval $(call BuildPackage,luci-app-pon-calib))
