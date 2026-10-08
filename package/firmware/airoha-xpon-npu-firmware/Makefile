#
# SPDX-License-Identifier: Proprietary
#
# airoha-xpon-npu-firmware - Airoha AN7581 NPU (rv32) firmware asset
#
# Extracted from the stock Nokia Bell XG-040G-MD firmware
# (userfs/npu_rv32.bin + userfs/npu_data.bin). The on-die NPU runs a single
# rv32 core; on this ONT that firmware is the WiFi/PPE offload HAL (the stock
# npu.ko loader requests these exact blobs - it is NOT an XPON HAL; the PON
# optical link is driven by the on-die PON MAC, see
# Tools/re_notes_omci_mailbox.md rev 2).
#
# NOTE: proprietary vendor blob - for the device owner's personal use only,
# NOT redistributable.

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
  TITLE:=Airoha AN7581 NPU firmware (extracted, WiFi/PPE offload)
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
  Proprietary Airoha AN7581 NPU rv32 firmware, extracted from the stock
  Nokia Bell XG-040G-MD image (userfs/npu_rv32.bin + npu_data.bin). Placed
  at /lib/firmware/airoha/ as the asset consumed by the in-tree NPU driver
  (airoha_npu.c). This is the WiFi/PPE offload firmware; the PON optical
  link is driven by the on-die PON MAC, not by the NPU.
endef

define Build/Prepare
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

# Firmware-only package: the blobs are prebuilt, there is nothing to
# compile. Override the default Build/Compile (which would cd into
# $(PKG_BUILD_DIR) and run make -> "No targets specified and no makefile
# found").
define Build/Compile
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
