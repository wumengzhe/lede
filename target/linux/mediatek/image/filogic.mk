DTS_DIR := $(DTS_DIR)/mediatek

define Image/Prepare
	# For UBI we want only one extra block
	rm -f $(KDIR)/ubi_mark
	echo -ne '\xde\xad\xc0\xde' > $(KDIR)/ubi_mark
endef

define Build/mt7981-bl2
	cat $(STAGING_DIR_IMAGE)/mt7981-$1-bl2.img >> $@
endef

define Build/mt7981-bl31-uboot
	cat $(STAGING_DIR_IMAGE)/mt7981_$1-u-boot.fip >> $@
endef

define Build/mt7986-bl2
	cat $(STAGING_DIR_IMAGE)/mt7986-$1-bl2.img >> $@
endef

define Build/mt7986-bl31-uboot
	cat $(STAGING_DIR_IMAGE)/mt7986_$1-u-boot.fip >> $@
endef

define Build/mt7987-bl2
	cat $(STAGING_DIR_IMAGE)/mt7987-$1-bl2.img >> $@
endef

define Build/mt7987-bl31-uboot
	cat $(STAGING_DIR_IMAGE)/mt7987_$1-u-boot.fip >> $@
endef

define Build/mt7988-bl2
	cat $(STAGING_DIR_IMAGE)/mt7988-$1-bl2.img >> $@
endef

define Build/mt7988-bl31-uboot
	cat $(STAGING_DIR_IMAGE)/mt7988_$1-u-boot.fip >> $@
endef

define Build/mt798x-gpt
	cp $@ $@.tmp 2>/dev/null || true
	ptgen -g -o $@.tmp -a 1 -l 1024 \
		$(if $(findstring sdmmc,$1), \
			-H \
			-t 0x83	-N bl2		-r	-p 4079k@17k \
		) \
			-t 0x83	-N ubootenv	-r	-p 512k@4M \
			-t 0x83	-N factory	-r	-p 2M@4608k \
			-t 0xef	-N fip		-r	-p 4M@6656k \
				-N recovery	-r	-p 32M@12M \
		$(if $(findstring sdmmc,$1), \
				-N install	-r	-p 20M@44M \
			-t 0x2e -N production		-p $(CONFIG_TARGET_ROOTFS_PARTSIZE)M@64M \
		) \
		$(if $(findstring emmc,$1), \
			-t 0x2e -N production		-p $(CONFIG_TARGET_ROOTFS_PARTSIZE)M@64M \
		)
	cat $@.tmp >> $@
	rm $@.tmp
endef

define Build/cetron-header
	$(eval magic=$(word 1,$(1)))
	$(eval model=$(word 2,$(1)))
	( \
		dd if=/dev/zero bs=856 count=1 2>/dev/null; \
		printf "$(model)," | dd bs=128 count=1 conv=sync 2>/dev/null; \
		md5sum $@ | cut -f1 -d" " | dd bs=32 count=1 2>/dev/null; \
		printf "$(magic)" | dd bs=4 count=1 conv=sync 2>/dev/null; \
		cat $@; \
	) > $@.tmp
	fw_crc=$$(gzip -c $@.tmp | tail -c 8 | od -An -N4 -tx4 --endian little | tr -d ' \n'); \
	printf "$$(echo $$fw_crc | sed 's/../\\x&/g')" | cat - $@.tmp > $@
	rm $@.tmp
endef

define Build/tenda-mkdualimageheader
	printf '%b' "\x47\x6f\x64\x31\x00\x00\x00\x00" >"$@.new"
	gzip -c "$@" | tail -c8 >>"$@.new"
	cat "$@" >>"$@.new"
	mv "$@.new" "$@"
endef


# ============================================================
# 设备块按 DEVICE_TITLE 字母升序重排 (2026-08-07)
#   * 4 个 `*-common` 公共定义放在前面 (无菜单项)
#   * 87 个具体设备按 VENDOR + MODEL (+ VARIANT) 升序
# ============================================================

define Device/bananapi_bpi-r3-common
  DEVICE_VENDOR := Bananapi
  DEVICE_MODEL := BPI-R3 Mini
  DEVICE_DTS_DIR := $(DTS_DIR)/
  DEVICE_PACKAGES := e2fsprogs f2fsck mkf2fs \
	kmod-hwmon-pwmfan kmod-mt7915e kmod-mt7986-firmware \
	kmod-phy-airoha-en8811h kmod-usb3 mt7986-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef

define Device/bananapi_bpi-r4-common
  DEVICE_VENDOR := Bananapi
  DEVICE_DTS_DIR := $(DTS_DIR)/
  DEVICE_DTS_LOADADDR := 0x45f00000
  DEVICE_DTS_OVERLAY:= mt7988a-bananapi-bpi-r4-emmc mt7988a-bananapi-bpi-r4-rtc mt7988a-bananapi-bpi-r4-sd
  DEVICE_DTC_FLAGS := --pad 4096
  DEVICE_PACKAGES := kmod-hwmon-pwmfan kmod-i2c-mux-pca954x kmod-eeprom-at24 kmod-mt7996-233-firmware \
		     kmod-rtc-pcf8563 kmod-sfp kmod-usb3 e2fsprogs f2fsck mkf2fs mt7988-wo-firmware fitblk
  IMAGES := sysupgrade.itb
  KERNEL_LOADADDR := 0x46000000
  KERNEL_INITRAMFS_SUFFIX := -recovery.itb
  ARTIFACTS := \
	       emmc-preloader.bin emmc-bl31-uboot.fip \
	       sdcard.img.gz \
	       snand-preloader.bin snand-bl31-uboot.fip
  ARTIFACT/emmc-preloader.bin	:= mt7988-bl2 emmc-comb
  ARTIFACT/emmc-bl31-uboot.fip	:= mt7988-bl31-uboot $$(DEVICE_NAME)-emmc
  ARTIFACT/snand-preloader.bin	:= mt7988-bl2 spim-nand-ubi-comb
  ARTIFACT/snand-bl31-uboot.fip	:= mt7988-bl31-uboot $$(DEVICE_NAME)-snand
  ARTIFACT/sdcard.img.gz	:= mt798x-gpt sdmmc |\
				   pad-to 17k | mt7988-bl2 sdmmc-comb |\
				   pad-to 6656k | mt7988-bl31-uboot $$(DEVICE_NAME)-sdmmc |\
				$(if $(CONFIG_TARGET_ROOTFS_INITRAMFS),\
				   pad-to 12M | append-image-stage initramfs-recovery.itb | check-size 44m |\
				) \
				   pad-to 44M | mt7988-bl2 spim-nand-ubi-comb |\
				   pad-to 45M | mt7988-bl31-uboot $$(DEVICE_NAME)-snand |\
				   pad-to 51M | mt7988-bl2 emmc-comb |\
				   pad-to 52M | mt7988-bl31-uboot $$(DEVICE_NAME)-emmc |\
				   pad-to 56M | mt798x-gpt emmc |\
				$(if $(CONFIG_TARGET_ROOTFS_SQUASHFS),\
				   pad-to 64M | append-image squashfs-sysupgrade.itb | check-size |\
				) \
				  gzip
  IMAGE_SIZE := $$(shell expr 64 + $$(CONFIG_TARGET_ROOTFS_PARTSIZE))m
  KERNEL			:= kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.itb := append-kernel | fit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb external-with-rootfs | pad-rootfs | append-metadata
