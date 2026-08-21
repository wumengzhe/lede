# SPDX-License-Identifier: Apache-2.0
#
# luci-app-pon - web UI for the Airoha AN7581 PON (XGS-PON ONT)
#
# This Makefile normally lives in the luci feed where 'include ../../luci.mk'
# resolves to the feed root. When placed directly under package/ (core tree,
# as here), luci.mk must be found from an installed luci feed instead.
# Probe order: local feed layout -> feed staged into package/feeds -> feed
# source dir. Requires the luci feed:
#   ./scripts/feeds update luci && ./scripts/feeds install luci

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Airoha AN7581 PON status and control
LUCI_DEPENDS:=+pon-manager
LUCI_PKGARCH:=all

ifneq ($(wildcard ../../luci.mk),)
include ../../luci.mk
else ifneq ($(wildcard $(TOPDIR)/package/feeds/luci/luci.mk),)
include $(TOPDIR)/package/feeds/luci/luci.mk
else ifneq ($(wildcard $(TOPDIR)/feeds/luci/luci.mk),)
include $(TOPDIR)/feeds/luci/luci.mk
else
$(error luci.mk not found - run './scripts/feeds update luci && ./scripts/feeds install luci' first)
endif

# call BuildPackage - OpenWrt buildroot signature
