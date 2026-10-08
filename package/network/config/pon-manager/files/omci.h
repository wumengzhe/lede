/* SPDX-License-Identifier: GPL-2.0 */
/*
 * omci.h - minimal G.988 (OMCI) message codec for ponmgr
 *
 * Wire format (all multi-byte fields big-endian):
 *   TransactionId (2) | MessageType (1) | DeviceIdentifier (1, 0x0A)
 *   ME-Class (2) | ME-Instance (2) | ... payload ...
 *
 * MessageType: the two high bits carry the direction (0x00=request,
 * 0x80=response), the six low bits the command (GET=0x01, SET=0x02,
 * CREATE=0x04, DELETE=0x06, MIB_RESET=0x09, GET_NEXT=0x0B).
 */
#ifndef PON_OMCI_H
#define PON_OMCI_H

#include <stdint.h>

/* message types */
#define OMCI_MT_GET		0x01
#define OMCI_MT_SET		0x02
#define OMCI_MT_CREATE		0x04
#define OMCI_MT_DELETE		0x06
#define OMCI_MT_GET_RESPONSE	0x81
#define OMCI_MT_SET_RESPONSE	0x82
#define OMCI_MT_CREATE_RESPONSE	0x84
#define OMCI_MT_DELETE_RESPONSE	0x86
#define OMCI_MT_MIB_RESET	0x09
#define OMCI_MT_MIB_RESET_RESP	0x89
#define OMCI_MT_GET_NEXT	0x0B

/* well-known ME classes (G.988 table 4.2.1) */
#define OMCI_ME_ONU_G		2
#define OMCI_ME_ONU2_G		7
#define OMCI_ME_ANI_G		6
#define OMCI_ME_SW_IMAGE	7	/* alias kept for ONU2-G use */
#define OMCI_ME_IP_HOST_CFG	134
#define OMCI_ME_8021P_MAP	277

struct omci_msg {
	uint8_t	type;		/* message type (incl. response bit) */
	uint16_t me_class;
	uint16_t me_inst;
	uint8_t	*body;		/* points into the caller's buffer */
	int	body_len;
};

/* Build one OMCI request frame into buf (max size bytes). Returns the frame
 * length (> 0) or -1 on error. tid is the transaction id to stamp. */
int omci_build(uint8_t *buf, size_t size, uint16_t tid, uint8_t mt,
	       uint16_t me_class, uint16_t me_inst,
	       const void *payload, size_t payload_len);

/* Parse one OMCI frame (len bytes at buf, *excluding* any transport prefix)
 * into m. Returns bytes consumed (> 0) or -1 if it does not look like OMCI. */
int omci_parse(const uint8_t *buf, size_t len, struct omci_msg *m);

#endif /* PON_OMCI_H */
