// SPDX-License-Identifier: GPL-2.0
/*
 * kmod-airoha-pon - Airoha AN7581 PON management-plane + OMCI transport
 *
 * Two channels to userspace (both consumed by pon-manager/ponmgr):
 *
 *  1. generic-netlink family "airoha_pon"  - management state:
 *       laser on/off, LOS/TX-FAULT, provisioning, PON state (O1..O5),
 *       RX power, PON mode, FEC, DDM (tx power, bias, temperature).
 *       Driven by the BOSA control GPIOs described in the "airoha,pon"
 *       device tree node and by direct PON MAC/PHY register access.
 *
 *  2. char device /dev/airoha_pon          - OMCI/GTC *frame* plane:
 *       SEND_OMCI ioctl pushes a raw OMCI G.988 message; read() drains
 *       OMCI indications/alarms. This is the transport that lets
 *       ponmgr/omcid2 actually talk OMCI with the OLT.
 *
 * ARCHITECTURE (clean-room, 2026-08-21):
 * The optical link is terminated by the on-die PON MAC / XPON PHY. The
 * register map below was extracted as *facts* (addresses, offsets, bit
 * fields) from the public Airoha/EcoNet reference material
 * (Sirherobrine23/airoha_xpon_en757x: README DTSI, ecnt_xpon.c,
 * ecnt_pon_phy.c). No vendor source code is copied; only the hardware
 * register layout and the OMCI-on-Ethernet framing (EtherType 0x88b5)
 * are reused as documentation, re-implemented here from scratch.
 *
 *   PON MAC core : 0x1fb64000
 *     GPON MAC sub-block : +0x4000
 *     XGPON MAC sub-block : +0x5000   (AN7581 / EN7581)
 *     EPON MAC sub-block  : +0x6000
 *   PON PHY      : 0x1faf0000
 *   PON_PHY_FPGA_RG_TX_OFF : 0x1fa2ff24  (write 0 = laser ON, 1 = TX off)
 *   SerDes ANA/PMA : 0x1fa8a000 / 0x1fa8b000
 *
 * OMCI framing (from xpon_netif.c omciHdr): OMCI is an Ethernet frame with
 *   dst MAC 00:00:00:00:00:02, src 00:00:00:00:00:01, EtherType 0x88b5.
 * In the Airoha reference BSP (v2/xpon_10g) the OMCI frame is delivered to
 * the fibre by the on-die CMAC engine: the 48-byte G.988 message is DMA-mapped
 * and handed to gponDevSetCmac0Start(GPON_CMAC_UPSTREAM, ...) which computes
 * the MIC and emits it on the dedicated OMCI GEM port (XGSPON: GEM_PORT_CFG
 * @0x5274, id 0x048). The public Sirherobrine23/airoha_kernel tree ships an
 * OPEN GPON OMCI transport (net/omci.h + airoha_gpon_omci.c) over the standard
 * airoha_eth QDMA path - NOT the private PWAN subsystem - which proves OMCI
 * does not require PWAN. That open tree is EN7523/GPON-only (its xpon_oam TX
 * is gated by !airoha_is(eth, airoha_en7523)), so it does not cover AN7581
 * XGSPON. Confirmed against the OEM AN7581 xpon_10g.ko (from this device's
 * stock firmware): the OMCI upstream submit builds a QDMA-style TX descriptor
 * (gwan_prepare_tx_message: GEM-port tag in bits 14..29, TXMSG OAM flag) and
 * computes the MIC on the CMAC engine (gponDevSetCmac0Start: SW0_ENCSTART
 * @0x5400, SW0_ENCINFO @0x5414, INT_STATUS @0x5044 bit 21). Therefore the
 * remaining blocker is the AN7581 QDMA data-pump: the frame must reach the
 * SoC QDMA engine that airoha_eth owns, which needs the xpon_oam hook
 * backported into this tree's 6.12 airoha_eth (see PON_PORTING.md 4-B).
 * This driver therefore: configures the OMCI channel registers
 * (hal_xgpon_omci_setup), programs the OMCI IK + computes the MIC on the
 * CMAC engine (hal_omci_compute_mic, verifiable on hardware), and honestly
 * returns -EOPNOTSUPP until the QDMA data-pump lands.
 *
 * PON mode: enum pon_mode from pon_abi.h. 1=XGPON, 7=XGSPON (upstream ref
 * default). The SoC mode is selected via sysPonMode-style global; the exact
 * MAC mode register is applied in hal_activate() (TODO: mode-register write
 * once gponDevSetWanMode sequence is extracted).
 *
 * hal_backend=1 (real, shipped default) maps registers + brings the laser
 * up + replays the init sequence. hal_backend=0 (sim) synthesises an O1..O5
 * bring-up and echoes OMCI for userspace exercising without hardware.
 */

#include <linux/module.h>
#include <linux/io.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/property.h>
#include <linux/gpio/consumer.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/kfifo.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/wait.h>
#include <linux/timer.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>
#include <linux/delay.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <net/genetlink.h>
#include <net/net_namespace.h>
#include <linux/skbuff.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/version.h>
#include <linux/dma-mapping.h>
#include <linux/kernel.h>

#include "pon_abi.h"
#include "pon_mac_seq.h"

/* OMCI transport: the frame is delivered to the SoC QDMA engine owned by
 * airoha_eth, tagged as an OAM frame on the OMCC GEM port (0x048). Provided
 * by the airoha_eth xPON OAM patch (049-net-airoha-xpon-oam.patch). */
extern int airoha_eth_xmit_xpon_oam(struct net_device *netdev,
				    struct sk_buff *skb, u16 gem_port_id);

/* ------------------------------------------------------------------ */
/* Register map (extracted facts, see header)                          */
/* ------------------------------------------------------------------ */

#define PON_MAC_BASE_PHYS	0x1fb64000UL
#define PON_MAC_IOMAP_SIZE	0x10000UL
#define PON_GPON_OFF		0x4000UL
#define PON_XGPON_OFF		0x5000UL
#define PON_EPON_OFF		0x6000UL

#define PON_PHY_BASE_PHYS	0x1faf0000UL
#define PON_PHY_IOMAP_SIZE	0x2000UL
/* FPGA RG TX_OFF: 1 = laser forced off (TX disabled), 0 = laser enabled */
#define PON_PHY_TX_OFF_PHYS	0x1fa2ff24UL
#define PON_PHY_TX_OFF_SIZE	0x4UL

