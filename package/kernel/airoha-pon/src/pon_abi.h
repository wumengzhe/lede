/* SPDX-License-Identifier: GPL-2.0 */
/*
 * pon_abi.h - ABI shared between kmod-airoha-pon and pon-manager/ponctl
 *
 * Two planes:
 *   1. generic-netlink family "airoha_pon" - management state
 *      (laser on/off, LOS/TX-FAULT, provisioning, PON state O1..O5, RX power)
 *   2. char device /dev/airoha_pon - OMCI/GTC *frame* plane
 *      (SEND_OMCI ioctl pushes a raw OMCI G.988 message; read() drains
 *       indications/alarms; record = u16 len + payload)
 */
#ifndef PON_ABI_H
#define PON_ABI_H

#include <linux/types.h>

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
	PON_MODE_XGPON  = 1,   /* 10G down / 2.5G up (factory default for ZJ CMCC) */
	PON_MODE_XGSPON = 7,   /* 10G symmetric (upstream OpenWrt reference default) */
	PON_MODE_AUTO   = 0,   /* leave SoC default */
};

/* ------------------------------------------------------------------ */
/* char device frame plane                                             */
/* ------------------------------------------------------------------ */

#define AIR_PON_DEV		"/dev/airoha_pon"

#define AIR_PON_OMCI_MAX	2048

struct air_pon_omci {
	__u16 len;		/* payload length */
	__u8  msg[AIR_PON_OMCI_MAX];
} __packed;

struct air_pon_status {
	__u32 state;		/* enum pon_state */
	__u8  laser;		/* 1 = enabled */
	__s32 rx_power;		/* dBm * 100 */
	__u8  los;		/* 1 = loss of signal */
	__u8  tx_fault;		/* 1 = TX fault asserted */
	__u32 mode;		/* enum pon_mode, public ABI */
	__u8  fec;		/* 1 = FEC enabled */
	__s32 tx_power;		/* dBm * 100 */
	__s32 bias;		/* mA * 100 */
	__s32 temperature;	/* degC * 100 */
	__u32 voltage;		/* mV */
} __packed;

#define AIR_PON_IOCTL_BASE	0xC0

#define AIR_PON_SEND_OMCI	_IOW(AIR_PON_IOCTL_BASE, 1, struct air_pon_omci)
#define AIR_PON_GET_STATUS	_IOR(AIR_PON_IOCTL_BASE, 2, struct air_pon_status)
#define AIR_PON_SET_LASER	_IOW(AIR_PON_IOCTL_BASE, 3, __u8)
#define AIR_PON_GET_LASER	_IOR(AIR_PON_IOCTL_BASE, 4, __u8)

#endif /* PON_ABI_H */