endef

define Device/glinet_gl-x3000-xe3000-common
  DEVICE_VENDOR := GL.iNet
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware mkf2fs \
    kmod-fs-f2fs kmod-hwmon-pwmfan kmod-usb3 kmod-usb-serial-option \
    kmod-usb-storage kmod-usb-net-qmi-wwan uqmi
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef

define Device/tplink_tl-common
  DEVICE_VENDOR := TP-Link
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef

define Device/abt_asr3000
  DEVICE_VENDOR := ABT
  DEVICE_MODEL := ASR3000
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-abt-asr3000
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += abt_asr3000

define Device/abt_asr3000-256m
  DEVICE_VENDOR := ABT
  DEVICE_MODEL := ASR3000
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-abt-asr3000-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += abt_asr3000-256m
define Device/abt_asr3000-512m
  DEVICE_VENDOR := ABT
  DEVICE_MODEL := ASR3000
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-abt-asr3000-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += abt_asr3000-512m
define Device/abt_asr3000-auto
  DEVICE_VENDOR := ABT
  DEVICE_MODEL := ASR3000
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-abt-asr3000-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += abt_asr3000-auto
define Device/aigo_s21
  DEVICE_VENDOR := Aigo
  DEVICE_MODEL := S21
  DEVICE_DTS := mt7981b-aigo-s21
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware blkid blockdev fdisk f2fsck mkf2fs automount kmod-mmc
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += aigo_s21

define Device/airpi_ap3000m
  DEVICE_VENDOR := Airpi
  DEVICE_MODEL := AP3000M
  DEVICE_DTS := mt7981b-Airpi-emmc16G
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  SUPPORTED_DEVICES += Airpi,emmc-16g
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs automount
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += airpi_ap3000m

define Device/asus_tuf-ax4200
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX4200
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7986a-asus-tuf-ax4200
  DEVICE_DTS_DIR := ../dts
  DEVICE_DTS_LOADADDR := 0x47000000
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGES := sysupgrade.bin
  KERNEL := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax4200

define Device/asus_tuf-ax4200-256m
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX4200
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7986a-asus-tuf-ax4200-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 258048k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax4200-256m
define Device/asus_tuf-ax4200-512m
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX4200
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7986a-asus-tuf-ax4200-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 520192k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax4200-512m
define Device/asus_tuf-ax4200-auto
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX4200
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7986a-asus-tuf-ax4200-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 520192k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax4200-auto
define Device/asus_tuf-ax6000
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX6000
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7986a-asus-tuf-ax6000
  DEVICE_DTS_DIR := ../dts
  DEVICE_DTS_LOADADDR := 0x47000000
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGES := sysupgrade.bin
  KERNEL := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax6000

define Device/asus_tuf-ax6000-256m
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX6000
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7986a-asus-tuf-ax6000-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 258048k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax6000-256m
define Device/asus_tuf-ax6000-512m
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX6000
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7986a-asus-tuf-ax6000-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 520192k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax6000-512m
define Device/asus_tuf-ax6000-auto
  DEVICE_VENDOR := ASUS
  DEVICE_MODEL := TUF-AX6000
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7986a-asus-tuf-ax6000-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 520192k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += asus_tuf-ax6000-auto
define Device/bananapi_bpi-r3
  DEVICE_VENDOR := Bananapi
  DEVICE_MODEL := BPi-R3
  DEVICE_DTS := mt7986a-bananapi-bpi-r3
  DEVICE_DTS_CONFIG := config-mt7986a-bananapi-bpi-r3
  DEVICE_DTS_OVERLAY:= mt7986a-bananapi-bpi-r3-emmc mt7986a-bananapi-bpi-r3-nand mt7986a-bananapi-bpi-r3-nor mt7986a-bananapi-bpi-r3-sd
  DEVICE_DTS_DIR := $(DTS_DIR)/
  DEVICE_PACKAGES := kmod-hwmon-pwmfan kmod-i2c-gpio kmod-mt7986-firmware kmod-sfp kmod-usb3 e2fsprogs f2fsck mkf2fs mt7986-wo-firmware
  IMAGES := sysupgrade.itb
  KERNEL_LOADADDR := 0x44000000
  KERNEL_INITRAMFS_SUFFIX := -recovery.itb
  ARTIFACTS := \
	       emmc-preloader.bin emmc-bl31-uboot.fip \
	       nor-preloader.bin nor-bl31-uboot.fip \
	       sdcard.img.gz \
	       snand-preloader.bin snand-bl31-uboot.fip
  ARTIFACT/emmc-preloader.bin	:= mt7986-bl2 emmc-ddr4
  ARTIFACT/emmc-bl31-uboot.fip	:= mt7986-bl31-uboot bananapi_bpi-r3-emmc
  ARTIFACT/nor-preloader.bin	:= mt7986-bl2 nor-ddr4
  ARTIFACT/nor-bl31-uboot.fip	:= mt7986-bl31-uboot bananapi_bpi-r3-nor
  ARTIFACT/snand-preloader.bin	:= mt7986-bl2 spim-nand-ddr4
  ARTIFACT/snand-bl31-uboot.fip	:= mt7986-bl31-uboot bananapi_bpi-r3-snand
  ARTIFACT/sdcard.img.gz	:= mt798x-gpt sdmmc |\
				   pad-to 17k | mt7986-bl2 sdmmc-ddr4 |\
				   pad-to 6656k | mt7986-bl31-uboot bananapi_bpi-r3-sdmmc |\
				$(if $(CONFIG_TARGET_ROOTFS_INITRAMFS),\
				   pad-to 12M | append-image-stage initramfs-recovery.itb | check-size 44m |\
				) \
				   pad-to 44M | mt7986-bl2 spim-nand-ddr4 |\
				   pad-to 45M | mt7986-bl31-uboot bananapi_bpi-r3-snand |\
				   pad-to 49M | mt7986-bl2 nor-ddr4 |\
				   pad-to 50M | mt7986-bl31-uboot bananapi_bpi-r3-nor |\
				   pad-to 51M | mt7986-bl2 emmc-ddr4 |\
				   pad-to 52M | mt7986-bl31-uboot bananapi_bpi-r3-emmc |\
				   pad-to 56M | mt798x-gpt emmc |\
				$(if $(CONFIG_TARGET_ROOTFS_SQUASHFS),\
				   pad-to 64M | append-image squashfs-sysupgrade.itb | check-size |\
				) \
				  gzip
  IMAGE_SIZE := $$(shell expr 64 + $$(CONFIG_TARGET_ROOTFS_PARTSIZE))m
  KERNEL			:= kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.itb := append-kernel | fit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb external-static-with-rootfs | pad-rootfs | append-metadata
  DEVICE_DTC_FLAGS := --pad 4096
  DEVICE_COMPAT_VERSION := 1.1
  DEVICE_COMPAT_MESSAGE := Device tree overlay mechanism needs bootloader update
endef
TARGET_DEVICES += bananapi_bpi-r3

