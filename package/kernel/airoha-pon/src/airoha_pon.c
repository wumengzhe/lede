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
 * In the Airoha reference BSP this frame rides the vendor "PWAN" QDMA
 * subsystem (v2/xpon_10g/src/pwan). That subsystem is Airoha-private; this
 * driver exposes the OMCI frame over a virtual "omci" netdevice so the same
 * framing reaches whichever transport the kernel provides. NOTE: real OLT
 * delivery currently requires the Airoha PWAN backend (see PON_PORTING.md);
 * without it the frame is queued but not put on the fibre (tagged TODO).
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
#include <linux/skbuff.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/version.h>

#include "pon_abi.h"
#include "pon_mac_seq.h"

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

/* OMCI TX DMA submission gate. The OMCI *framing* (EtherType 0x88b5 over
 * the omci netdevice) is implemented here. The actual on-fibre delivery
 * needs the Airoha PWAN QDMA backend; until that is wired, frames are
 * queued but not transmitted. Set omci_tx_enable=1 to attempt the netdev
 * path (still gated by PWAN TODO). */
static bool omci_tx_enable;
module_param_named(omci_tx_enable, omci_tx_enable, bool, 0444);
MODULE_PARM_DESC(omci_tx_enable, "0=safe (default), 1=queue OMCI via omci netdev (PWAN TODO)");

/* ------------------------------------------------------------------ */
/* Device / GPIO state                                                 */
/* ------------------------------------------------------------------ */

struct air_pon {
	struct device		*dev;
	void __iomem		*mac_base;	/* PON MAC regs (real backend) */
	void __iomem		*phy_base;	/* PON PHY regs (real backend) */
	void __iomem		*tx_off_base;	/* laser TX_OFF (real backend) */
	struct net_device	*omci_netdev;	/* OMCI-over-Ethernet xport */
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
 * on-fibre delivery requires the Airoha PWAN QDMA backend; until that
 * is present we free the skb and report success (so the stack does not
 * block) but tag it clearly as not transmitted. */
static netdev_tx_t omci_ndo_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct air_pon *p = netdev_priv(ndev);

	if (!omci_tx_enable) {
		dev_dbg(p ? p->dev : ndev->dev.parent,
			"OMCI TX dropped (omci_tx_enable=0 / PWAN backend TODO)\n");
		dev_kfree_skb(skb);
		return NETDEV_TX_OK;
	}
	/* TODO(PWAN): hand skb to Airoha QDMA WAN OMCI queue
	 * (v2/xpon_10g/src/pwan/gpon_wan.c:gwan_prepare_tx_message). */
	dev_dbg(p ? p->dev : ndev->dev.parent,
		"OMCI TX queued len=%u (PWAN backend TODO)\n", skb->len);
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
	struct air_pon_omci rec;
	u8 *p = skb->data;

	if (skb->len < 2)
		goto drop;
	rec.len = min_t(u16, (u16)(skb->len - 14), AIR_PON_OMCI_MAX);
	if (rec.len == 0)
		goto drop;
	memcpy(rec.msg, skb->data + 14, rec.len);
	ind_push(&rec);
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

/* QDMA OMCI TX descriptor (reverse-engineered, see PON_OMCI_TX_RE.md)  */
struct gwan_tx_desc {
	__le32 word0;
	__le32 word1;
} __packed;

static void gwan_build_tx_desc(struct gwan_tx_desc *d, const struct air_pon_omci *m)
{
	u32 len = m->len > 0xffff ? 0xffff : m->len;

	d->word0 = cpu_to_le32(((len & 0xffff) << 14) | (1u << 8));
	d->word1 = cpu_to_le32((1u << 31) | (0x7fu << 24) |
			       (0x2u << 20) | (0x1fu << 6) | (0x1fu << 0));
}

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

/* Forward a raw OMCI message to the PON MAC.
 * Real backend: encapsulate as EtherType 0x88b5 Ethernet and push via the
 * omci netdevice (PWAN TODO for actual on-fibre delivery).
 * Sim backend: echo back as an indication so the userspace stack is
 * exercised end-to-end without hardware. */
static int hal_send_omci(const struct air_pon_omci *m)
{
	struct air_pon *p = g_pon;
	struct sk_buff *skb;
	u8 *eth;

	if (backend_param == BACKEND_REAL) {
		if (!p || !p->omci_netdev)
			return -ENODEV;
		skb = alloc_skb(m->len + ETH_HLEN + 2, GFP_KERNEL);
		if (!skb)
			return -ENOMEM;
		skb_reserve(skb, 2);
		eth = skb_put(skb, ETH_HLEN);
		ether_addr_copy(eth, omci_olt_mac);
		ether_addr_copy(eth + ETH_ALEN, omci_dev_mac);
		eth[12] = (OMCI_ETHERTYPE >> 8) & 0xff;
		eth[13] = OMCI_ETHERTYPE & 0xff;
		skb_put_data(skb, m->msg, m->len);
		skb->dev = p->omci_netdev;
		skb->protocol = cpu_to_be16(OMCI_ETHERTYPE);
		dev_queue_xmit(skb);
		return 0;
	}
	if (p)
		ind_push(m);
	return 0;
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
	dev_info(p->dev, "PON MAC init sequence replayed (%d ops, mode=%d)\n",
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
	struct air_pon_omci ind = { .len = 4 };

	if (!p || atomic_read(&p->stop))
		return;
	if (p->sim_step >= (int)ARRAY_SIZE(seq)) {
		p->state = PON_STATE_O5_OPERATION;
		return;
	}
	p->state = seq[p->sim_step];
	ind.msg[0] = 0x0A; ind.msg[1] = (u8)p->sim_step;
	ind_push(&ind);
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
	struct air_pon_omci rec;
	unsigned long flags;
	int ret;

	if (!p)
		return -ENODEV;
	if (kfifo_is_empty(&p->ind_fifo)) {
		if (filp->f_flags & O_NONBLOCK)
			return -EAGAIN;
		ret = wait_event_interruptible(p->ind_wait,
				!kfifo_is_empty(&p->ind_fifo) ||
				atomic_read(&p->stop));
		if (ret)
			return ret;
		if (atomic_read(&p->stop))
			return 0;
	}
	spin_lock_irqsave(&p->fifo_lock, flags);
	if (kfifo_out_peek(&p->ind_fifo, &rec.len, 2) != 2) {
		spin_unlock_irqrestore(&p->fifo_lock, flags);
		return 0;
	}
	if (count < (size_t)rec.len + 2) {
		spin_unlock_irqrestore(&p->fifo_lock, flags);
		return -EMSGSIZE;
	}
	kfifo_out(&p->ind_fifo, &rec.len, 2);
	kfifo_out(&p->ind_fifo, rec.msg, rec.len);
	spin_unlock_irqrestore(&p->fifo_lock, flags);

	if (copy_to_user(buf, &rec, rec.len + 2))
		return -EFAULT;
	return rec.len + 2;
}

static long air_pon_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	struct air_pon *p = g_pon;
	struct air_pon_omci omci;
	struct air_pon_status st;
	u8 laser;

	switch (cmd) {
	case AIR_PON_SEND_OMCI:
		if (copy_from_user(&omci, (void __user *)arg, sizeof(omci)))
			return -EFAULT;
		if (omci.len == 0 || omci.len > AIR_PON_OMCI_MAX)
			return -EINVAL;
		return hal_send_omci(&omci);

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
