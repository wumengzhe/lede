#
# SPDX-License-Identifier: Proprietary
#
# airoha-xpon-npu-firmware - Airoha AN7581 XPON NPU (rv32) firmware asset
#
# Extracted from the stock Nokia Bell XG-040G-MD firmware
# (userfs/npu_rv32.bin + userfs/npu_data.bin). This is the proprietary
# Airoha XPON HAL that runs on the on-die NPU and drives the optical
# serdes / GTC framing. It is required (together with a k6.12 XPON MAC
# driver) to bring the PON link up.
#
# NOTE: proprietary vendor blob - for the device owner's personal use only,
# NOT redistributable. The real PON bring-up also needs Airoha's k6.12
# xpon_bsp (or an open reimplementation); see PON_REFACTOR_SUMMARY.md.

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=airoha-xpon-npu-firmware
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_MAINTAINER:=OpenWrt AN7581 PON porting
PKG_LICENSE:=proprietary

include $(INCLUDE_DIR)/package.mk

define Package/airoha-xpon-npu-firmware
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Airoha AN7581 XPON NPU firmware (extracted)
  DEPENDS:=@TARGET_airoha
  # The AN7581 has ONE NPU rv32 core, so only one firmware image can ever be
  # loaded, and the in-tree driver requests the fixed names
  # airoha/en7581_npu_{rv32,data}.bin. This package installs those names with
  # the XPON HAL blob, which collides file-for-file with the upstream
  # PPE-offload package airoha-en7581-npu-firmware. Declare it so the
  # combination is rejected up front instead of failing later with a
  # confusing "file already provided by package" clash.
  CONFLICTS:=airoha-en7581-npu-firmware
  PKG_FLAGS:=nonshared
endef

define Package/airoha-xpon-npu-firmware/description
  Proprietary Airoha AN7581 XPON (XGS-PON/GPON) NPU rv32 firmware, extracted
  from the stock Nokia Bell XG-040G-MD image. Placed at
  /lib/firmware/airoha/ as the asset consumed by the XPON MAC driver.
endef

define Build/Prepare
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Package/airoha-xpon-npu-firmware/install
	$(INSTALL_DIR) $(1)/lib/firmware/airoha
	# The in-tree NPU driver (drivers/net/ethernet/airoha/airoha_npu.c,
	# patches-6.12/048-12..102-*) requests these EXACT names via
	# request_firmware(). A name mismatch makes request_firmware() fail,
	# the NPU never boots and the PON link can never come up.
	$(CP) $(PKG_BUILD_DIR)/an7581_xpon_npu_rv32.bin \
		$(1)/lib/firmware/airoha/en7581_npu_rv32.bin
	$(CP) $(PKG_BUILD_DIR)/an7581_xpon_npu_data.bin \
		$(1)/lib/firmware/airoha/en7581_npu_data.bin
	# Keep the descriptive (stock-derived) names as aliases for reference.
	$(CP) $(PKG_BUILD_DIR)/an7581_xpon_npu_rv32.bin \
		$(1)/lib/firmware/airoha/an7581_xpon_npu_rv32.bin
	$(CP) $(PKG_BUILD_DIR)/an7581_xpon_npu_data.bin \
		$(1)/lib/firmware/airoha/an7581_xpon_npu_data.bin
endef

$(eval $(call BuildPackage,airoha-xpon-npu-firmware))