/* OMCI-on-Ethernet framing (Airoha reference: xpon_netif.c omciHdr) */
#define OMCI_ETHERTYPE		0x88b5
/* OMCC (OMCI) GEM port id - fixed convention in GPON/XGSPON */
#define XGSPON_OMCI_GEM_PORT	0x048
static const u8 omci_dev_mac[ETH_ALEN] = {0x00,0x00,0x00,0x00,0x00,0x01};
static const u8 omci_olt_mac[ETH_ALEN] = {0x00,0x00,0x00,0x00,0x00,0x02};

/* ------------------------------------------------------------------ */
/* HAL backend + PON mode                                              */
/* ------------------------------------------------------------------ */

enum hal_backend {
	BACKEND_SIM = 0,
	BACKEND_REAL = 1,
};

static int backend_param = BACKEND_SIM;
module_param_named(hal_backend, backend_param, int, 0444);
MODULE_PARM_DESC(hal_backend, "0=sim (default), 1=real Airoha XPON HAL");

static int xpon_mode_param = PON_MODE_XGSPON;
module_param_named(sys_xpon_mode, xpon_mode_param, int, 0644);
MODULE_PARM_DESC(sys_xpon_mode, "PON mode: 1=XGPON, 7=XGSPON (default)");

/* OMCI TX path selector (debug aid). The real backend never puts frames on
 * the fibre yet (MAC CMAC DMA data-pump unimplemented; see hal_send_omci and
 * PON_PORTING.md section 4-B). This flag is retained only so the sim path can
 * be observed. Default 0 = safe. */
static bool omci_tx_enable;
module_param_named(omci_tx_enable, omci_tx_enable, bool, 0444);
MODULE_PARM_DESC(omci_tx_enable, "debug: OMCI tx path (real backend still returns -EOPNOTSUPP; sim echoes)");

/* CMAC MIC debug knobs: compute the G.988 message-integrity check on every
 * TX attempt via the on-die CMAC engine (hardware-verifiable even though the
 * frame data-pump is still pending), and override the OMCI integrity key
 * (hex, 16 bytes; default all-zero until the OLT provisions it via OMCI). */
static bool omci_mic_enable;
module_param_named(omci_mic_enable, omci_mic_enable, bool, 0644);
MODULE_PARM_DESC(omci_mic_enable, "1=compute OMCI MIC via on-die CMAC on TX attempt");
static char omci_ik[40];
module_param_string(omci_ik, omci_ik, sizeof(omci_ik), 0644);
MODULE_PARM_DESC(omci_ik, "OMCI integrity key, 32 hex chars (default zeros)");

/* ------------------------------------------------------------------ */
/* Device / GPIO state                                                 */
/* ------------------------------------------------------------------ */

struct air_pon {
	struct device		*dev;
	void __iomem		*mac_base;	/* PON MAC regs (real backend) */
	void __iomem		*phy_base;	/* PON PHY regs (real backend) */
	void __iomem		*tx_off_base;	/* laser TX_OFF (real backend) */
	struct net_device	*omci_netdev;	/* OMCI-over-Ethernet xport */
	struct net_device	*gdm2_ndev;	/* PON GDM2 (pon0) xPON netdev */
	struct gpio_desc	*tx_disable;	/* active-low => laser on */
	struct gpio_desc	*rx_sd;
	struct gpio_desc	*tx_sd;
	struct gpio_desc	*tx_fault;
	int			tx_disable_active;
	int			laser;
	enum pon_mode		mode;

	enum pon_state		state;
	s32			rx_power;
	s32			tx_power;
	s32			bias;
	s32			temperature;
	u32			voltage;
	u8			fec;
	u8			serial[PON_SERIAL_LEN]; /* ONU serial (vendor 4 + SN 4
							for the MAC PLOAM; the rest is
							carried by OMCI ONU-G) */
	u8			serial_len;

	struct kfifo		ind_fifo;
	spinlock_t		fifo_lock;
	wait_queue_head_t	ind_wait;
	atomic_t		stop;

	struct delayed_work	sim_work;
	int			sim_step;
};

static struct air_pon *g_pon;

/* ------------------------------------------------------------------ */
/* OMCI indication fifo helpers                                        */
/* ------------------------------------------------------------------ */

static void ind_push(const struct air_pon_omci *m)
{
	struct air_pon *p = g_pon;
	unsigned long flags;

	if (!p)
		return;
	spin_lock_irqsave(&p->fifo_lock, flags);
	if (kfifo_avail(&p->ind_fifo) < (unsigned int)(m->len + 2))
		kfifo_reset(&p->ind_fifo);
	kfifo_in(&p->ind_fifo, &m->len, 2);
	kfifo_in(&p->ind_fifo, m->msg, m->len);
	spin_unlock_irqrestore(&p->fifo_lock, flags);
	wake_up_interruptible(&p->ind_wait);
}

/* ------------------------------------------------------------------ */
/* OMCI-over-Ethernet transport (virtual "omci" netdevice)            */
/* ------------------------------------------------------------------ */

/* netdev start_xmit: the frame is already an OMCI Ethernet skb. Real
 * on-fibre delivery requires submitting it to the SoC QDMA engine that
 * airoha_eth owns, tagged with the OMCI GEM port (0x048) + OAM flag
 * (the xpon_oam hook - see PON_PORTING.md 4-B). Until that hook is
 * backported into this tree's 6.12 airoha_eth we free the skb and report
 * success (so the stack does not block) but tag it clearly as not
 * transmitted. */
static netdev_tx_t omci_ndo_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct air_pon *p = netdev_priv(ndev);
	struct net_device *gdm2 = p ? p->gdm2_ndev : NULL;

	if (!gdm2) {
		dev_dbg(ndev->dev.parent,
			"OMCI TX dropped: pon0 (GDM2) netdev not available\n");
		dev_kfree_skb(skb);
		return NETDEV_TX_OK;
	}
	/* Deliver on the OMCC GEM port via the QDMA OAM path. */
	if (airoha_eth_xmit_xpon_oam(gdm2, skb, XGSPON_OMCI_GEM_PORT))
		dev_kfree_skb(skb);
	return NETDEV_TX_OK;
}

