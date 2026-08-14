define Build/an7581-emmc-bl2-bl31-uboot
  head -c $$((0x800)) /dev/zero > $@
  cat $(STAGING_DIR_IMAGE)/an7581_$1-bl2.fip >> $@
  dd if=$(STAGING_DIR_IMAGE)/an7581_$1-bl31-u-boot.fip of=$@ bs=1 seek=$$((0x20000)) conv=notrunc
endef

define Build/an7581-preloader
  cat $(STAGING_DIR_IMAGE)/an7581_$1-bl2.fip >> $@
endef

define Build/an7581-bl31-uboot
  cat $(STAGING_DIR_IMAGE)/an7581_$1-bl31-u-boot.fip >> $@
endef

define Device/FitImageLzma
	KERNEL_SUFFIX := -uImage.itb
	KERNEL = kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(DEVICE_DTS).dtb
	KERNEL_NAME := Image
endef

define Device/airoha_an7581-evb
  $(call Device/FitImageLzma)
  DEVICE_VENDOR := Airoha
  DEVICE_MODEL := AN7581 Evaluation Board (SNAND)
  DEVICE_PACKAGES := kmod-leds-pwm kmod-i2c-an7581 kmod-pwm-airoha kmod-input-gpio-keys-polled
  DEVICE_DTS := an7581-evb
  DEVICE_DTS_CONFIG := config@1
  IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | pad-rootfs | append-metadata
  ARTIFACT/preloader.bin := an7581-preloader rfb
  ARTIFACT/bl31-uboot.fip := an7581-bl31-uboot rfb
  ARTIFACTS := preloader.bin bl31-uboot.fip
endef
TARGET_DEVICES += airoha_an7581-evb

define Device/airoha_an7581-evb-emmc
  DEVICE_VENDOR := Airoha
  DEVICE_MODEL := AN7581 Evaluation Board (EMMC)
  DEVICE_DTS := an7581-evb-emmc
  DEVICE_PACKAGES := kmod-i2c-an7581
  ARTIFACT/preloader.bin := an7581-preloader rfb
  ARTIFACT/bl31-uboot.fip := an7581-bl31-uboot rfb
  ARTIFACTS := preloader.bin bl31-uboot.fip
endef
TARGET_DEVICES += airoha_an7581-evb-emmc

define Device/airoha_an7581-bell-xg-040g-md
  $(call Device/FitImageLzma)
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := Bell XG-040G-MD
  DEVICE_DTS := an7581-nokia_xg-040g-md-ubi
  DEVICE_DTS_CONFIG := config@1
  # EN8811H 2.5G PHY firmware (driver is built-in: CONFIG_AIR_EN8811H_PHY=y).
  #
  # NPU firmware: there is exactly ONE rv32 core, so exactly ONE firmware
  # image can be loaded, and the in-tree driver hardcodes the request_firmware()
  # names airoha/en7581_npu_{rv32,data}.bin. Two packages ship those names:
  #   - airoha-en7581-npu-firmware  : upstream *network-offload* (PPE) blob,
  #     pulled in as a DEFAULT_PACKAGE by an7581/target.mk.
  #   - airoha-xpon-npu-firmware    : the *XPON HAL* blob extracted from the
  #     stock Nokia image - the engine that trains the optical serdes and does
  #     GTC framing / OMCI, i.e. the only one that can bring the PON link up.
  # Installing both would collide on the same two file paths, so the PPE-only
  # default is explicitly removed here ("-pkg", handled by image.mk
  # mkfs_packages_remove) and the XPON blob wins on this ONT. The stock blob
  # is the ONT's own firmware, so it also carries the PPE HAL.
  # kmod-airoha-pon reaches this firmware through the NPU mailbox (target
  # patch 110-01), see below.
  #
  # PON (XGS-PON ONT): the PON *data* plane is the SoC gdm2 MAC wired to the
  # internal pon_pcs, already enabled (CONFIG_PCS_AIROHA_AN7581=y); the
  # upstream airoha_eth driver presents it as the `pon0` WAN device. The
  # in-tree PON stack is two layers:
  #   - kmod-airoha-pon  : management-plane + OMCI transport driver (platform
  #     driver bound to the `airoha,pon` DT node). It implements the
  #     generic-netlink ABI and a /dev/airoha_pon char device carrying raw
  #     OMCI G.988 frames, drives the BOSA laser GPIO and reads
  #     Rxsd/Txsd/TxFault. Does NOT create a netdev; `pon0` comes from
  #     gdm2/pon_pcs. hal_backend=sim (default) synthesises O5 + echoes OMCI
  #     so the whole stack is exercisable without the proprietary firmware.
  #   - pon-manager      : userspace (netifd `pon` proto + /etc/config/pon +
  #     OMCI/PLOAM daemon ponmgr + ponctl); board.d/99-airoha-pon wires pon0
  #     as WAN automatically. ponmgr talks OMCI to the driver via
  #     /dev/airoha_pon.
  #   - luci-app-pon     : web management UI (status / activate / config).
  DEVICE_PACKAGES := kmod-i2c-an7581 airoha-en8811h-firmware -airoha-en7581-npu-firmware airoha-xpon-npu-firmware kmod-airoha-pon pon-manager luci-app-pon
  IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | pad-rootfs | append-metadata
  ARTIFACT/preloader.bin := an7581-preloader bell-xg-040g-md
  ARTIFACT/bl31-uboot.fip := an7581-bl31-uboot bell-xg-040g-md
  ARTIFACTS := preloader.bin bl31-uboot.fip
endef
TARGET_DEVICES += airoha_an7581-bell-xg-040g-md
