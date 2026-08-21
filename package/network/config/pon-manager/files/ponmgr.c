/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ponmgr.c - Airoha AN7581 PON (XGS-PON ONT) management daemon
 *
 * Responsibilities:
 *   - genl management plane with kmod-airoha-pon (GET_INFO / SET_ENABLE /
 *     SET_PROV), resolving the "airoha_pon" family at startup
 *   - OMCI frame plane: opens /dev/airoha_pon and ships G.988 messages via
 *     AIR_PON_SEND_OMCI (in hal_backend=sim they are echoed back so the
 *     codec path is exercised end-to-end; on the real backend the driver
 *     reports -EOPNOTSUPP until the OMCI register protocol is ported)
 *   - RTNL link monitor on `pon0` (gdm2/pon_pcs data plane)
 *   - UCI configuration (/etc/config/pon)
 *   - unix control socket for ponctl (/var/run/ponmgr.sock)
 *
 * Build: gcc -o ponmgr ponmgr.c omci.c -luci -lubox -lubus -lblobmsg_json
 *        -ljson-c -lubox (see package Makefile).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <getopt.h>
#include <syslog.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>

#include <libubox/uloop.h>
#include <libubox/blobmsg.h>
#include <libubox/utils.h>
#include <libubus/ubus.h>
#include <uci.h>

#include "ponmgr.h"
#include "omci.h"

/* ------------------------------------------------------------------ */
/* globals                                                             */
/* ------------------------------------------------------------------ */

uint16_t g_family_id;
int g_omci_fd = -1;

static void set_laser(int on);

static struct uloop_fd omci_fd;
static struct uloop_fd rtnl_fd;
static struct uloop_fd ctl_fd;
static int ctl_sock;
static int g_active;		/* laser enabled */

/* ------------------------------------------------------------------ */
/* genl plumbing                                                       */
/* ------------------------------------------------------------------ */

static struct nlattr {
	uint16_t	nla_len;
	uint16_t	nla_type;
} __attribute__((packed));

int nl_put_attr_inline(uint8_t *buf, int *off, int type,
		       const void *data, int len)
{
	struct nlattr *a = (struct nlattr *)(buf + *off);
	int alen = sizeof(*a) + len;

	a->nla_type = (uint16_t)type;
	a->nla_len = (uint16_t)alen;
	memcpy(buf + *off + sizeof(*a), data, len);
	*off += alen;
	return 0;
}

/* Send one genl command and (optionally) collect the reply. */
int genl_pon_cmd(int cmd, const uint8_t *attrs, int attrs_len,
		 uint8_t *reply, int reply_sz, int *reply_len)
{
	struct {
		struct nlmsghdr nlh;
		struct genlmsghdr gh;
		uint8_t attrs[256];
	} req;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	uint8_t rbuf[2048];
	int fd, ret = -1, len = 0;

	if (!g_family_id)
		return -ENOTSUP;

	memset(&req, 0, sizeof(req));
	req.nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + attrs_len;
	req.nlh.nlmsg_type = g_family_id;
	req.nlh.nlmsg_flags = NLM_F_REQUEST;
	req.gh.cmd = (uint8_t)cmd;
	req.gh.version = PON_GENL_VERSION;
	memcpy(req.attrs, attrs, attrs_len);

	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0)
		return -errno;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
		goto out;
	if (send(fd, &req, req.nlh.nlmsg_len, 0) < 0)
		goto out;

	len = recv(fd, rbuf, sizeof(rbuf), 0);
	if (len < (int)NLMSG_HDRLEN)
		goto out;
	ret = 0;
	if (reply && reply_sz) {
		int pl = len - (int)NLMSG_HDRLEN - (int)GENL_HDRLEN;
		if (pl > reply_sz)
			pl = reply_sz;
		memcpy(reply, rbuf + NLMSG_HDRLEN + GENL_HDRLEN, pl);
		if (reply_len)
			*reply_len = pl;
	}
out:
	close(fd);
	return ret;
}

