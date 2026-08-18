include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-policyroute
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=wumengzhe
PKG_LICENSE:=MIT

LUCI_TITLE:=Policy Route (per-device / per-port exit, anti-association)
LUCI_DESCRIPTION:=Source-based policy routing. Route traffic by device MAC/IP/host \
	or destination port to any egress (multi-WAN, WireGuard, OpenVPN, passwall/openclash utun). \
	Exit-agnostic: no proxy required.
LUCI_DEPENDS:=+nftables +ip-full +kmod-nft-core

include $(TOPDIR)/feeds/luci/luci.mk

# OpenWrt 22.03+ uses nftables by default; this package relies on `nft` + `ip rule`.
PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_nftables \
	CONFIG_PACKAGE_ip-full

$(eval $(call BuildPackage,$(PKG_NAME)))