define Device/bananapi_bpi-r3-mini-emmc
  $(call Device/bananapi_bpi-r3-common)
  DEVICE_MODEL := BPI-R3 Mini (eMMC)
  DEVICE_DTS := mt7986a-bananapi-bpi-r3mini-emmc
  SUPPORTED_DEVICES += bananapi,bpi-r3-mini
endef
TARGET_DEVICES += bananapi_bpi-r3-mini-emmc

define Device/bananapi_bpi-r3-mini-nand
  $(call Device/bananapi_bpi-r3-common)
  DEVICE_MODEL := BPI-R3 Mini (NAND)
  DEVICE_DTS := mt7986a-bananapi-bpi-r3mini-nand
  SUPPORTED_DEVICES += bananapi,bpi-r3-mini
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
endef
TARGET_DEVICES += bananapi_bpi-r3-mini-nand

define Device/bananapi_bpi-r4
  DEVICE_MODEL := BPi-R4
  DEVICE_DTS := mt7988a-bananapi-bpi-r4
  DEVICE_DTS_CONFIG := config-mt7988a-bananapi-bpi-r4
  $(call Device/bananapi_bpi-r4-common)
endef
TARGET_DEVICES += bananapi_bpi-r4

define Device/bananapi_bpi-r4-poe
  DEVICE_MODEL := BPi-R4 2.5GE
ifneq ($(CONFIG_LINUX_6_6),)
  DEVICE_DTS := mt7988a-bananapi-bpi-r4-poe
else
  DEVICE_DTS := mt7988a-bananapi-bpi-r4-2g5
endif
  DEVICE_DTS_CONFIG := config-mt7988a-bananapi-bpi-r4-poe
  $(call Device/bananapi_bpi-r4-common)
  DEVICE_PACKAGES += mt7988-2p5g-phy-firmware
  SUPPORTED_DEVICES += bananapi,bpi-r4-2g5
endef
TARGET_DEVICES += bananapi_bpi-r4-poe

define Device/bananapi_bpi-r4-lite
  DEVICE_VENDOR := Bananapi
  DEVICE_MODEL := BPi-R4 Lite
  DEVICE_DTS := mt7987a-bananapi-bpi-r4-lite
  DEVICE_DTS_OVERLAY:= mt7987a-bananapi-bpi-r4-lite-1pcie-2L \
		       mt7987a-bananapi-bpi-r4-lite-2pcie-1L \
		       mt7987a-bananapi-bpi-r4-lite-emmc mt7987a-bananapi-bpi-r4-lite-sd \
		       mt7987a-bananapi-bpi-r4-lite-nand mt7987a-bananapi-bpi-r4-lite-nor
  DEVICE_DTS_CONFIG := config-mt7987a-bananapi-bpi-r4-lite
  DEVICE_DTC_FLAGS := --pad 4096
  DEVICE_DTS_DIR := ../dts
  DEVICE_DTS_LOADADDR := 0x4ff00000
  DEVICE_PACKAGES := fitblk kmod-eeprom-at24 kmod-gpio-pca953x kmod-i2c-mux-pca954x \
		     kmod-rtc-pcf8563 kmod-sfp kmod-usb3 e2fsprogs mkf2fs mt7987-2p5g-phy-firmware
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  UBOOTENV_IN_UBI := 1
  KERNEL_LOADADDR := 0x40000000
  KERNEL := kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGES := sysupgrade.itb
  KERNEL_INITRAMFS_SUFFIX := -recovery.itb
  KERNEL_IN_UBI := 1
  IMAGES := sysupgrade.itb
  IMAGE/sysupgrade.itb := append-kernel | fit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb external-with-rootfs | pad-rootfs | append-metadata
  ARTIFACTS := \
	       emmc-preloader.bin emmc-bl31-uboot.fip \
	       nor-preloader.bin nor-bl31-uboot.fip \
	       sdcard.img.gz \
	       snand-preloader.bin snand-bl31-uboot.fip
  ARTIFACT/emmc-preloader.bin	:= mt7987-bl2 emmc-comb
  ARTIFACT/emmc-bl31-uboot.fip	:= mt7987-bl31-uboot bananapi_bpi-r4-lite-emmc
  ARTIFACT/nor-preloader.bin	:= mt7987-bl2 nor-comb
  ARTIFACT/nor-bl31-uboot.fip	:= mt7987-bl31-uboot bananapi_bpi-r4-lite-nor
  ARTIFACT/snand-preloader.bin	:= mt7987-bl2 spim-nand2-ubi-comb
  ARTIFACT/snand-bl31-uboot.fip	:= mt7987-bl31-uboot bananapi_bpi-r4-lite-snand
  ARTIFACT/sdcard.img.gz	:= mt798x-gpt sdmmc |\
				   pad-to 17k | mt7987-bl2 sdmmc-comb |\
				   pad-to 6656k | mt7987-bl31-uboot bananapi_bpi-r4-lite-sdmmc |\
				$(if $(CONFIG_TARGET_ROOTFS_INITRAMFS),\
				   pad-to 12M | append-image-stage initramfs-recovery.itb | check-size 44m |\
				) \
				   pad-to 44M | mt7987-bl2 spim-nand2-ubi-comb |\
				   pad-to 45M | mt7987-bl31-uboot bananapi_bpi-r4-lite-snand |\
				   pad-to 49M | mt7987-bl2 nor-comb |\
				   pad-to 50M | mt7987-bl31-uboot bananapi_bpi-r4-lite-nor |\
				   pad-to 51M | mt7987-bl2 emmc-comb |\
				   pad-to 52M | mt7987-bl31-uboot bananapi_bpi-r4-lite-emmc |\
				   pad-to 56M | mt798x-gpt emmc |\
				$(if $(CONFIG_TARGET_ROOTFS_SQUASHFS),\
				   pad-to 64M | append-image squashfs-sysupgrade.itb | check-size |\
				) \
				  gzip
  IMAGE_SIZE := $$(shell expr 64 + $$(CONFIG_TARGET_ROOTFS_PARTSIZE))m
endef
TARGET_DEVICES += bananapi_bpi-r4-lite

define Device/bt_r320
  DEVICE_VENDOR := BT
  DEVICE_MODEL := R320
  DEVICE_DTS := mt7981b-bt-r320
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs automount
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += bt_r320

define Device/bt_rb300
  DEVICE_VENDOR := BT
  DEVICE_MODEL := RB300
  DEVICE_DTS := mt7981b-bt-rb300
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += bt_rb300

define Device/cetron_ct3003
  DEVICE_VENDOR := Cetron
  DEVICE_MODEL := CT3003
  DEVICE_DTS := mt7981b-cetron-ct3003
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += mediatek,mt7981-spim-snand-rfb
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  IMAGES += factory.bin
  IMAGE/factory.bin := $$(IMAGE/sysupgrade.bin) | cetron-header rd30 CT3003
endef
TARGET_DEVICES += cetron_ct3003

define Device/cetron_ct3003-mod
  DEVICE_VENDOR := Cetron
  DEVICE_MODEL := CT3003 (U-Boot mod)
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-cetron-ct3003-mod
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cetron_ct3003-mod