/* Resolve the "airoha_pon" genl family id via CTRL_CMD_GETFAMILY. */
static int genl_resolve_family(void)
{
	struct {
		struct nlmsghdr nlh;
		struct genlmsghdr gh;
		uint8_t attrs[128];
	} req;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	uint8_t rbuf[2048];
	int fd, ret = -1, off = 0;
	const char name[] = PON_GENL_NAME;

	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0)
		return -errno;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
		goto out;

	memset(&req, 0, sizeof(req));
	req.nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + 20 + sizeof(name);
	req.nlh.nlmsg_type = GENL_ID_CTRL;
	req.nlh.nlmsg_flags = NLM_F_REQUEST;
	req.gh.cmd = CTRL_CMD_GETFAMILY;
	req.gh.version = 1;
	nl_put_attr_inline(req.attrs, &off, CTRL_ATTR_FAMILY_NAME,
			   name, sizeof(name));
	req.nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + off;

	if (send(fd, &req, req.nlh.nlmsg_len, 0) < 0)
		goto out;
	{
		int len = recv(fd, rbuf, sizeof(rbuf), 0);
		struct nlmsghdr *nlh = (struct nlmsghdr *)rbuf;
		struct genlmsghdr *gh;
		struct nlattr *a;
		int rem;

		if (len < (int)NLMSG_HDRLEN)
			goto out;
		for (a = (struct nlattr *)GENLMSG_DATA(nlh),
		     rem = GENLMSG_PAYLOAD(nlh);
		     NLA_OK(a, rem); a = NLA_NEXT(a, rem)) {
			gh = (struct genlmsghdr *)GENLMSG_DATA(nlh);
			if (gh->cmd == CTRL_CMD_NEWFAMILY &&
			    a->nla_type == CTRL_ATTR_FAMILY_ID) {
				g_family_id = *(uint16_t *)NLA_DATA(a);
				ret = 0;
				break;
			}
		}
	}
out:
	close(fd);
	return ret;
}

/* ------------------------------------------------------------------ */
/* OMCI frame plane (char device /dev/airoha_pon)                      */
/* ------------------------------------------------------------------ */

/* Push one raw OMCI G.988 message to the PON MAC. */
static int omci_send(const uint8_t *msg, uint16_t len)
{
	struct air_pon_omci o;

	if (g_omci_fd < 0)
		return -1;
	if (len > AIR_PON_OMCI_MAX)
		len = AIR_PON_OMCI_MAX;
	memset(&o, 0, sizeof(o));
	o.len = len;
	memcpy(o.msg, msg, len);
	return ioctl(g_omci_fd, AIR_PON_SEND_OMCI, &o);
}

/* Read OMCI indications/alarms from the driver and decode them. */
static void omci_rx_cb(struct uloop_fd *fd, unsigned int events)
{
	uint8_t buf[AIR_PON_OMCI_MAX + 2];
	ssize_t n;
	struct omci_msg m;

	(void)events;
	n = read(fd->fd, buf, sizeof(buf));
	if (n < (ssize_t)(2 + 1))
		return;		/* empty / short */
	{
		uint16_t len = *(uint16_t *)buf;
		if ((ssize_t)len + 2 > n)
			len = (uint16_t)(n - 2);
		if (omci_parse(buf + 2, len, &m) > 0) {
			syslog(LOG_INFO,
				"pon: OMCI rx type=0x%02x me=%u inst=%u len=%u",
				m.type, m.me_class, m.me_inst, m.body_len);
		} else {
			syslog(LOG_DEBUG, "pon: OMCI rx %u bytes (not decoded)",
				len);
		}
	}
}

/* Send the ONT's first OMCI after activation (e.g. a MIB reset trigger /
 * an ONU2-G GET) so the OLT sees a live OMCI peer. */
static void omci_activate(void)
{
	uint8_t omci[64];
	int n;

	if (g_omci_fd < 0)
		return;
	n = omci_build(omci, sizeof(omci), 1, OMCI_MT_GET,
		       OMCI_ME_ONU2_G, 0, NULL, 0);
	if (n > 0) {
		omci_send(omci, (uint16_t)n);
		syslog(LOG_INFO, "pon: sent initial OMCI (%d bytes)", n);
	}
}

/* ------------------------------------------------------------------ */
/* UCI                                                                 */
/* ------------------------------------------------------------------ */

int uci_get_str(struct uci_section *s, const char *opt,
		char *out, size_t outsz, const char *def)
{
	const char *v = uci_lookup_option_string(s->package->ctx, s, opt);

	if (!v)
		v = def ? def : "";
	snprintf(out, outsz, "%s", v);
	return 0;
}

int uci_get_int(struct uci_section *s, const char *opt, int def)
{
	const char *v = uci_lookup_option_string(s->package->ctx, s, opt);

	if (!v)
		return def;
	return atoi(v);
}

/* Map UCI mode string to the kernel's sys_xpon_mode ABI. */
static int mode_from_uci(struct uci_section *s)
{
	char buf[16];

	uci_get_str(s, "mode", buf, sizeof(buf), "xgspon");
	if (!strncmp(buf, "xgpon", 5))
		return PON_MODE_XGPON;
	if (!strncmp(buf, "xgspon", 6))
		return PON_MODE_XGSPON;
	return PON_MODE_XGSPON;
}