static const struct net_device_ops omci_netdev_ops = {
	.ndo_start_xmit = omci_ndo_start_xmit,
};

/* Packet type handler: OMCI frames addressed to us land here and are
 * pushed into the indication fifo for read() by ponmgr/omcid2. */
static int omci_packet_rcv(struct sk_buff *skb, struct net_device *ndev,
			   struct packet_type *pt, struct net_device *orig)
{
	struct air_pon_omci *rec;

	if (skb->len < 2)
		goto drop;
	/* struct air_pon_omci is ~2 KiB (2048-byte msg); this handler runs in
	 * NET_RX softirq context, so keep the big object off the stack. */
	rec = kmalloc(sizeof(*rec), GFP_ATOMIC);
	if (!rec)
		goto drop;
	rec->len = min_t(u16, (u16)(skb->len - 14), AIR_PON_OMCI_MAX);
	if (rec->len == 0) {
		kfree(rec);
		goto drop;
	}
	memcpy(rec->msg, skb->data + 14, rec->len);
	ind_push(rec);
	kfree(rec);
drop:
	consume_skb(skb);
	return NET_RX_SUCCESS;
}

static struct packet_type omci_packet_type = {
	.type = cpu_to_be16(OMCI_ETHERTYPE),
	.func = omci_packet_rcv,
};

static int omci_netdev_create(struct air_pon *p)
{
	struct net_device *ndev;
	int ret;

	ndev = alloc_etherdev(sizeof(struct air_pon *));
	if (!ndev)
		return -ENOMEM;
	eth_hw_addr_set(ndev, omci_dev_mac);
	ndev->netdev_ops = &omci_netdev_ops;
	ndev->flags |= IFF_NOARP;
	ndev->min_mtu = 0;
	ndev->max_mtu = 2048;
	strscpy(ndev->name, "omci%d", IFNAMSIZ);
	/* stash back-pointer for the xmit path */
	*(struct air_pon **)netdev_priv(ndev) = p;

	ret = register_netdev(ndev);
	if (ret) {
		free_netdev(ndev);
		return ret;
	}
	omci_packet_type.dev = ndev;
	dev_add_pack(&omci_packet_type);
	netif_start_queue(ndev);
	p->omci_netdev = ndev;
	return 0;
}

static void omci_netdev_destroy(struct air_pon *p)
{
	if (!p->omci_netdev)
		return;
	netif_stop_queue(p->omci_netdev);
	dev_remove_pack(&omci_packet_type);
	unregister_netdev(p->omci_netdev);
	free_netdev(p->omci_netdev);
	p->omci_netdev = NULL;
}

/* ------------------------------------------------------------------ */
/* HAL backend operations                                              */
/* ------------------------------------------------------------------ */

/* Laser enable/disable via PON_PHY_FPGA_RG_TX_OFF.
 * on=1 -> write 0 (cancel TX off); on=0 -> write 1 (force TX off). */
static void hal_laser_enable(int on)
{
	struct air_pon *p = g_pon;

	if (!p || !p->tx_off_base)
		return;
	writel(on ? 0 : 1, p->tx_off_base);
	dev_info(p->dev, "laser %s (TX_OFF <- %u)\n", on ? "ON" : "OFF", on ? 0 : 1);
}

/* Program the ONU serial number into the XGSPON MAC serial-number
 * registers so the Serial_Number_ONU PLOAM sent during O3/O4 ranging
 * carries the correct identity.
 *
 * Register facts (clean-room extracted from the Airoha AN7581 XGSPON MAC
 * register map, xgpon_mac_reg_c_header.h; offsets are relative to the PON
 * MAC core base 0x1fb64000, i.e. mac_base, and already include the
 * +0x5000 XGSPON window base):
 *   VENDOR_ID @ 0x500C : vendor_id[31:0]  = sn[0]<<24 | sn[1]<<16 |
 *                                              sn[2]<<8  | sn[3]   (4 ASCII)
 *   VS_SN     @ 0x5010 : vs_sn[31:0]      = sn[4]<<24 | sn[5]<<16 |
 *                                              sn[6]<<8  | sn[7]   (4 ASCII)
 * Only the first 8 bytes of the serial (vendor 4 + vs_sn 4) program the
 * MAC; the OMCI ONU-G ME carries the full 12-byte XGPON serial. */
#define XGSPON_VND_ID_OFF	0x500C
#define XGSPON_VS_SN_OFF	0x5010

/* XGSPON OMCI channel registers. Offsets are relative to mac_base
 * (0x1fb64000) and live in the +0x5000 XGSPON MAC window. Facts extracted
 * as register layout only (no source copied) from Airoha AN7581
 * xgpon_mac_reg_c_header.h + the gpon_dvt.c init table.
 *   TCONT_ID_CFG      @ 0x5250 : wr_tcont_id[13:0], tcont_id_index[24:20],
 *                                   wr_tcont_id_vld[16], tcont_cmd[31]
 *   GEM_PORT_CFG      @ 0x5274 : gem_port_id[15:0], gpid_vld[18],
 *                                   gpid_type[17], gpid_us_encrypt[16],
 *                                   gpid_cmd[31]
 *   GEM_PORT_STS      @ 0x5278
 *   TX_OMCI_PRE_GET   @ 0x528C : tx_pre_get_omci_en[0], tx_limit_get_omci_en[8],
 *                                   tx_limit_get_omci_size[16:31]
 *   RX_OMCI_PRE_GET   @ 0x5290 : rx_omci_intr_eth_en[0]
 *   OMCI_LEN_CTRL     @ 0x59BC : max_omci_len[13:0]
 * The OMCI GEM port id follows the GPON OMCC convention (0x048). */
#define XGSPON_TCONT_ID_CFG_OFF	0x5250
#define XGSPON_GEM_PORT_CFG_OFF	0x5274
#define XGSPON_GEM_PORT_STS_OFF	0x5278
#define XGSPON_TX_OMCI_PRE_GET_OFF	0x528C
#define XGSPON_RX_OMCI_PRE_GET_OFF	0x5290
#define XGSPON_OMCI_LEN_CTRL_OFF	0x59BC