define Device/cetron_ct3003-mod-256m
  DEVICE_VENDOR := Cetron
  DEVICE_MODEL := CT3003 (U-Boot mod)
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-cetron-ct3003-mod-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cetron_ct3003-mod-256m
define Device/cetron_ct3003-mod-512m
  DEVICE_VENDOR := Cetron
  DEVICE_MODEL := CT3003 (U-Boot mod)
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-cetron-ct3003-mod-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cetron_ct3003-mod-512m
define Device/cetron_ct3003-mod-auto
  DEVICE_VENDOR := Cetron
  DEVICE_MODEL := CT3003 (U-Boot mod)
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-cetron-ct3003-mod-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cetron_ct3003-mod-auto
define Device/clx_s20p
  DEVICE_VENDOR := CLX
  DEVICE_MODEL := S20P
  DEVICE_DTS := mt7986a-clx-s20p
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware kmod-usb3 automount
  DEVICE_ALT0_VENDOR := CLX
  DEVICE_ALT0_MODEL := S20
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += clx_s20p

define Device/cmcc_a10
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := A10
  DEVICE_DTS := mt7981b-cmcc-a10
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  SUPPORTED_DEVICES += mediatek,mt7981-spim-snand-rfb
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cmcc_a10

define Device/cmcc_a10-mod
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := A10 (U-Boot mod)
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-cmcc-a10-mod
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 98304k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cmcc_a10-mod

define Device/cmcc_a10-mod-256m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := A10 (U-Boot mod)
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-cmcc-a10-mod-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_a10-mod-256m
define Device/cmcc_a10-mod-512m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := A10 (U-Boot mod)
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-cmcc-a10-mod-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_a10-mod-512m
define Device/cmcc_a10-mod-auto
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := A10 (U-Boot mod)
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-cmcc-a10-mod-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_a10-mod-auto
define Device/cmcc_rax3000m-emmc
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M (eMMC version)
  DEVICE_DTS := mt7981b-cmcc-rax3000m-emmc
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-emmc

define Device/cmcc_rax3000m-nand
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M (NAND version)
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-cmcc-rax3000m-nand
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 116736k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-nand

define Device/cmcc_rax3000m-nand-256m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M (NAND version)
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-cmcc-rax3000m-nand-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-nand-256m
define Device/cmcc_rax3000m-nand-512m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M (NAND version)
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-cmcc-rax3000m-nand-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-nand-512m
define Device/cmcc_rax3000m-nand-auto
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M (NAND version)
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-cmcc-rax3000m-nand-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-nand-auto
define Device/cmcc_xr30-emmc
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30 (eMMC version)
  DEVICE_DTS := mt7981b-cmcc-xr30-emmc
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-emmc

define Device/cmcc_xr30-nand
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30 NAND
  DEVICE_VARIANT := (U-Boot mod)
  DEVICE_DTS := mt7981b-cmcc-xr30-nand
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 116736k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-nand

define Device/cmcc_xr30-nand-256m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30 NAND
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-cmcc-xr30-nand-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-nand-256m
define Device/cmcc_xr30-nand-512m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30 NAND
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-cmcc-xr30-nand-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-nand-512m
define Device/cmcc_xr30-nand-auto
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30 NAND
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-cmcc-xr30-nand-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-nand-auto
define Device/comfast_cf-wr632ax
  DEVICE_VENDOR := COMFAST
  DEVICE_MODEL := CF-WR632AX
  DEVICE_DTS := mt7981b-comfast-cf-wr632ax
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 65536k
  SUPPORTED_DEVICES += cf-wr632ax
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-hwmon-pwmfan kmod-usb3 automount
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += comfast_cf-wr632ax

define Device/comfast_cf-wr632ax-mod
  DEVICE_VENDOR := COMFAST
  DEVICE_MODEL := CF-WR632AX
  DEVICE_VARIANT := U-Boot mod
  DEVICE_DTS := mt7981b-comfast-cf-wr632ax-ubootmod
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  SUPPORTED_DEVICES += comfast,cf-wr632ax-ubootmod
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-hwmon-pwmfan kmod-usb3 automount
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += comfast_cf-wr632ax-mod

define Device/creatlentem_clt-r30b1
  DEVICE_VENDOR := CreatLentem
  DEVICE_MODEL := CLT-R30B1
  DEVICE_DTS := mt7981b-creatlentem-clt-r30b1
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 65536k
  SUPPORTED_DEVICES += mediatek,mt7981-spim-snand-rfb
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  DEVICE_ALT0_VENDOR := EDUP
  DEVICE_ALT0_MODEL := EP-RT2980
  DEVICE_ALT1_VENDOR := Dragonglass
  DEVICE_ALT1_MODEL := DGX21
  DEVICE_ALT2_VENDOR := Livinet
  DEVICE_ALT2_MODEL := Li228
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += creatlentem_clt-r30b1

define Device/cudy_tr3000-mod
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := (U-Boot mod)
  DEVICE_DTS := mt7981b-cudy-tr3000-mod
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-mod

define Device/cudy_tr3000-mod-256m
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-cudy-tr3000-mod-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 256256k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-mod-256m
define Device/cudy_tr3000-mod-512m
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-cudy-tr3000-mod-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518400k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-mod-512m
define Device/cudy_tr3000-mod-auto
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-cudy-tr3000-mod-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518400k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-mod-auto
define Device/cudy_tr3000-256mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 256mb v1
  DEVICE_DTS := mt7981b-cudy-tr3000-256mb-v1
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += R103
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-256mb-v1

define Device/cudy_tr3000-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := v1
  DEVICE_DTS := mt7981b-cudy-tr3000-v1
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += R47
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 65536k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += cudy_tr3000-v1

define Device/cudy_tr3000-v1-256m
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-cudy-tr3000-v1-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 256256k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-v1-256m
define Device/cudy_tr3000-v1-512m
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-cudy-tr3000-v1-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518400k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-v1-512m
define Device/cudy_tr3000-v1-auto
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-cudy-tr3000-v1-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518400k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-v1-auto
define Device/fzs_5gcpe-p3
  DEVICE_VENDOR := FZS
  DEVICE_MODEL := 5GCPE P3
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-fzs-5gcpe-p3
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += fzs_5gcpe-p3

define Device/fzs_5gcpe-p3-256m
  DEVICE_VENDOR := FZS
  DEVICE_MODEL := 5GCPE P3
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-fzs-5gcpe-p3-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += fzs_5gcpe-p3-256m
define Device/fzs_5gcpe-p3-512m
  DEVICE_VENDOR := FZS
  DEVICE_MODEL := 5GCPE P3
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-fzs-5gcpe-p3-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += fzs_5gcpe-p3-512m
define Device/fzs_5gcpe-p3-auto
  DEVICE_VENDOR := FZS
  DEVICE_MODEL := 5GCPE P3
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-fzs-5gcpe-p3-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += fzs_5gcpe-p3-auto
define Device/glinet_gl-mt2500
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT2500
  DEVICE_DTS := mt7981b-glinet-gl-mt2500
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := e2fsprogs f2fsck mkf2fs kmod-usb3
  SUPPORTED_DEVICES += glinet,mt2500-emmc
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += glinet_gl-mt2500

