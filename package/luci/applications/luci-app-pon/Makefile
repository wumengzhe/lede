# SPDX-License-Identifier: Apache-2.0
#
# luci-app-pon - web UI for the Airoha AN7581 PON (XGS-PON ONT)
#
# Requires the luci feed (./scripts/feeds update luci && ./scripts/feeds
# install luci) so this Makefile can include ../../luci.mk.

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Airoha AN7581 PON status and control
LUCI_DEPENDS:=+pon-manager
LUCI_PKGARCH:=all

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