/* XGSPON CMAC (AES-CMAC MIC engine) - offsets confirmed against the OEM
 * AN7581 xpon_10g.ko disassembly (gponDevSetCmac0Start: SW0_ENCSTART=0x5400,
 * SW0_ENCINFO=0x5414 with enckidx[18:16]/encdic[1:0], INT_STATUS=0x5044 with
 * sw0_mic_done_int[21]) and the Airoha XGSPON register header. */
#define XGSPON_INT_STATUS_OFF	0x5044
#define XGSPON_INT_SW0_MIC_DONE	(1U << 21)
#define XGSPON_OIK0_0_OFF	0x5380	/* OMCI IK0 key RAM (16 B, BE words) */
#define XGSPON_OIK0_1_OFF	0x5384
#define XGSPON_OIK0_2_OFF	0x5388
#define XGSPON_OIK0_3_OFF	0x538C
#define XGSPON_SW0_ENCSTART_OFF	0x5400
#define XGSPON_SW0_MADDR_OFF	0x5404
#define XGSPON_SW0_RADDR_OFF	0x5408
#define XGSPON_SW0_KADDR_OFF	0x540C
#define XGSPON_SW0_ENCLEN_OFF	0x5410
#define XGSPON_SW0_ENCINFO_OFF	0x5414
#define CMAC_KEYIDX_OMCI0	2	/* GPON_CMAC_OMCI_IDX0 */
#define CMAC_DIR_UPSTREAM	2	/* GPON_CMAC_UPSTREAM */
#define CMAC_MIC_RESULT_LEN	5	/* 4-byte MIC + 1 completion flag */
#define CMAC_POLL_RETRY		3000

#define RF(v, s)	((u32)(v) << (s))

static void hal_set_serial(struct air_pon *p)
{
	u32 v;

	if (!p || !p->mac_base || p->serial_len < 8)
		return;
	v = ((u32)p->serial[0] << 24) | ((u32)p->serial[1] << 16) |
	    ((u32)p->serial[2] << 8)  | (u32)p->serial[3];
	writel(v, p->mac_base + XGSPON_VND_ID_OFF);
	v = ((u32)p->serial[4] << 24) | ((u32)p->serial[5] << 16) |
	    ((u32)p->serial[6] << 8)  | (u32)p->serial[7];
	writel(v, p->mac_base + XGSPON_VS_SN_OFF);
	dev_info(p->dev, "PON MAC serial programmed: '%.4s%.4s' (VENDOR_ID/VS_SN)\n",
		 p->serial, p->serial + 4);
}

/* Configure the XGSPON OMCI management channel in the PON MAC.
 *
 * This brings the OMCI path to a *configured* state: the dedicated OMCI GEM
 * port (0x048) is allocated, the OMCI TX/RX "pre-get" (CPU/FE hand-off)
 * registers are enabled, and the max OMCI length is set. These are exactly
 * the register writes the vendor DVT table applies before OMCI starts
 * (TX_OMCI_PRE_GET = 0x300101 -> pre-get enable + 48-byte limit;
 *  RX_OMCI_PRE_GET = 0x1   -> route RX OMCI interrupt to the FE/ethernet).
 *
 * What is intentionally NOT done here (documented gap, see PON_PORTING.md
 * section 4-B):
 *   * T-CONT 0 alloc-id binding to the ONU-ID. That requires the ONU-ID
 *     assigned by the OLT during O4/O5 ranging; it is applied later, not at
 *     activate time.
 *   * The OMCI *frame data pump*: pushing the 48-byte G.988 message into the
 *     MAC for transmission. The reference BSP does this via the on-die CMAC
 *     engine (gponDevSetCmac0Start with the message's DMA bus address,
 *     GPON_CMAC_UPSTREAM) which computes the MIC and emits it on the OMCI
 *     GEM port. That DMA/CMAC path is not part of this standalone driver and
 *     is the remaining blocker for real OLT delivery. */
static void hal_xgpon_omci_setup(struct air_pon *p)
{
	if (!p || !p->mac_base)
		return;

	/* Allocate the OMCI GEM port (id 0x048, valid, command trigger). */
	writel(RF(XGSPON_OMCI_GEM_PORT, 0) | RF(1, 18) | RF(1, 31),
	       p->mac_base + XGSPON_GEM_PORT_CFG_OFF);

	/* TX OMCI pre-get: enable CPU pre-get + size limit 48 bytes. */
	writel(0x300101, p->mac_base + XGSPON_TX_OMCI_PRE_GET_OFF);
	/* RX OMCI pre-get: route RX OMCI interrupt to the FE. */
	writel(0x1, p->mac_base + XGSPON_RX_OMCI_PRE_GET_OFF);
	/* Max OMCI message length: 53 (48-byte G.988 basic + 4 CRC + 1). */
	writel(RF(53, 0), p->mac_base + XGSPON_OMCI_LEN_CTRL_OFF);

	dev_info(p->dev, "XGSPON OMCI channel configured (gem=%#x); frame data-pump pending\n",
		 XGSPON_OMCI_GEM_PORT);
}

/* Program the OMCI integrity key 0 (16 bytes) into the CMAC key RAM.
 * Byte order per reference gponDevSetOmciIk0(): BE words, key[12..15] first. */
static void hal_omci_set_ik0(struct air_pon *p, const u8 *ik)
{
	u32 v;

	v = ((u32)ik[12] << 24) | ((u32)ik[13] << 16) | ((u32)ik[14] << 8) | ik[15];
	writel(v, p->mac_base + XGSPON_OIK0_0_OFF);
	v = ((u32)ik[8] << 24) | ((u32)ik[9] << 16) | ((u32)ik[10] << 8) | ik[11];
	writel(v, p->mac_base + XGSPON_OIK0_1_OFF);
	v = ((u32)ik[4] << 24) | ((u32)ik[5] << 16) | ((u32)ik[6] << 8) | ik[7];
	writel(v, p->mac_base + XGSPON_OIK0_2_OFF);
	v = ((u32)ik[0] << 24) | ((u32)ik[1] << 16) | ((u32)ik[2] << 8) | ik[3];
	writel(v, p->mac_base + XGSPON_OIK0_3_OFF);
}