define Device/glinet_gl-mt3000
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT3000
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-glinet-gl-mt3000
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-hwmon-pwmfan kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 252160k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += glinet_gl-mt3000

define Device/glinet_gl-mt3000-256m
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT3000
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-glinet-gl-mt3000-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-hwmon-pwmfan kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 256256k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += glinet_gl-mt3000-256m
define Device/glinet_gl-mt3000-512m
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT3000
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-glinet-gl-mt3000-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-hwmon-pwmfan kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518400k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += glinet_gl-mt3000-512m
define Device/glinet_gl-mt3000-auto
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT3000
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-glinet-gl-mt3000-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-hwmon-pwmfan kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518400k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += glinet_gl-mt3000-auto
define Device/glinet_gl-mt3600be
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT3600BE
  DEVICE_DTS := mt7987a-glinet-gl-mt3600be
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := mt7987-2p5g-phy-firmware kmod-mt7990-firmware \
	kmod-hwmon-pwmfan kmod-usb3
  KERNEL_IN_UBI := 1
  KERNEL_LOADADDR := 0x40000000
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 483328k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += glinet_gl-mt3600be

define Device/glinet_gl-mt6000
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT6000
  DEVICE_DTS := mt7986a-glinet-gl-mt6000
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := e2fsprogs f2fsck mkf2fs kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += glinet_gl-mt6000

define Device/glinet_gl-x3000
  DEVICE_MODEL := GL-X3000
  DEVICE_DTS := mt7981a-glinet-gl-x3000
  SUPPORTED_DEVICES := glinet,gl-x3000
  $(call Device/glinet_gl-x3000-xe3000-common)
endef
TARGET_DEVICES += glinet_gl-x3000

define Device/glinet_gl-xe3000
  DEVICE_MODEL := GL-XE3000
  DEVICE_DTS := mt7981a-glinet-gl-xe3000
  SUPPORTED_DEVICES := glinet,gl-xe3000
  $(call Device/glinet_gl-x3000-xe3000-common)
endef
TARGET_DEVICES += glinet_gl-xe3000

define Device/h3c_magic-nx30-pro
  DEVICE_VENDOR := H3C
  DEVICE_MODEL := Magic NX30 Pro
  DEVICE_DTS := mt7981b-h3c-magic-nx30-pro
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  # smallest chip is 128 MiB, ubi starts at 56 MiB -> 72 MiB raw, keep a
  # margin for the NMBM bad block reserve
  IMAGE_SIZE := 71680k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
endef
TARGET_DEVICES += h3c_magic-nx30-pro

define Device/hf_m7986r1-emmc
  DEVICE_VENDOR := HF
  DEVICE_MODEL := M7986R1 (eMMC)
  DEVICE_DTS := mt7986a-hf-m7986r1-emmc
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7921e kmod-usb-net-rndis kmod-usb-serial-option f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  SUPPORTED_DEVICES += HF-M7986R1
endef
TARGET_DEVICES += hf_m7986r1-emmc

define Device/hf_m7986r1-nand
  DEVICE_VENDOR := HF
  DEVICE_MODEL := M7986R1 (NAND)
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7986a-hf-m7986r1-nand
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 125440k
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7921e kmod-usb-net-rndis kmod-usb-serial-option
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  SUPPORTED_DEVICES += HF-M7986R1
endef
TARGET_DEVICES += hf_m7986r1-nand

define Device/hf_m7986r1-nand-256m
  DEVICE_VENDOR := HF
  DEVICE_MODEL := M7986R1 (NAND)
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7986a-hf-m7986r1-nand-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7921e kmod-usb-net-rndis kmod-usb-serial-option
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += hf_m7986r1-nand-256m
define Device/hf_m7986r1-nand-512m
  DEVICE_VENDOR := HF
  DEVICE_MODEL := M7986R1 (NAND)
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7986a-hf-m7986r1-nand-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7921e kmod-usb-net-rndis kmod-usb-serial-option
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += hf_m7986r1-nand-512m
define Device/hf_m7986r1-nand-auto
  DEVICE_VENDOR := HF
  DEVICE_MODEL := M7986R1 (NAND)
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7986a-hf-m7986r1-nand-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7921e kmod-usb-net-rndis kmod-usb-serial-option
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += hf_m7986r1-nand-auto
define Device/honor_fur-602
  DEVICE_VENDOR := Honor
  DEVICE_MODEL := FUR-602
  DEVICE_DTS := mt7981b-honor-fur-602
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += honor_fur-602

define Device/huasifei_wh3000-emmc
  DEVICE_VENDOR := Huasifei
  DEVICE_MODEL := WH3000 eMMC
  DEVICE_DTS := mt7981b-huasifei-wh3000-emmc
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  SUPPORTED_DEVICES += huasifei,wh3000
endef
TARGET_DEVICES += huasifei_wh3000-emmc

define Device/huasifei_wh3000-pro
  DEVICE_VENDOR := Huasifei
  DEVICE_MODEL := WH3000 Pro
  DEVICE_DTS := mt7981b-huasifei-wh3000-pro
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-hwmon-pwmfan kmod-usb3 f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += huasifei_wh3000-pro

define Device/huasifei_wh3000r-nand
  DEVICE_VENDOR := Huasifei
  DEVICE_MODEL := WH3000R
  DEVICE_VARIANT := NAND
  DEVICE_DTS := mt7981b-huasifei-wh3000r-nand
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 231936k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 automount
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += huasifei_wh3000r-nand

define Device/huasifei_ws3006
  DEVICE_VENDOR := Huasifei
  DEVICE_MODEL := WS3006
  DEVICE_DTS := mt7981b-huasifei-ws3006
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 112640k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += huasifei_ws3006

define Device/huasifei_ws3006-large
  DEVICE_VENDOR := Huasifei
  DEVICE_MODEL := WS3006 (Large Flash)
  DEVICE_DTS := mt7981b-huasifei-ws3006-large
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += huasifei_ws3006-large

define Device/huasifei_ws3009
  DEVICE_VENDOR := Huasifei
  DEVICE_MODEL := WS3009
  DEVICE_DTS := mt7981b-huasifei-ws3009
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 112640k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += huasifei_ws3009

define Device/huasifei_ws3009-large
  DEVICE_VENDOR := Huasifei
  DEVICE_MODEL := WS3009 (Large Flash)
  DEVICE_DTS := mt7981b-huasifei-ws3009-large
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += huasifei_ws3009-large

define Device/ikq_ikq6000
  DEVICE_VENDOR := IKQ
  DEVICE_MODEL := IKQ6000
  DEVICE_DTS := mt7986a-ikq6000
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 109568k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
endef
TARGET_DEVICES += ikq_ikq6000

define Device/imou_lc-hx3001
  DEVICE_VENDOR := IMOU
  DEVICE_MODEL := LC-HX3001
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-imou-lc-hx3001
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 117248k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += imou_lc-hx3001

