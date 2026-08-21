/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ponmgr.h - Airoha AN7581 PON (XGS-PON ONT) management daemon
 *
 * Talks to kmod-airoha-pon over:
 *   - generic-netlink family "airoha_pon" (state / laser / provisioning)
 *   - /dev/airoha_pon char device (raw OMCI G.988 frames)
 * and to netifd via the `pon` protocol (pon.sh). Configuration comes from
 * UCI (/etc/config/pon).
 */
#ifndef PONMGR_H
#define PONMGR_H

#include <stdint.h>

#include "pon_abi.h"

/* unix control socket (ponctl) */
#define PONMGR_SOCK		"/var/run/ponmgr.sock"

extern uint16_t g_family_id;	/* resolved genl family id (0 = not resolved) */
extern int g_omci_fd;		/* /dev/airoha_pon, -1 = no frame plane */

/* genl helpers */
int genl_pon_cmd(int cmd, const uint8_t *attrs, int attrs_len,
		 uint8_t *reply, int reply_sz, int *reply_len);
int nl_put_attr_inline(uint8_t *buf, int *off, int type,
		       const void *data, int len);

/* UCI */
int uci_get_str(struct uci_section *s, const char *opt,
		char *out, size_t outsz, const char *def);
int uci_get_int(struct uci_section *s, const char *opt, int def);

#endif /* PONMGR_H */