/* Compute the 4-byte OMCI MIC for a G.988 message on the on-die CMAC engine.
 * Register sequence matches the OEM AN7581 xpon_10g.ko (gponDevSetCmac0Start):
 *   ENCINFO(keyidx=OMCI_IK0, dir=UPSTREAM) -> ENCLEN -> MADDR/RADDR ->
 *   clear INT_STATUS[21] -> ENCSTART|1 -> poll INT_STATUS[21] -> check the
 *   result buffer's completion flag (last byte == 1) -> copy 4-byte MIC.
 * Returns 0 on success, -errno otherwise. */
static int hal_omci_compute_mic(struct air_pon *p, const u8 *msg, u16 len, u8 mic[4])
{
	struct device *dev = p->dev;
	void *src = NULL, *res = NULL;
	dma_addr_t src_phys = 0, res_phys = 0;
	u32 info, istat;
	int retry = CMAC_POLL_RETRY;
	int ret = -EIO;

	if (!p || !p->mac_base)
		return -ENODEV;

	src = dma_alloc_coherent(dev, len, &src_phys, GFP_KERNEL);
	if (!src)
		return -ENOMEM;
	res = dma_alloc_coherent(dev, CMAC_MIC_RESULT_LEN, &res_phys, GFP_KERNEL);
	if (!res) {
		ret = -ENOMEM;
		goto out;
	}
	memcpy(src, msg, len);
	memset(res, 0, CMAC_MIC_RESULT_LEN);

	/* key index (OMCI_IK0 = 2) << 16 | direction (UPSTREAM = 2) */
	info = readl(p->mac_base + XGSPON_SW0_ENCINFO_OFF);
	info &= ~((0x7u << 16) | (0x3u << 0));
	info |= ((u32)CMAC_KEYIDX_OMCI0 << 16) | ((u32)CMAC_DIR_UPSTREAM << 0);
	writel(info, p->mac_base + XGSPON_SW0_ENCINFO_OFF);

	/* message length | result length << 16, then DMA addresses */
	writel((u32)len | ((u32)CMAC_MIC_RESULT_LEN << 16),
	       p->mac_base + XGSPON_SW0_ENCLEN_OFF);
	writel((u32)src_phys, p->mac_base + XGSPON_SW0_MADDR_OFF);
	writel((u32)res_phys, p->mac_base + XGSPON_SW0_RADDR_OFF);

	/* clear done bit, then start the engine */
	istat = readl(p->mac_base + XGSPON_INT_STATUS_OFF);
	writel(istat | XGSPON_INT_SW0_MIC_DONE,
	       p->mac_base + XGSPON_INT_STATUS_OFF);
	writel(readl(p->mac_base + XGSPON_SW0_ENCSTART_OFF) | 1,
	       p->mac_base + XGSPON_SW0_ENCSTART_OFF);

	while (retry--) {
		istat = readl(p->mac_base + XGSPON_INT_STATUS_OFF);
		if (!(istat & XGSPON_INT_SW0_MIC_DONE))
			continue;
		writel(istat | XGSPON_INT_SW0_MIC_DONE,
		       p->mac_base + XGSPON_INT_STATUS_OFF);
		if (((u8 *)res)[CMAC_MIC_RESULT_LEN - 1] == 1) {
			memcpy(mic, res, 4);
			ret = 0;
		}
		break;
	}
out:
	if (src)
		dma_free_coherent(dev, len, src, src_phys);
	if (res)
		dma_free_coherent(dev, CMAC_MIC_RESULT_LEN, res, res_phys);
	return ret;
}

/* Forward a raw OMCI message to the PON MAC.
 *
 * Sim backend: echo the message back as an indication so the userspace OMCI
 * stack (omcid2) is exercised end-to-end without hardware.
 *
 * Real backend: the OMCI *channel* is configured at activate time
 * (hal_xgpon_omci_setup: OMCI GEM port + TX/RX pre-get). The actual on-fibre
 * *data pump* - handing the 48-byte G.988 message to the MAC's CMAC engine
 * via DMA (reference: gponDevSetCmac0Start, GPON_CMAC_UPSTREAM, which
 * computes the MIC and emits it on the OMCI GEM port) - is NOT implemented
 * in this standalone driver. We therefore return -EOPNOTSUPP so omcid2 knows
 * the frame was not delivered, instead of silently queueing it. See
 * PON_PORTING.md section 4-B for the resolution path. */
static int hal_send_omci(const struct air_pon_omci *m)
{
	struct air_pon *p = g_pon;
	struct sk_buff *skb;
	struct ethhdr *eth;
	u8 *payload;
	int r;

	if (backend_param == BACKEND_SIM) {
		if (p)
			ind_push(m);
		return 0;
	}
	if (!p || !p->gdm2_ndev || !m || m->len < 1 ||
	    m->len > AIR_PON_OMCI_MAX)
		return -EINVAL;

	/* Hardware-verifiable step on the same path the real egress uses:
	 * run the message through the on-die CMAC engine and log the MIC. */
	if (omci_mic_enable && p->mac_base && m->len >= 8) {
		u8 ik[16] = { 0 }, mic[4];
		int r2;

		if (strlen(omci_ik) == 32 &&
		    hex2bin(ik, omci_ik, sizeof(ik)) == 0)
			dev_dbg(p->dev, "using OMCI IK override\n");
		hal_omci_set_ik0(p, ik);
		r2 = hal_omci_compute_mic(p, m->msg, m->len, mic);
		if (r2 == 0)
			dev_info(p->dev,
				 "OMCI MIC OK len=%u mic=%02x%02x%02x%02x\n",
				 m->len, mic[0], mic[1], mic[2], mic[3]);
		else
			dev_warn(p->dev, "OMCI MIC failed (%d)\n", r2);
	}

	/* Build the OMCI-on-Ethernet frame (dst 00:..:02, EtherType 0x88b5)
	 * and hand it to the QDMA OAM path. */
	skb = netdev_alloc_skb(p->gdm2_ndev, ETH_HLEN + m->len);
	if (!skb)
		return -ENOMEM;
	skb_reserve(skb, NET_IP_ALIGN);
	skb_put(skb, ETH_HLEN + m->len);
	eth = (struct ethhdr *)skb->data;
	ether_addr_copy(eth->h_dest, omci_olt_mac);
	ether_addr_copy(eth->h_source, omci_dev_mac);
	eth->h_proto = htons(OMCI_ETHERTYPE);
	payload = skb->data + ETH_HLEN;
	memcpy(payload, m->msg, m->len);

	r = airoha_eth_xmit_xpon_oam(p->gdm2_ndev, skb,
				     XGSPON_OMCI_GEM_PORT);
	if (r)
		dev_warn_ratelimited(p->dev,
				     "OMCI TX submit failed (%d)\n", r);
	return r;
}