define Device/imou_lc-hx3001-256m
  DEVICE_VENDOR := IMOU
  DEVICE_MODEL := LC-HX3001
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-imou-lc-hx3001-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += imou_lc-hx3001-256m
define Device/imou_lc-hx3001-512m
  DEVICE_VENDOR := IMOU
  DEVICE_MODEL := LC-HX3001
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-imou-lc-hx3001-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += imou_lc-hx3001-512m
define Device/imou_lc-hx3001-auto
  DEVICE_VENDOR := IMOU
  DEVICE_MODEL := LC-HX3001
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-imou-lc-hx3001-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += imou_lc-hx3001-auto
define Device/jcg_q30-pro
  DEVICE_VENDOR := JCG
  DEVICE_MODEL := Q30 PRO
  DEVICE_VARIANT := NAND 128M
  DEVICE_DTS := mt7981b-jcg-q30-pro
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += jcg_q30-pro

define Device/jcg_q30-pro-auto
  DEVICE_VENDOR := JCG
  DEVICE_MODEL := Q30 PRO
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-jcg-q30-pro-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += jcg_q30-pro-auto
define Device/jcg_q30-pro-256m
  DEVICE_VENDOR := JCG
  DEVICE_MODEL := Q30 PRO
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-jcg-q30-pro-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 240128k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += jcg_q30-pro-256m

define Device/jcg_q30-pro-512m
  DEVICE_VENDOR := JCG
  DEVICE_MODEL := Q30 PRO
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-jcg-q30-pro-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 485888k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += jcg_q30-pro-512m

define Device/jdcloud_re-cs-05
  DEVICE_VENDOR := JDCloud
  DEVICE_MODEL := AX6000
  DEVICE_DTS := mt7986a-jdcloud-re-cs-05
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := e2fsprogs f2fsck mkf2fs kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += jdcloud_re-cs-05

define Device/jdcloud_re-cp-03
  DEVICE_VENDOR := JDCloud
  DEVICE_MODEL := RE-CP-03
  DEVICE_DTS := mt7986a-jdcloud-re-cp-03
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware kmod-usb3 f2fsck mkf2fs
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += jdcloud_re-cp-03

define Device/konka_komi-a31
  DEVICE_VENDOR := KONKA
  DEVICE_MODEL := KOMI A31
  DEVICE_VARIANT := NAND (factory)
  DEVICE_ALT0_VENDOR := E-life
  DEVICE_ALT0_MODEL := ETR631-T
  DEVICE_ALT1_VENDOR := E-life
  DEVICE_ALT1_MODEL := ETR635-U
  DEVICE_DTS := mt7981b-konka-komi-a31
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += konka_komi-a31

define Device/konka_komi-a31-256m
  DEVICE_VENDOR := KONKA
  DEVICE_MODEL := KOMI A31
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-konka-komi-a31-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += konka_komi-a31-256m
define Device/konka_komi-a31-512m
  DEVICE_VENDOR := KONKA
  DEVICE_MODEL := KOMI A31
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-konka-komi-a31-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += konka_komi-a31-512m
define Device/konka_komi-a31-auto
  DEVICE_VENDOR := KONKA
  DEVICE_MODEL := KOMI A31
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-konka-komi-a31-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += konka_komi-a31-auto
define Device/livinet_li320
  DEVICE_VENDOR := Livinet
  DEVICE_MODEL := Li320
  DEVICE_DTS := mt7981b-livinet-li320
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  SUPPORTED_DEVICES += mediatek,mt7981-spim-snand-gsw-rfb
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += livinet_li320

define Device/livinet_zr-3020
  DEVICE_VENDOR := Livinet
  DEVICE_MODEL := ZR-3020
  DEVICE_DTS := mt7981b-livinet-zr-3020
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += livinet_zr-3020

define Device/mediatek_mt7988a-rfb
  DEVICE_VENDOR := MediaTek
  DEVICE_MODEL := MT7988A rfb
  DEVICE_DTS := mt7988a-rfb
  DEVICE_DTS_OVERLAY:= \
	mt7988a-rfb-emmc \
	mt7988a-rfb-sd \
	mt7988a-rfb-snfi-nand \
	mt7988a-rfb-spim-nand \
	mt7988a-rfb-spim-nor \
	mt7988a-rfb-eth1-aqr \
	mt7988a-rfb-eth1-i2p5g-phy \
	mt7988a-rfb-eth1-mxl \
	mt7988a-rfb-eth1-sfp \
	mt7988a-rfb-eth2-aqr \
	mt7988a-rfb-eth2-mxl \
	mt7988a-rfb-eth2-sfp
  DEVICE_DTS_DIR := $(DTS_DIR)/
  DEVICE_DTC_FLAGS := --pad 4096
  DEVICE_DTS_LOADADDR := 0x45f00000
  DEVICE_PACKAGES := mt7988-2p5g-phy-firmware kmod-sfp kmod-phy-aquantia
  KERNEL_LOADADDR := 0x46000000
  KERNEL := kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  KERNEL_INITRAMFS_SUFFIX := .itb
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := $$(shell expr 64 + $$(CONFIG_TARGET_ROOTFS_PARTSIZE))m
  IMAGES := sysupgrade.itb
  IMAGE/sysupgrade.itb := append-kernel | fit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb external-with-rootfs | pad-rootfs | append-metadata
  ARTIFACTS := \
	       emmc-gpt.bin emmc-preloader.bin emmc-bl31-uboot.fip \
	       nor-preloader.bin nor-bl31-uboot.fip \
	       sdcard.img.gz \
	       snand-preloader.bin snand-bl31-uboot.fip
  ARTIFACT/emmc-gpt.bin		:= mt798x-gpt emmc
  ARTIFACT/emmc-preloader.bin	:= mt7988-bl2 emmc-comb
  ARTIFACT/emmc-bl31-uboot.fip	:= mt7988-bl31-uboot rfb-emmc
  ARTIFACT/nor-preloader.bin	:= mt7988-bl2 nor-comb
  ARTIFACT/nor-bl31-uboot.fip	:= mt7988-bl31-uboot rfb-nor
  ARTIFACT/snand-preloader.bin	:= mt7988-bl2 spim-nand-comb
  ARTIFACT/snand-bl31-uboot.fip	:= mt7988-bl31-uboot rfb-snand
  ARTIFACT/sdcard.img.gz	:= mt798x-gpt sdmmc |\
				   pad-to 17k | mt7988-bl2 sdmmc-comb |\
				   pad-to 6656k | mt7988-bl31-uboot rfb-sd |\
				$(if $(CONFIG_TARGET_ROOTFS_INITRAMFS),\
				   pad-to 12M | append-image-stage initramfs.itb | check-size 44m |\
				) \
				   pad-to 44M | mt7988-bl2 spim-nand-comb |\
				   pad-to 45M | mt7988-bl31-uboot rfb-snand |\
				   pad-to 51M | mt7988-bl2 nor-comb |\
				   pad-to 51M | mt7988-bl31-uboot rfb-nor |\
				   pad-to 55M | mt7988-bl2 emmc-comb |\
				   pad-to 56M | mt7988-bl31-uboot rfb-emmc |\
				   pad-to 62M | mt798x-gpt emmc |\
				$(if $(CONFIG_TARGET_ROOTFS_SQUASHFS),\
				   pad-to 64M | append-image squashfs-sysupgrade.itb | check-size |\
				) \
				  gzip