/* Write the PON mode back to the kernel module parameter before activation.
 * The module must be loaded (it is, by the time ponmgr starts). */
static int set_kernel_mode(int mode)
{
	int fd;
	char buf[4];
	int n;

	fd = open("/sys/module/airoha_pon/parameters/sys_xpon_mode", O_WRONLY);
	if (fd < 0)
		return -1;
	n = snprintf(buf, sizeof(buf), "%d", mode);
	if (write(fd, buf, n) < 0) {
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

/* ------------------------------------------------------------------ */
/* provisioning (PON_CMD_SET_PROV)                                     */
/* ------------------------------------------------------------------ */

static int prov_apply(struct uci_section *s)
{
	uint8_t attrs[128];
	int off = 0;
	char buf[64];
	uint8_t f = 0;
	uint32_t am = 0;

	uci_get_str(s, "lo_id", buf, sizeof(buf), "");
	if (buf[0])
		nl_put_attr_inline(attrs, &off, PON_ATTR_ENABLE, &f, 1);

	f = (uint8_t)uci_get_int(s, "fec", 0);
	nl_put_attr_inline(attrs, &off, PON_ATTR_FEC, &f, 1);

	/* auth method + LOID/password/serial are conveyed to the OLT through
	 * OMCI; here we only persist them via the driver's provisioning slot */
	uci_get_str(s, "auth_method", buf, sizeof(buf), "loid");
	am = (buf[0] == 'p') ? 2 : (buf[0] == 's') ? 3 : 1; /* loid=1, pwd=2, sn=3 */
	nl_put_attr_inline(attrs, &off, PON_ATTR_AUTH_METHOD, &am, 4);

	/* ONU serial -> MAC PLOAM serial-number registers (VENDOR_ID/VS_SN).
	 * The kernel writes the first 8 bytes (vendor 4 + vs_sn 4) to the
	 * XGSPON MAC; the full 12-byte XGPON serial is carried by OMCI ONU-G. */
	uci_get_str(s, "serial_no", buf, sizeof(buf), "");
	if (buf[0]) {
		int sl = (int)strlen(buf);
		if (sl > PON_SERIAL_LEN)
			sl = PON_SERIAL_LEN;
		nl_put_attr_inline(attrs, &off, PON_ATTR_SERIAL, buf, sl);
	}

	{
		int mode = mode_from_uci(s);
		if (set_kernel_mode(mode) == 0)
			syslog(LOG_INFO, "pon: kernel xpon_mode set to %d", mode);
		else
			syslog(LOG_WARNING, "pon: failed to set kernel xpon_mode");
	}

	syslog(LOG_INFO, "pon: applying provisioning (%d attr bytes)", off);
	return genl_pon_cmd(PON_CMD_SET_PROV, attrs, off, NULL, 0, NULL);
}

/* ------------------------------------------------------------------ */
/* RTNL link monitor on the PON data-plane netdev (pon0)               */
/* ------------------------------------------------------------------ */

static void rtnl_cb(struct uloop_fd *fd, unsigned int events)
{
	uint8_t buf[4096];
	int n;

	(void)events;
	n = recv(fd->fd, buf, sizeof(buf), MSG_DONTWAIT);
	while (n >= (int)sizeof(struct nlmsghdr)) {
		struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
		struct ifinfomsg *ifi;

		if (nlh->nlmsg_type == RTM_NEWLINK) {
			ifi = NLMSG_DATA(nlh);
			if (ifi->ifi_index == if_nametoindex("pon0"))
				syslog(LOG_DEBUG, "pon: pon0 link %s",
				       (ifi->ifi_flags & IFF_UP) ? "up" : "down");
		}
		n -= nlh->nlmsg_len;
		memmove(buf, (uint8_t *)buf + nlh->nlmsg_len, (size_t)n);
	}
}

static int rtnl_open(void)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };

	rtnl_fd.fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
	if (rtnl_fd.fd < 0)
		return -1;
	sa.nl_groups = RTMGRP_LINK;
	if (bind(rtnl_fd.fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(rtnl_fd.fd);
		return -1;
	}
	rtnl_fd.cb = rtnl_cb;
	uloop_fd_add(&rtnl_fd, ULOOP_READ);
	return 0;
}

/* ------------------------------------------------------------------ */
/* unix control socket (ponctl)                                        */
/* ------------------------------------------------------------------ */

static void ctl_cb(struct uloop_fd *fd, unsigned int events)
{
	uint8_t buf[128];
	struct sockaddr_un peer;
	socklen_t plen = sizeof(peer);
	int n;

	(void)events;
	n = recvfrom(fd->fd, buf, sizeof(buf) - 1, 0,
		      (struct sockaddr *)&peer, &plen);
	if (n <= 0)
		return;
	buf[n] = 0;

	if (!strncmp((char *)buf, "status", 6)) {
		/* reply with the laser/active state, enough for ponctl */
		sendto(fd->fd, g_active ? "1" : "0", 1, 0,
		       (struct sockaddr *)&peer, plen);
	} else if (!strncmp((char *)buf, "activate", 8)) {
		set_laser(1);
		sendto(fd->fd, "ok", 2, 0, (struct sockaddr *)&peer, plen);
	} else if (!strncmp((char *)buf, "deactivate", 10)) {
		set_laser(0);
		sendto(fd->fd, "ok", 2, 0, (struct sockaddr *)&peer, plen);
	} else {
		sendto(fd->fd, "err", 3, 0, (struct sockaddr *)&peer, plen);
	}
}

static int ctl_open(void)
{
	struct sockaddr_un sa;

	unlink(PONMGR_SOCK);
	ctl_sock = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (ctl_sock < 0)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", PONMGR_SOCK);
	if (bind(ctl_sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(ctl_sock);
		return -1;
	}
	ctl_fd.fd = ctl_sock;
	ctl_fd.cb = ctl_cb;
	uloop_fd_add(&ctl_fd, ULOOP_READ);
	return 0;
}

/* ------------------------------------------------------------------ */
/* activation                                                          */
/* ------------------------------------------------------------------ */

static void set_laser(int on)
{
	uint8_t attrs[16];
	int off = 0;
	uint8_t v = (uint8_t)!!on;

	nl_put_attr_inline(attrs, &off, PON_ATTR_ENABLE, &v, 1);
	genl_pon_cmd(PON_CMD_SET_ENABLE, attrs, off, NULL, 0, NULL);
	g_active = !!on;
	if (on)
		omci_activate();
	syslog(LOG_INFO, "pon: laser %s", on ? "on" : "off");
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s [-d] [-h]\n"
		"  -d  daemonize\n"
		"  -h  this help\n", prog);
	exit(1);
}

int main(int argc, char **argv)
{
	int opt, daemonize = 0;
	struct uci_context *ctx;
	struct uci_package *pkg = NULL;
	struct uci_section *s = NULL;
	int enabled = 1;

	while ((opt = getopt(argc, argv, "dh")) != -1) {
		switch (opt) {
		case 'd':
			daemonize = 1;
			break;
		default:
			usage(argv[0]);
		}
	}

	openlog("ponmgr", LOG_PID | LOG_NDELAY, LOG_DAEMON);
	if (daemonize) {
		if (daemon(0, 0) < 0)
			syslog(LOG_ERR, "daemon: %m");
	}
	signal(SIGPIPE, SIG_IGN);

	if (genl_resolve_family() == 0)
		syslog(LOG_INFO, "pon: genl family '%s' id=%u",
		       PON_GENL_NAME, g_family_id);
	else
		syslog(LOG_WARNING, "pon: kmod-airoha-pon not loaded (genl)");

	g_omci_fd = open(AIR_PON_DEV, O_RDWR | O_NONBLOCK);
	if (g_omci_fd >= 0) {
		omci_fd.fd = g_omci_fd;
		omci_fd.cb = omci_rx_cb;
		uloop_fd_add(&omci_fd, ULOOP_READ);
		syslog(LOG_INFO, "pon: OMCI frame plane %s open",
		       AIR_PON_DEV);
	} else {
		syslog(LOG_WARNING, "pon: %s not available: %m",
		       AIR_PON_DEV);
	}

	ctx = uci_alloc_context();
	if (uci_load(ctx, "pon", &pkg) == 0)
		s = uci_lookup_section(ctx, pkg, "config", "pon");

	/* honour the UCI enabled flag; activation itself happens when the
	 * operator presses Activate (ponctl) or on link-up requests */
	enabled = uci_get_int(s, "enabled", 1);
	if (enabled)
		prov_apply(s);

	rtnl_open();
	ctl_open();

	syslog(LOG_INFO, "pon: ponmgr started (enabled=%d)", enabled);

	for (;;) {
		uloop_run();
		uloop_done();
		uloop_init();
	}
	uci_free_context(ctx);
	return 0;
}