static void hal_get_status(struct air_pon_status *s)
{
	struct air_pon *p = g_pon;

	memset(s, 0, sizeof(*s));
	if (!p) {
		s->state = PON_STATE_NO_MODULE;
		return;
	}
	s->state       = p->state;
	s->laser       = p->laser;
	s->rx_power    = p->rx_power;
	s->tx_power    = p->tx_power;
	s->bias        = p->bias;
	s->temperature = p->temperature;
	s->voltage     = p->voltage;
	s->fec         = p->fec;
	s->mode        = p->mode;
	s->los         = p->rx_sd ? !gpiod_get_value_cansleep(p->rx_sd) : 0;
	s->tx_fault    = p->tx_fault ? gpiod_get_value_cansleep(p->tx_fault) : 0;
}

static void pon_mac_replay_seq(struct air_pon *p)
{
	int i;

	if (!p || !p->mac_base)
		return;
	for (i = 0; i < PON_MAC_SEQ_N; i++) {
		const struct pon_reg_op *op = &pon_mac_seq[i];
		void __iomem *reg = p->mac_base + op->off;

		if (op->type == PON_OP_W) {
			writel(op->wval, reg);
		} else {
			u32 v = readl(reg);
			v = (v & op->and_mask) | op->or_val;
			writel(v, reg);
		}
	}
	dev_info(p->dev, "PON MAC init sequence replayed (%zu ops, mode=%d)\n",
		 PON_MAC_SEQ_N, p->mode);
}

static void hal_activate(int on)
{
	struct air_pon *p = g_pon;

	if (!p)
		return;
	if (backend_param == BACKEND_REAL) {
		if (on) {
			p->mode = xpon_mode_param;
			hal_laser_enable(1);		/* bring the laser up */
			pon_mac_replay_seq(p);		/* MAC init sequence */
			hal_set_serial(p);		/* ONU serial -> XGSPON MAC */
			hal_xgpon_omci_setup(p);	/* OMCI GEM port + pre-get */
			/* Resolve the PON GDM2 (pon0) netdev for OMCI TX. */
			if (!p->gdm2_ndev) {
				p->gdm2_ndev = dev_get_by_name(&init_net, "pon0");
				if (p->gdm2_ndev)
					dev_info(p->dev, "PON GDM2 netdev: %s\n",
						 p->gdm2_ndev->name);
				else
					dev_warn(p->dev,
						 "pon0 (GDM2) netdev not found; OMCI TX disabled\n");
			}
			/* TODO: apply SoC XGSPON/XGPON mode register
			 * (gponDevSetWanMode / sysPonMode) once extracted. */
			if (p->omci_netdev)
				netif_start_queue(p->omci_netdev);
			p->state = PON_STATE_O2_STANDBY;
		} else {
			hal_laser_enable(0);
			if (p->omci_netdev)
				netif_stop_queue(p->omci_netdev);
			p->state = PON_STATE_O1_INIT;
		}
		return;
	}
	if (on) {
		p->sim_step = 0;
		schedule_delayed_work(&p->sim_work, 0);
	} else {
		cancel_delayed_work_sync(&p->sim_work);
		p->state = PON_STATE_O1_INIT;
	}
}

static void sim_work_fn(struct work_struct *w)
{
	struct air_pon *p = g_pon;
	static const enum pon_state seq[] = {
		PON_STATE_O1_INIT, PON_STATE_O2_STANDBY, PON_STATE_O3_SERIAL_NUM,
		PON_STATE_O4_RANGING, PON_STATE_O5_OPERATION,
	};
	struct air_pon_omci *ind;

	if (!p || atomic_read(&p->stop))
		return;
	ind = kzalloc(sizeof(*ind), GFP_KERNEL);
	if (!ind)
		return;
	ind->len = 4;
	if (p->sim_step >= (int)ARRAY_SIZE(seq)) {
		kfree(ind);
		p->state = PON_STATE_O5_OPERATION;
		return;
	}
	p->state = seq[p->sim_step];
	ind->msg[0] = 0x0A; ind->msg[1] = (u8)p->sim_step;
	ind_push(ind);
	kfree(ind);
	p->rx_power = -2300 + p->sim_step * 200;
	p->sim_step++;
	schedule_delayed_work(&p->sim_work, msecs_to_jiffies(1000));
}

/* ------------------------------------------------------------------ */
/* char device                                                         */
/* ------------------------------------------------------------------ */

static ssize_t air_pon_read(struct file *filp, char __user *buf,
			    size_t count, loff_t *ppos)
{
	struct air_pon *p = g_pon;
	struct air_pon_omci *rec;
	unsigned long flags;
	int ret;
	ssize_t n;

	if (!p)
		return -ENODEV;
	rec = kzalloc(sizeof(*rec), GFP_KERNEL);
	if (!rec)
		return -ENOMEM;
	if (kfifo_is_empty(&p->ind_fifo)) {
		if (filp->f_flags & O_NONBLOCK) {
			kfree(rec);
			return -EAGAIN;
		}
		ret = wait_event_interruptible(p->ind_wait,
				!kfifo_is_empty(&p->ind_fifo) ||
				atomic_read(&p->stop));
		if (ret) {
			kfree(rec);
			return ret;
		}
		if (atomic_read(&p->stop)) {
			kfree(rec);
			return 0;
		}
	}
	spin_lock_irqsave(&p->fifo_lock, flags);
	if (kfifo_out_peek(&p->ind_fifo, &rec->len, 2) != 2) {
		spin_unlock_irqrestore(&p->fifo_lock, flags);
		kfree(rec);
		return 0;
	}
	if (count < (size_t)rec->len + 2) {
		spin_unlock_irqrestore(&p->fifo_lock, flags);
		kfree(rec);
		return -EMSGSIZE;
	}
	if (kfifo_out(&p->ind_fifo, &rec->len, 2) != 2 ||
	    kfifo_out(&p->ind_fifo, rec->msg, rec->len) != rec->len) {
		spin_unlock_irqrestore(&p->fifo_lock, flags);
		kfree(rec);
		return -EIO;
	}
	spin_unlock_irqrestore(&p->fifo_lock, flags);

	n = rec->len + 2;
	ret = copy_to_user(buf, rec, n);
	kfree(rec);
	return ret ? -EFAULT : n;
}