endef
TARGET_DEVICES += mediatek_mt7988a-rfb

define Device/mediatek_mt7986a-rfb
  DEVICE_VENDOR := MediaTek
  DEVICE_MODEL := MTK7986 rfba AP
  DEVICE_DTS := mt7986a-rfb-spim-nand
  DEVICE_DTS_DIR := $(DTS_DIR)/
  SUPPORTED_DEVICES := mediatek,mt7986a-rfb
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 65536k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += mediatek_mt7986a-rfb

define Device/mediatek_mt7986b-rfb
  DEVICE_VENDOR := MediaTek
  DEVICE_MODEL := MTK7986 rfbb AP
  DEVICE_DTS := mt7986b-rfb
  DEVICE_DTS_DIR := $(DTS_DIR)/
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  SUPPORTED_DEVICES := mediatek,mt7986b-rfb
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 65536k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += mediatek_mt7986b-rfb

define Device/netcore_n60
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7986a-netcore-n60
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 117248k
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60

define Device/netcore_n60-256m
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7986a-netcore-n60-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60-256m
define Device/netcore_n60-512m
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7986a-netcore-n60-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60-512m
define Device/netcore_n60-auto
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7986a-netcore-n60-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60-auto
define Device/netcore_n60-pro
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60 PRO
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7986a-netcore-n60-pro
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 117248k
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60-pro

define Device/netcore_n60-pro-256m
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60 PRO
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7986a-netcore-n60-pro-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60-pro-256m
define Device/netcore_n60-pro-512m
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60 PRO
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7986a-netcore-n60-pro-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60-pro-512m
define Device/netcore_n60-pro-auto
  DEVICE_VENDOR := Netcore
  DEVICE_MODEL := N60 PRO
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7986a-netcore-n60-pro-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += netcore_n60-pro-auto
define Device/newland_nl-wr8103
  DEVICE_VENDOR := Newland
  DEVICE_MODEL := NL-WR8103
  DEVICE_DTS := mt7981b-newland-nl-wr8103
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += newland_nl-wr8103

define Device/newland_nl-wr9103
  DEVICE_VENDOR := Newland
  DEVICE_MODEL := NL-WR9103
  DEVICE_DTS := mt7981b-newland-nl-wr9103
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += newland_nl-wr9103

define Device/nokia_ea0326gmp
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := EA0326GMP
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-nokia-ea0326gmp
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 88576k
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += nokia_ea0326gmp

define Device/nokia_ea0326gmp-256m
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := EA0326GMP
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-nokia-ea0326gmp-256m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 227840k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += nokia_ea0326gmp-256m
define Device/nokia_ea0326gmp-512m
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := EA0326GMP
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-nokia-ea0326gmp-512m
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 489984k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += nokia_ea0326gmp-512m
define Device/nokia_ea0326gmp-auto
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := EA0326GMP
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-nokia-ea0326gmp-auto
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE_SIZE := 489984k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += nokia_ea0326gmp-auto
define Device/openembed_som7981
  DEVICE_VENDOR := OpenEmbed
  DEVICE_MODEL := SOM7981
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7981b-openembed-som7981
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \
	kmod-crypto-hw-atmel kmod-eeprom-at24 kmod-gpio-beeper kmod-rtc-pcf8563 \
	kmod-usb-net-cdc-mbim kmod-usb-net-qmi-wwan kmod-usb-serial-option uqmi
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 244224k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += openembed_som7981

define Device/openembed_som7981-256m
  DEVICE_VENDOR := OpenEmbed
  DEVICE_MODEL := SOM7981
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7981b-openembed-som7981-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += openembed_som7981-256m
define Device/openembed_som7981-512m
  DEVICE_VENDOR := OpenEmbed
  DEVICE_MODEL := SOM7981
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7981b-openembed-som7981-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += openembed_som7981-512m
define Device/openembed_som7981-auto
  DEVICE_VENDOR := OpenEmbed
  DEVICE_MODEL := SOM7981
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7981b-openembed-som7981-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += openembed_som7981-auto
define Device/philips_hy3000
  DEVICE_VENDOR := Philips
  DEVICE_MODEL := HY3000
  DEVICE_DTS := mt7981b-philips-hy3000
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += philips_hy3000

define Device/qihoo_360t7
  DEVICE_VENDOR := Qihoo
  DEVICE_MODEL := 360T7
  DEVICE_DTS := mt7981b-qihoo-360t7
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += qihoo_360t7

define Device/ruijie_ew-6000gx-pro
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := EW-6000GX-PRO
  DEVICE_DTS := mt7986a-ruijie-ew-6000gx-pro
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_ew-6000gx-pro

define Device/ruijie_rg-x30e
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X30E
  DEVICE_DTS := mt7981b-ruijie-rg-x30e
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x30e

define Device/ruijie_rg-x30e-pro
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X30E
  DEVICE_VARIANT := Pro
  DEVICE_DTS := mt7981b-ruijie-rg-x30e-pro
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 114688k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x30e-pro

define Device/ruijie_rg-x60
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60
  DEVICE_DTS := mt7986a-ruijie-rg-x60
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  SUPPORTED_DEVICES += X60
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware kmod-phy-airoha-en8811h
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x60

define Device/ruijie_rg-x60-new
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60
  DEVICE_VARIANT := New
  DEVICE_DTS := mt7986a-ruijie-rg-x60-new
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x60-new

define Device/ruijie_rg-x60-pro
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60 Pro
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7986a-ruijie-rg-x60-pro
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x60-pro

define Device/ruijie_rg-x60-pro-256m
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60 Pro
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7986a-ruijie-rg-x60-pro-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 255488k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x60-pro-256m
define Device/ruijie_rg-x60-pro-512m
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60 Pro
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7986a-ruijie-rg-x60-pro-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 517632k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x60-pro-512m
define Device/ruijie_rg-x60-pro-auto
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60 Pro
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7986a-ruijie-rg-x60-pro-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE_SIZE := 517632k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x60-pro-auto
define Device/sl_3000-emmc
  DEVICE_VENDOR := SL
  DEVICE_MODEL := 3000
  DEVICE_VARIANT := eMMC
  DEVICE_DTS := mt7981b-sl-3000-emmc
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware automount coremark blkid blockdev fdisk f2fsck mkf2fs kmod-mmc
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += sl_3000-emmc

define Device/sn_r1
  DEVICE_VENDOR := SN
  DEVICE_MODEL := R1
  DEVICE_DTS := mt7981b-sn-r1
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += sn_r1

define Device/sn_r1-longlife
  DEVICE_VENDOR := SN
  DEVICE_MODEL := R1
  DEVICE_VARIANT := LongLife
  DEVICE_DTS := mt7981b-sn-r1-longlife
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += sn_r1-longlife

define Device/tenbay_wr3000k
  DEVICE_VENDOR := Tenbay
  DEVICE_MODEL := WR3000K
  DEVICE_DTS := mt7981b-tenbay-wr3000k
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += tenbay_wr3000k

define Device/tenbay_wr3000k-large
  DEVICE_VENDOR := Tenbay
  DEVICE_MODEL := WR3000K (Large Flash)
  DEVICE_DTS := mt7981b-tenbay-wr3000k-large
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += tenbay_wr3000k-large

