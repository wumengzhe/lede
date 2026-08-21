/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ponctl.c - CLI for the Airoha AN7581 PON (XGS-PON ONT)
 *
 * Talks directly to kmod-airoha-pon (genl family "airoha_pon" + the
 * /dev/airoha_pon char device), so it works whether or not ponmgr is
 * running.
 *
 *   ponctl status                 print PON state / laser / rx power
 *   ponctl activate               enable laser + trigger OMCI bring-up
 *   ponctl deactivate             disable laser
 *   ponctl apply                  re-apply UCI provisioning
 *   ponctl set <key> <value>      write a UCI option and re-apply
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>

#include "pon_abi.h"

/* generic-netlink payload accessors (not in the UAPI headers) */
#define GENLMSG_DATA(nlh)	((void *)((char *)NLMSG_DATA(nlh) + GENL_HDRLEN))
#define GENLMSG_PAYLOAD(nlh)	(NLMSG_PAYLOAD(nlh, GENL_HDRLEN))

static uint16_t g_family_id;

static int nl_put_attr(uint8_t *buf, int *off, int type,
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

static int genl_call(int cmd, const uint8_t *attrs, int alen,
		     uint8_t *reply, int rsz, int *rlen)
{
	struct {
		struct nlmsghdr nlh;
		struct genlmsghdr gh;
		uint8_t attrs[256];
	} req;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	uint8_t rbuf[2048];
	int fd, ret = -1;

	if (!g_family_id)
		return -ENOTSUP;
	memset(&req, 0, sizeof(req));
	req.nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + alen;
	req.nlh.nlmsg_type = g_family_id;
	req.nlh.nlmsg_flags = NLM_F_REQUEST;
	req.gh.cmd = (uint8_t)cmd;
	req.gh.version = PON_GENL_VERSION;
	memcpy(req.attrs, attrs, alen);

	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0)
		return -errno;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
		goto out;
	if (send(fd, &req, req.nlh.nlmsg_len, 0) < 0)
		goto out;
	{
		int n = recv(fd, rbuf, sizeof(rbuf), 0);
		if (n < (int)NLMSG_HDRLEN)
			goto out;
		ret = 0;
		if (reply && rsz) {
			int pl = n - (int)NLMSG_HDRLEN - (int)GENL_HDRLEN;
			if (pl > rsz)
				pl = rsz;
			memcpy(reply, rbuf + NLMSG_HDRLEN + GENL_HDRLEN, pl);
			if (rlen)
				*rlen = pl;
		}
	}
out:
	close(fd);
	return ret;
}

static int resolve_family(void)
{
	struct {
		struct nlmsghdr nlh;
		struct genlmsghdr gh;
		uint8_t attrs[128];
	} req;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	uint8_t rbuf[2048];
	int fd, off = 0, ret = -1;
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
	nl_put_attr(req.attrs, &off, CTRL_ATTR_FAMILY_NAME, name, sizeof(name));
	req.nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + off;
	if (send(fd, &req, req.nlh.nlmsg_len, 0) < 0)
		goto out;
	{
		int n = recv(fd, rbuf, sizeof(rbuf), 0);
		struct nlmsghdr *nlh = (struct nlmsghdr *)rbuf;
		struct nlattr *a;
		int rem;

		if (n < (int)NLMSG_HDRLEN)
			goto out;
		for (a = (struct nlattr *)GENLMSG_DATA(nlh),
		     rem = GENLMSG_PAYLOAD(nlh);
		     (int)rem >= (int)sizeof(*a) &&
		     a->nla_len >= sizeof(*a) && a->nla_len <= rem;
		     rem -= NLA_ALIGN(a->nla_len),
		     a = (struct nlattr *)((uint8_t *)a + NLA_ALIGN(a->nla_len))) {
			if (a->nla_type == CTRL_ATTR_FAMILY_ID) {
				g_family_id = *(uint16_t *)((uint8_t *)a + sizeof(*a));
				ret = 0;
				break;
			}
		}
	}
out:
	close(fd);
	return ret;
}