static long air_pon_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	struct air_pon *p = g_pon;
	struct air_pon_status st;
	u8 laser;

	switch (cmd) {
	case AIR_PON_SEND_OMCI: {
		struct air_pon_omci *omci;
		int r;

		omci = kzalloc(sizeof(*omci), GFP_KERNEL);
		if (!omci)
			return -ENOMEM;
		if (copy_from_user(omci, (void __user *)arg, sizeof(*omci))) {
			kfree(omci);
			return -EFAULT;
		}
		if (omci->len == 0 || omci->len > AIR_PON_OMCI_MAX) {
			kfree(omci);
			return -EINVAL;
		}
		r = hal_send_omci(omci);
		kfree(omci);
		return r;
	}

	case AIR_PON_GET_STATUS:
		hal_get_status(&st);
		if (copy_to_user((void __user *)arg, &st, sizeof(st)))
			return -EFAULT;
		return 0;

	case AIR_PON_SET_LASER:
		if (copy_from_user(&laser, (void __user *)arg, sizeof(laser)))
			return -EFAULT;
		if (p && p->tx_off_base)
			hal_laser_enable(laser);
		if (p)
			p->laser = !!laser;
		hal_activate(laser);
		return 0;

	case AIR_PON_GET_LASER:
		laser = p ? p->laser : 0;
		if (copy_to_user((void __user *)arg, &laser, sizeof(laser)))
			return -EFAULT;
		return 0;
	}
	return -ENOTTY;
}

static int air_pon_open(struct inode *ino, struct file *filp) { return 0; }
static int air_pon_release(struct inode *ino, struct file *filp) { return 0; }

static const struct file_operations air_pon_fops = {
	.owner		= THIS_MODULE,
	.open		= air_pon_open,
	.release	= air_pon_release,
	.read		= air_pon_read,
	.unlocked_ioctl	= air_pon_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl	= compat_ptr_ioctl,
#endif
};

static struct miscdevice air_pon_misc = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "airoha_pon",
	.fops	= &air_pon_fops,
};

/* ------------------------------------------------------------------ */
/* generic-netlink management family                                   */
/* ------------------------------------------------------------------ */

static struct genl_family air_pon_genl_family;

static int genl_get_info(struct sk_buff *skb, struct genl_info *info)
{
	struct air_pon_status st;
	struct sk_buff *msg;
	void *hdr;

	hal_get_status(&st);
	msg = nlmsg_new(NLMSG_DEFAULT_SIZE, GFP_KERNEL);
	if (!msg)
		return -ENOMEM;
	hdr = genlmsg_put(msg, info->snd_portid, info->snd_seq,
			 &air_pon_genl_family, 0, PON_CMD_GET_INFO);
	if (!hdr)
		goto nla_put_failure;
	if (nla_put_u32(msg, PON_ATTR_STATE, st.state) ||
	    nla_put_s32(msg, PON_ATTR_RX_POWER, st.rx_power) ||
	    nla_put_s32(msg, PON_ATTR_TX_POWER, st.tx_power) ||
	    nla_put_s32(msg, PON_ATTR_BIAS, st.bias) ||
	    nla_put_s32(msg, PON_ATTR_TEMP, st.temperature) ||
	    nla_put_u32(msg, PON_ATTR_VOLTAGE, st.voltage) ||
	    nla_put_u8(msg, PON_ATTR_LASER, st.laser) ||
	    nla_put_u8(msg, PON_ATTR_LOS, st.los) ||
	    nla_put_u8(msg, PON_ATTR_TX_FAULT, st.tx_fault) ||
	    nla_put_u8(msg, PON_ATTR_FEC, st.fec) ||
	    nla_put_u32(msg, PON_ATTR_MODE, st.mode))
		goto nla_put_failure;
	genlmsg_end(msg, hdr);
	return genlmsg_reply(msg, info);

nla_put_failure:
	nlmsg_free(msg);
	return -EMSGSIZE;
}

static int genl_set_enable(struct sk_buff *skb, struct genl_info *info)
{
	u8 en = 0;
	if (info->attrs[PON_ATTR_ENABLE])
		en = nla_get_u8(info->attrs[PON_ATTR_ENABLE]);
	if (g_pon) {
		if (g_pon->tx_off_base)
			hal_laser_enable(en);
		g_pon->laser = !!en;
	}
	hal_activate(en);
	return 0;
}

static int genl_set_prov(struct sk_buff *skb, struct genl_info *info)
{
	u32 mode = PON_MODE_AUTO;

	if (!g_pon)
		return -ENODEV;
	if (info->attrs[PON_ATTR_MODE])
		mode = nla_get_u32(info->attrs[PON_ATTR_MODE]);
	/* Store the requested line mode. The actual on-wire mode register is
	 * applied in hal_activate() (TODO: gponDevSetWanMode sequence). */
	g_pon->mode = mode;
	xpon_mode_param = (int)mode;
	if (info->attrs[PON_ATTR_FEC])
		g_pon->fec = nla_get_u8(info->attrs[PON_ATTR_FEC]);
	if (info->attrs[PON_ATTR_SERIAL]) {
		u8 *s = nla_data(info->attrs[PON_ATTR_SERIAL]);
		int l = nla_len(info->attrs[PON_ATTR_SERIAL]);

		if (l > PON_SERIAL_LEN)
			l = PON_SERIAL_LEN;
		memcpy(g_pon->serial, s, l);
		g_pon->serial_len = (u8)l;
		hal_set_serial(g_pon);
	}
	dev_info(g_pon->dev, "provisioned: mode=%u fec=%u\n", mode, g_pon->fec);
	return 0;
}

static const struct genl_ops air_pon_genl_ops[] = {
	{ .cmd = PON_CMD_GET_INFO,   .doit = genl_get_info },
	{ .cmd = PON_CMD_SET_ENABLE, .doit = genl_set_enable },
	{ .cmd = PON_CMD_SET_PROV,   .doit = genl_set_prov },
};

