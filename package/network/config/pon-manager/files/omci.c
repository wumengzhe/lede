/* SPDX-License-Identifier: GPL-2.0 */
/*
 * omci.c - minimal G.988 (OMCI) message codec for ponmgr
 */
#include <stdio.h>
#include <string.h>

#include "omci.h"

static void put_be16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)(v >> 8);
	p[1] = (uint8_t)v;
}

static uint16_t get_be16(const uint8_t *p)
{
	return (uint16_t)((p[0] << 8) | p[1]);
}

int omci_build(uint8_t *buf, size_t size, uint16_t tid, uint8_t mt,
	       uint16_t me_class, uint16_t me_inst,
	       const void *payload, size_t payload_len)
{
	size_t off;

	if (!buf || size < 8 + payload_len)
		return -1;

	off = 0;
	put_be16(buf + off, tid);	off += 2;
	buf[off++] = mt;
	buf[off++] = 0x0A;		/* device identifier (OMCI) */
	put_be16(buf + off, me_class);	off += 2;
	put_be16(buf + off, me_inst);	off += 2;
	if (payload_len) {
		memcpy(buf + off, payload, payload_len);
		off += payload_len;
	}
	return (int)off;
}

int omci_parse(const uint8_t *buf, size_t len, struct omci_msg *m)
{
	if (!buf || !m || len < 8)
		return -1;
	/* sanity: device identifier must be 0x0A for OMCI */
	if (buf[3] != 0x0A)
		return -1;

	memset(m, 0, sizeof(*m));
	m->type = buf[2];
	m->me_class = get_be16(buf + 4);
	m->me_inst = get_be16(buf + 6);
	m->body = (uint8_t *)(buf + 8);
	m->body_len = (int)(len - 8);
	return (int)len;
}