define Device/tenda_be12-pro
  DEVICE_VENDOR := Tenda
  DEVICE_MODEL := BE12 Pro
  DEVICE_DTS := mt7987a-tenda-be12-pro
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := mt7987-2p5g-phy-firmware airoha-en8811h-firmware \
	kmod-phy-airoha-en8811h kmod-phy-mediatek-2p5g kmod-mt7992-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_LOADADDR := 0x40000000
  IMAGE/sysupgrade.bin := append-kernel | tenda-mkdualimageheader | sysupgrade-tar kernel=$$$$@ | append-metadata
endef
TARGET_DEVICES += tenda_be12-pro

define Device/tenda_be12-pro-large
  DEVICE_VENDOR := Tenda
  DEVICE_MODEL := BE12 Pro (Large Flash)
  DEVICE_DTS := mt7987a-tenda-be12-pro-large
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := mt7987-2p5g-phy-firmware airoha-en8811h-firmware \
	kmod-phy-airoha-en8811h kmod-phy-mediatek-2p5g kmod-mt7992-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_LOADADDR := 0x40000000
  IMAGE/sysupgrade.bin := append-kernel | tenda-mkdualimageheader | sysupgrade-tar kernel=$$$$@ | append-metadata
endef
TARGET_DEVICES += tenda_be12-pro-large

define Device/teralink_tl3020
  DEVICE_VENDOR := Teralink
  DEVICE_MODEL := TL3020
  DEVICE_DTS := mt7981b-teralink-tl3020
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += teralink_tl3020

define Device/tplink_tl-xdr4288
  DEVICE_MODEL := TL-XDR4288
  DEVICE_DTS := mt7986a-tplink-tl-xdr4288
  $(call Device/tplink_tl-common)
endef
TARGET_DEVICES += tplink_tl-xdr4288

define Device/tplink_tl-xdr6086
  DEVICE_MODEL := TL-XDR6086
  DEVICE_DTS := mt7986a-tplink-tl-xdr6086
  $(call Device/tplink_tl-common)
endef
TARGET_DEVICES += tplink_tl-xdr6086

define Device/tplink_tl-xdr6088
  DEVICE_MODEL := TL-XDR6088
  DEVICE_DTS := mt7986a-tplink-tl-xdr6088
  $(call Device/tplink_tl-common)
endef
TARGET_DEVICES += tplink_tl-xdr6088

define Device/tplink_tl-xtr8488
  DEVICE_MODEL := TL-XTR8488
  DEVICE_VARIANT := NAND (factory)
  DEVICE_DTS := mt7986a-tplink-tl-xtr8488
  DEVICE_PACKAGES += kmod-mt7915-firmware
  $(call Device/tplink_tl-common)
endef
TARGET_DEVICES += tplink_tl-xtr8488

define Device/tplink_tl-xtr8488-256m
  DEVICE_MODEL := TL-XTR8488
  DEVICE_VARIANT := NAND 256M
  DEVICE_DTS := mt7986a-tplink-tl-xtr8488-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES += kmod-mt7915-firmware
  IMAGE_SIZE := 256512k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += tplink_tl-xtr8488-256m
define Device/tplink_tl-xtr8488-512m
  DEVICE_MODEL := TL-XTR8488
  DEVICE_VARIANT := NAND 512M
  DEVICE_DTS := mt7986a-tplink-tl-xtr8488-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES += kmod-mt7915-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += tplink_tl-xtr8488-512m
define Device/tplink_tl-xtr8488-auto
  DEVICE_MODEL := TL-XTR8488
  DEVICE_VARIANT := NAND (auto)
  DEVICE_DTS := mt7986a-tplink-tl-xtr8488-auto
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES += kmod-mt7915-firmware
  IMAGE_SIZE := 518656k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += tplink_tl-xtr8488-auto
define Device/tplink_wma301
  DEVICE_VENDOR := TP-Link
  DEVICE_MODEL := WMA301
  DEVICE_VARIANT := stock layout
  DEVICE_DTS := mt7981b-tplink-wma301
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 65536k
  SUPPORTED_DEVICES += tplink,wma301
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += tplink_wma301

define Device/tplink_wma301-mod
  DEVICE_VENDOR := TP-Link
  DEVICE_MODEL := WMA301
  DEVICE_VARIANT := U-Boot mod
  DEVICE_DTS := mt7981b-tplink-wma301-ubootmod
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  SUPPORTED_DEVICES += tplink,wma301-ubootmod
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += tplink_wma301-mod

define Device/wirelesstag_zx7981pd
  DEVICE_VENDOR := Wireless-Tag
  DEVICE_MODEL := ZX7981PD
  DEVICE_DTS := mt7981b-wirelesstag-zx7981pd
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 51200k
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  DEVICE_ALT0_VENDOR := SmartPanle
  DEVICE_ALT0_MODEL := ZX7981PD
  DEVICE_DTS_LOADADDR := 0x44000000
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += wirelesstag_zx7981pd

define Device/wirelesstag_zx7981pd-mod
  DEVICE_VENDOR := Wireless-Tag
  DEVICE_MODEL := ZX7981PD
  DEVICE_VARIANT := U-Boot mod
  DEVICE_DTS := mt7981b-wirelesstag-zx7981pd-ubootmod
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  SUPPORTED_DEVICES += wirelesstag,zx7981pd-ubootmod
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  DEVICE_ALT0_VENDOR := SmartPanle
  DEVICE_ALT0_MODEL := ZX7981PD
  DEVICE_ALT0_VARIANT := U-Boot mod
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += wirelesstag_zx7981pd-mod

define Device/xiaomi_mi-router-ax3000t
  DEVICE_VENDOR := Xiaomi
  DEVICE_MODEL := Mi Router AX3000T
  DEVICE_DTS := mt7981b-xiaomi-ax3000t
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += xiaomi_mi-router-ax3000t

define Device/xiaomi_mi-router-wr30u
  DEVICE_VENDOR := Xiaomi
  DEVICE_MODEL := Mi Router WR30U
  DEVICE_DTS := mt7981b-xiaomi-wr30u
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += xiaomi_mi-router-wr30u

define Device/xiaomi_redmi-router-ax6000
  DEVICE_VENDOR := Xiaomi
  DEVICE_MODEL := Redmi Router AX6000
  DEVICE_DTS := mt7986a-xiaomi-redmi-router-ax6000
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-leds-ws2812b kmod-mt7986-firmware mt7986-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += xiaomi_redmi-router-ax6000

define Device/zbtlink_zbt-z8103ax-c
  DEVICE_VENDOR := Zbtlink
  DEVICE_MODEL := Z8103AX-C
  DEVICE_DTS := mt7981b-zbtlink-zbt-z8103ax-c
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += zbtlink_zbt-z8103ax-c

define Device/zyxel_ex5700-telenor
  DEVICE_VENDOR := Zyxel
  DEVICE_MODEL := EX5700
  DEVICE_VARIANT := Telenor
  DEVICE_DTS := mt7986a-zyxel-ex5700-telenor
  DEVICE_DTS_DIR := ../dts
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += zyxel_ex5700-telenor
