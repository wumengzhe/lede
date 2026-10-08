/* SPDX-License-Identifier: GPL-2.0 */
/*
 * pon_abi.h - ABI shared between kmod-airoha-pon and pon-manager/ponctl
 *
 * This file is the AUTHORITATIVE userspace copy of the kernel ABI defined in
 * package/kernel/airoha-pon/src/pon_abi.h. The two MUST stay byte-for-byte in
 * sync: the genl attribute numbers and the air_pon_status layout are part of
 * the kernel<-userspace contract. Keep them identical.
 *
 * Two planes:
 *   1. generic-netlink family "airoha_pon" - management state
 *      (laser on/off, LOS/TX-FAULT, provisioning, PON state O1..O5, RX/TX
 *       power, bias, temperature, voltage, FEC, line mode)
 *   2. char device /dev/airoha_pon - OMCI/GTC *frame* plane
 *      (SEND_OMCI ioctl pushes a raw OMCI G.988 message; read() drains
 *       indications/alarms; record = u16 len + payload)
 */
#ifndef PON_ABI_H
#define PON_ABI_H

#include <stdint.h>

/* Length of the PON ONU serial number (see kernel pon_abi.h). */
#define PON_SERIAL_LEN		12

/* ------------------------------------------------------------------ */
/* netlink family                                                      */
/* ------------------------------------------------------------------ */

#define PON_GENL_NAME		"airoha_pon"
#define PON_GENL_VERSION	1

enum {
	PON_CMD_GET_INFO = 1,
	PON_CMD_SET_ENABLE,
	PON_CMD_SET_PROV,
};

enum {
	PON_ATTR_STATE = 1,
	PON_ATTR_RX_POWER,	/* s32, dBm * 100 */
	PON_ATTR_TX_POWER,	/* s32, dBm * 100 */
	PON_ATTR_BIAS,		/* s32, mA * 100 */
	PON_ATTR_TEMP,		/* s32, degC * 100 */
	PON_ATTR_VOLTAGE,	/* u32, mV */
	PON_ATTR_LASER,		/* u8 */
	PON_ATTR_LOS,		/* u8 */
	PON_ATTR_TX_FAULT,	/* u8 */
	PON_ATTR_ENABLE,	/* u8 */
	PON_ATTR_FEC,		/* u8 (provisioning) */
	PON_ATTR_MODE,		/* u32, enum pon_mode */
	PON_ATTR_AUTH_METHOD,	/* u32, big-endian serial (provisioning) */
	PON_ATTR_SERIAL,	/* binary, up to PON_SERIAL_LEN: ONU serial */
	PON_ATTR_MAX,
};

/* ITU-T G.984.3 ONT PON states */
enum pon_state {
	PON_STATE_NO_MODULE = 0,
	PON_STATE_O1_INIT,
	PON_STATE_O2_STANDBY,
	PON_STATE_O3_SERIAL_NUM,
	PON_STATE_O4_RANGING,
	PON_STATE_O5_OPERATION,
};

/* PON line mode as exposed through sysfs/module param.
 * These values match the upstream OpenWrt AN7581 reference UI where
 * sys_xpon_mode=7 reports as XGSPON. The underlying register encoding is
 * SoC-specific; the driver uses this enumeration for its public ABI. */
enum pon_mode {
	PON_MODE_XGPON  = 1,   /* 10G down / 2.5G up */
	PON_MODE_XGSPON = 7,   /* 10G symmetric */
	PON_MODE_AUTO   = 0,   /* leave SoC default */
};

/* ------------------------------------------------------------------ */
/* char device frame plane                                             */
/* ------------------------------------------------------------------ */

#define AIR_PON_DEV		"/dev/airoha_pon"

#define AIR_PON_OMCI_MAX	2048

struct air_pon_omci {
	uint16_t len;		/* payload length */
	uint8_t  msg[AIR_PON_OMCI_MAX];
} __attribute__((packed));

/* Layout MUST match the kernel's struct air_pon_status (see
 * package/kernel/airoha-pon/src/pon_abi.h). Field order and types are part
 * of the ABI. */
struct air_pon_status {
	uint32_t state;		/* enum pon_state */
	uint8_t  laser;		/* 1 = enabled */
	int32_t  rx_power;	/* dBm * 100 */
	uint8_t  los;		/* 1 = loss of signal */
	uint8_t  tx_fault;	/* 1 = TX fault asserted */
	uint32_t mode;		/* enum pon_mode, public ABI */
	uint8_t  fec;		/* 1 = FEC enabled */
	int32_t  tx_power;	/* dBm * 100 */
	int32_t  bias;		/* mA * 100 */
	int32_t  temperature;	/* degC * 100 */
	uint32_t voltage;	/* mV */
} __attribute__((packed));

#define AIR_PON_IOCTL_BASE	0xC0

#define AIR_PON_SEND_OMCI	_IOW(AIR_PON_IOCTL_BASE, 1, struct air_pon_omci)
#define AIR_PON_GET_STATUS	_IOR(AIR_PON_IOCTL_BASE, 2, struct air_pon_status)
#define AIR_PON_SET_LASER	_IOW(AIR_PON_IOCTL_BASE, 3, uint8_t)
#define AIR_PON_GET_LASER	_IOR(AIR_PON_IOCTL_BASE, 4, uint8_t)

#endif /* PON_ABI_H */
