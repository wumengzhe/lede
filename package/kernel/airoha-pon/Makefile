# SPDX-License-Identifier: GPL-2.0-only
#
# kmod-airoha-pon - Airoha AN7581 PON (XPON) management-plane kernel driver
#
# The PON *data* plane (gdm2 + pon_pcs) is driven by the upstream airoha_eth
# driver and presented as the `pon0` network device (named via the board DTS).
# This module is the management plane + OMCI transport:
#   - generic-netlink family "airoha_pon" (ABI shared with pon-manager)
#   - char device /dev/airoha_pon carrying raw OMCI G.988 frames
#   - BOSA laser enable/disable GPIO + Rxsd/Txsd/TxFault board inputs
# It does NOT create a netdev.
#
# The real optical synchronisation is performed by the Airoha NPU firmware
# (XPON HAL). The `hal_backend` module param selects the engine:
#   0 = sim   synthesises O5 bring-up + echoes OMCI so the whole userspace
#             stack is exercisable without the proprietary firmware
#   1 = real  replays the reverse-engineered PON MAC init sequence and ships
#             OMCI to the NPU XPON-HAL over the NPU mailbox transport added by
#             target patch 110-01 (airoha_npu_xpon_send_msg). The mailbox
#             func_id is auto-discovered at runtime, see the driver header.
# The shipped /etc/modprobe.d/airoha-pon.conf selects hal_backend=1, because
# on an ONT the real path is the point; edit it to fall back to the simulator.

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=airoha-pon
PKG_RELEASE:=1

PKG_MAINTAINER:=OpenWrt Airoha porting <local>
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/airoha-pon
  SUBMENU:=Network Devices
  TITLE:=Airoha AN7581 PON (XPON) management-plane driver
  FILES:=$(PKG_BUILD_DIR)/airoha_pon.ko
  AUTOLOAD:=$(call AutoProbe,airoha_pon,1)
  DEPENDS:=@TARGET_airoha
endef

define KernelPackage/airoha-pon/description
  Management-plane kernel driver for the Airoha AN7581 on-die PON
  (XGS-PON/GPON) interface.

  The PON data plane is the SoC gdm2 MAC + internal pon_pcs, surfaced by the
  upstream airoha_eth driver as the `pon0` WAN network device. This module
  registers a generic-netlink family named "airoha_pon" (ABI shared with the
  pon-manager daemon) and drives the BOSA laser enable/disable GPIO and reads
  the Rxsd/Txsd/TxFault board inputs.

  The real optical synchronisation is performed by the Airoha NPU firmware
  (XPON HAL), which this driver reaches over the NPU mailbox transport added by
  target patch 110-01. Select the engine with the `hal_backend` module param
  (1 = real, the shipped default; 0 = simulator, which synthesises an O1..O5
  bring-up and echoes OMCI so provisioning, the netlink contract, laser GPIO
  control and diagnostics all stay exercisable without the proprietary blob).
endef

define Package/kmod-airoha-pon/conffiles
/etc/modprobe.d/airoha-pon.conf
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(KERNEL_MAKE_FLAGS) \
		CONFIG_AIROHA_PON=m \
		M="$(PKG_BUILD_DIR)" \
		modules
endef

define KernelPackage/airoha-pon/install
	$(INSTALL_DIR) $(1)/etc/modprobe.d
	$(INSTALL_DATA) ./files/airoha-pon.conf $(1)/etc/modprobe.d/airoha-pon.conf
endef

$(eval $(call KernelPackage,airoha-pon))
