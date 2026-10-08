# SPDX-License-Identifier: GPL-2.0-only
#
# pon-manager - userspace PON stack for the Airoha AN7581 XGS-PON ONT
#
# ponmgr:  OMCI/PLOAM daemon. Talks to kmod-airoha-pon over the genl family
#          "airoha_pon" and the /dev/airoha_pon char device, watches `pon0`
#          (gdm2/pon_pcs data plane) via RTNL, and reads UCI /etc/config/pon.
# ponctl:  CLI (status / activate / deactivate / apply / set).
# pon.sh:  netifd `pon` protocol handler.
# 99-pon:  uci-defaults wiring pon0 as WAN.

include $(TOPDIR)/rules.mk

PKG_NAME:=pon-manager
PKG_RELEASE:=1

PKG_MAINTAINER:=OpenWrt AN7581 PON porting <local>
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/pon-manager
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Airoha AN7581 PON (XPON) management daemon + CLI
  DEPENDS:=+libuci +libubox +libubus +kmod-airoha-pon
endef

define Package/pon-manager/description
  Userspace management stack for the Airoha AN7581 XGS-PON ONT data plane
  (gdm2/pon_pcs, netdev pon0): OMCI G.988 message send/recv through
  kmod-airoha-pon, PON state reporting, laser control, provisioning,
  netifd `pon` protocol and the ponctl CLI.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./files/*.c ./files/*.h $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include \
		-o $(PKG_BUILD_DIR)/ponmgr $(PKG_BUILD_DIR)/ponmgr.c \
		$(PKG_BUILD_DIR)/omci.c \
		-L$(STAGING_DIR)/usr/lib -luci -lubox -lubus
	$(TARGET_CC) $(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include \
		-o $(PKG_BUILD_DIR)/ponctl $(PKG_BUILD_DIR)/ponctl.c
	$(TARGET_CC) $(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include \
		-I$(PKG_BUILD_DIR) \
		-o $(PKG_BUILD_DIR)/omcid2 $(PKG_BUILD_DIR)/omcid2.c
endef

define Package/pon-manager/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ponmgr $(1)/usr/sbin/ponmgr
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ponctl $(1)/usr/sbin/ponctl
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/omcid2 $(1)/usr/sbin/omcid2
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/pon.init $(1)/etc/init.d/pon
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/pon.config $(1)/etc/config/pon
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-pon $(1)/etc/uci-defaults/99-pon
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/pon.sh $(1)/lib/netifd/proto/pon.sh
endef

$(eval $(call BuildPackage,pon-manager))