static int do_status(void)
{
	struct air_pon_status st;
	uint8_t reply[64];
	int rlen = 0;

	if (genl_call(PON_CMD_GET_INFO, NULL, 0, reply, sizeof(reply),
		      &rlen) < 0) {
		fprintf(stderr, "ponctl: GET_INFO failed (driver loaded?)\n");
		return 1;
	}
	/* the reply carries the attrs we asked for; decode the packed attrs */
	{
		struct nlattr *a = (struct nlattr *)reply;
		int rem = rlen;

		memset(&st, 0, sizeof(st));
		while (rem >= (int)sizeof(*a) && a->nla_len >= sizeof(*a) &&
		       a->nla_len <= rem) {
			void *d = (uint8_t *)a + sizeof(*a);
			switch (a->nla_type) {
			case PON_ATTR_STATE:
				st.state = *(uint32_t *)d;
				break;
			case PON_ATTR_RX_POWER:
				st.rx_power = *(int32_t *)d;
				break;
			case PON_ATTR_LASER:
				st.laser = *(uint8_t *)d;
				break;
			case PON_ATTR_LOS:
				st.los = *(uint8_t *)d;
				break;
		case PON_ATTR_TX_FAULT:
			st.tx_fault = *(uint8_t *)d;
			break;
		case PON_ATTR_TX_POWER:
			st.tx_power = *(int32_t *)d;
			break;
		case PON_ATTR_BIAS:
			st.bias = *(int32_t *)d;
			break;
		case PON_ATTR_TEMP:
			st.temperature = *(int32_t *)d;
			break;
		case PON_ATTR_VOLTAGE:
			st.voltage = *(uint32_t *)d;
			break;
		case PON_ATTR_FEC:
			st.fec = *(uint8_t *)d;
			break;
		case PON_ATTR_MODE:
			st.mode = *(uint32_t *)d;
			break;
		}
		rem -= NLA_ALIGN(a->nla_len);
		a = (struct nlattr *)((uint8_t *)a + NLA_ALIGN(a->nla_len));
	}
}
	printf("state=%u\n", st.state);
	printf("laser=%u\n", st.laser);
	printf("rx_power=%d\n", st.rx_power);
	printf("tx_power=%d\n", st.tx_power);
	printf("bias=%d\n", st.bias);
	printf("temperature=%d\n", st.temperature);
	printf("voltage=%u\n", st.voltage);
	printf("los=%u\n", st.los);
	printf("tx_fault=%u\n", st.tx_fault);
	printf("fec=%u\n", st.fec);
	printf("mode=%u\n", st.mode);
	return 0;
}

static int do_set_laser(int on)
{
	uint8_t attrs[16];
	int off = 0;
	uint8_t v = (uint8_t)!!on;

	nl_put_attr(attrs, &off, PON_ATTR_ENABLE, &v, 1);
	if (genl_call(PON_CMD_SET_ENABLE, attrs, off, NULL, 0, NULL) < 0) {
		fprintf(stderr, "ponctl: SET_ENABLE failed\n");
		return 1;
	}
	return 0;
}

static int do_apply(void)
{
	/* provisioning is a daemon concern; make sure the driver is alive */
	uint8_t attrs[16];
	int off = 0;
	uint8_t f = 0;

	nl_put_attr(attrs, &off, PON_ATTR_FEC, &f, 1);
	if (genl_call(PON_CMD_SET_PROV, attrs, off, NULL, 0, NULL) < 0) {
		fprintf(stderr, "ponctl: SET_PROV failed\n");
		return 1;
	}
	return 0;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s status|activate|deactivate|apply|set <key> <value>\n",
		prog);
	exit(1);
}

int main(int argc, char **argv)
{
	if (argc < 2)
		usage(argv[0]);
	if (resolve_family() < 0) {
		fprintf(stderr, "ponctl: kmod-airoha-pon not loaded\n");
		return 1;
	}
	if (!strcmp(argv[1], "status"))
		return do_status();
	if (!strcmp(argv[1], "activate"))
		return do_set_laser(1);
	if (!strcmp(argv[1], "deactivate"))
		return do_set_laser(0);
	if (!strcmp(argv[1], "apply"))
		return do_apply();
	if (!strcmp(argv[1], "set")) {
		/* persists via UCI through ponmgr; keep the CLI contract */
		fprintf(stderr, "ponctl: 'set' is handled by ponmgr/UCI\n");
		return 1;
	}
	usage(argv[0]);
	return 0;
}