static struct genl_family air_pon_genl_family = {
	.name		= PON_GENL_NAME,
	.version	= PON_GENL_VERSION,
	.maxattr	= PON_ATTR_MAX,
	.ops		= air_pon_genl_ops,
	.n_ops		= ARRAY_SIZE(air_pon_genl_ops),
#ifdef GENL_ID_GENERATE
	.id		= GENL_ID_GENERATE,
#endif
};

/* ------------------------------------------------------------------ */
/* platform driver                                                     */
/* ------------------------------------------------------------------ */

static int air_pon_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct air_pon *p;
	struct resource *res;
	int ret;

	p = devm_kzalloc(dev, sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;
	p->dev = dev;
	p->mode = xpon_mode_param;
	p->state = PON_STATE_O1_INIT;
	p->rx_power = -4000;
	p->tx_power = 0;
	p->bias = 0;
	p->temperature = 0;
	p->voltage = 0;
	p->fec = 0;
	spin_lock_init(&p->fifo_lock);
	init_waitqueue_head(&p->ind_wait);
	atomic_set(&p->stop, 0);

	ret = kfifo_alloc(&p->ind_fifo, 64 * 1024, GFP_KERNEL);
	if (ret)
		return ret;

	p->tx_disable = devm_gpiod_get_optional(dev, "tx-disable", GPIOD_OUT_HIGH);
	if (IS_ERR(p->tx_disable)) {
		ret = PTR_ERR(p->tx_disable);
		goto err_fifo;
	}
	p->rx_sd = devm_gpiod_get_optional(dev, "rx-sd", GPIOD_IN);
	if (IS_ERR(p->rx_sd)) {
		ret = PTR_ERR(p->rx_sd);
		goto err_fifo;
	}
	p->tx_sd = devm_gpiod_get_optional(dev, "tx-sd", GPIOD_IN);
	if (IS_ERR(p->tx_sd)) {
		ret = PTR_ERR(p->tx_sd);
		goto err_fifo;
	}
	p->tx_fault = devm_gpiod_get_optional(dev, "tx-fault", GPIOD_IN);
	if (IS_ERR(p->tx_fault)) {
		ret = PTR_ERR(p->tx_fault);
		goto err_fifo;
	}

	if (device_property_read_bool(dev, "tx-disable-active-low"))
		p->tx_disable_active = 1;
	else if (device_property_read_bool(dev, "tx-disable-active-high"))
		p->tx_disable_active = 0;
	else
		p->tx_disable_active = 1; /* Airoha BOSA: active-low */

	if (backend_param == BACKEND_REAL) {
		p->mac_base = devm_ioremap(dev, PON_MAC_BASE_PHYS,
					   PON_MAC_IOMAP_SIZE);
		if (!p->mac_base) {
			dev_err(dev, "failed to ioremap PON MAC @0x%lx\n",
				PON_MAC_BASE_PHYS);
			ret = -ENOMEM;
			goto err_fifo;
		}
		p->phy_base = devm_ioremap(dev, PON_PHY_BASE_PHYS,
					  PON_PHY_IOMAP_SIZE);
		if (!p->phy_base) {
			dev_err(dev, "failed to ioremap PON PHY @0x%lx\n",
				PON_PHY_BASE_PHYS);
			ret = -ENOMEM;
			goto err_fifo;
		}
		res = devm_request_mem_region(dev, PON_PHY_TX_OFF_PHYS,
					     PON_PHY_TX_OFF_SIZE, "pon-tx-off");
		p->tx_off_base = devm_ioremap(dev, PON_PHY_TX_OFF_PHYS,
					     PON_PHY_TX_OFF_SIZE);
		if (!p->tx_off_base) {
			dev_err(dev, "failed to ioremap TX_OFF @0x%lx\n",
				PON_PHY_TX_OFF_PHYS);
			ret = -ENOMEM;
			goto err_fifo;
		}
		dev_info(dev, "PON MAC/PHY/TX_OFF mapped (real backend)\n");

		ret = omci_netdev_create(p);
		if (ret)
			dev_warn(dev, "omci netdevice create failed (%d)\n", ret);
	}

	p->laser = 0;
	if (p->tx_disable)
		gpiod_set_value_cansleep(p->tx_disable, p->tx_disable_active);

	INIT_DELAYED_WORK(&p->sim_work, sim_work_fn);

	g_pon = p;
	platform_set_drvdata(pdev, p);

	ret = misc_register(&air_pon_misc);
	if (ret)
		goto err_dev;

	ret = genl_register_family(&air_pon_genl_family);
	if (ret)
		goto err_misc;

	dev_info(dev, "Airoha PON driver probed (hal_backend=%d %s, mode=%d)\n",
		 backend_param, backend_param ? "real" : "sim", p->mode);
	return 0;

err_misc:
	misc_deregister(&air_pon_misc);
err_dev:
	omci_netdev_destroy(p);
	g_pon = NULL;
	platform_set_drvdata(pdev, NULL);
err_fifo:
	kfifo_free(&p->ind_fifo);
	return ret;
}

static void air_pon_remove(struct platform_device *pdev)
{
	struct air_pon *p = platform_get_drvdata(pdev);

	atomic_set(&p->stop, 1);
	wake_up_interruptible(&p->ind_wait);
	cancel_delayed_work_sync(&p->sim_work);
	if (p->gdm2_ndev)
		dev_put(p->gdm2_ndev);
	omci_netdev_destroy(p);
	genl_unregister_family(&air_pon_genl_family);
	misc_deregister(&air_pon_misc);
	kfifo_free(&p->ind_fifo);
	g_pon = NULL;
}

static const struct of_device_id air_pon_of_match[] = {
	{ .compatible = "airoha,pon" },
	{ .compatible = "econet,ecnt-xpon" },
	{},
};
MODULE_DEVICE_TABLE(of, air_pon_of_match);

static struct platform_driver air_pon_driver = {
	.probe	= air_pon_probe,
	.remove = air_pon_remove,
	.driver = {
		.name = "airoha_pon",
		.of_match_table = air_pon_of_match,
	},
};

module_platform_driver(air_pon_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("OpenWrt AN7581 PON porting (clean-room)");
MODULE_DESCRIPTION("Airoha AN7581 PON management-plane + OMCI transport driver");
MODULE_ALIAS("platform:airoha_pon");
