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
 *       device tree node and by direct PON MAC register access.
 *
 *  2. char device /dev/airoha_pon          - OMCI/GTC *frame* plane:
 *       SEND_OMCI ioctl pushes a raw OMCI G.988 message to the PON MAC,
 *       read() drains OMCI indications/alarms from the MAC. This is the
 *       transport that lets ponmgr actually talk OMCI with the OLT.
 *
 * ARCHITECTURE (rev 3, corrected 2026-08-21):
 * The optical link is terminated by the on-die PON MAC / XPON PHY.
 * Authoritative register map from the an7581 tclinux reference dts:
 *   - PON MAC core : 0x1fb64000 (IRQ 42, "econet,ecnt-xpon")
 *   - PON PHY      : 0x1faf0000
 *   - USXGMII wrapper: 0x1fa80000
 *   - SerDes PMA/ANA: 0x1fa8a000 / 0x1fa8b000
 * This driver maps the PON MAC core block and replays the reverse-
 * engineered init sequence (pon_mac_seq.h). The NPU (0x1e900000) is
 * unrelated to PON; xpon_10g.ko has zero NPU/mailbox references.
 *
 * OMCI frames are pushed to the MAC by gwan_prepare_tx_message() which
 * builds a QDMA (queue-DMA) TX descriptor. The 2-word descriptor format is
 * now FULLY reverse-engineered (see PON_OMCI_TX_RE.md): word0[29:14]=frame
 * length, word0[8]=type flag, word1[31]=OWN, plus fixed control fields.
 * The descriptor is built in hal_send_omci()/omci_tx_submit(); the actual
 * ring-write + doorbell is gated behind module param omci_tx_enable (off by
 * default) because the doorbell register lives behind an unresolved external
 * symbol. Until that is resolved, the real backend returns -EOPNOTSUPP.
 *
 * PON mode: the public sysfs/module ABI uses enum pon_mode from pon_abi.h.
 *   1 = XGPON  (10G down / 2.5G up, factory default for ZJ CMCC)
 *   7 = XGSPON (10G symmetric, upstream OpenWrt reference default)
 * The underlying SoC register encoding for the mode is applied in
 * pon_mac_replay_seq() once it is fully reverse-engineered.
 *
 * hal_backend=1 (real, shipped default) maps registers and replays the
 * init sequence. hal_backend=0 (sim) synthesises an O1..O5 bring-up and
 * echoes OMCI so the userspace stack can be exercised without hardware.
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
#include <linux/version.h>

#include "pon_abi.h"
#include "pon_mac_seq.h"

/* PON MAC core register base (an7581 tclinux dtsi: xpon_mac@1fb64000).
 * All offsets in pon_mac_seq.h are relative to this physical address.
 * The upstream airoha_eth driver may also ioremap nearby regions; we map
 * non-exclusively here. The 0x1fa80000 region is the USXGMII wrapper,
 * not the PON MAC core. */
#define PON_MAC_BASE_PHYS	0x1fb64000UL
#define PON_MAC_IOMAP_SIZE	0x10000UL	/* covers 0x1fb64000..0x1fb74000 */

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

/* PON line mode exposed to userspace and used to select the register init
 * sequence. Default XGSPON (7) after upstream OpenWrt reference; XGPON (1) is
 * the factory ZJ CMCC default. */
static int xpon_mode_param = PON_MODE_XGSPON;
module_param_named(sys_xpon_mode, xpon_mode_param, int, 0644);
MODULE_PARM_DESC(sys_xpon_mode, "PON mode: 1=XGPON, 7=XGSPON (default)");

/* OMCI TX DMA submission. Disabled by default: the QDMA OMCI descriptor
 * *format* is reverse-engineered (see PON_OMCI_TX_RE.md) but the doorbell
 * register / ring base lives behind an external symbol we have not resolved
 * yet. Loading with omci_tx_enable=1 without a real doorbell will NOT work
 * and is intentionally gated so the driver never issues speculative MMIO. */
static bool omci_tx_enable;
module_param_named(omci_tx_enable, omci_tx_enable, bool, 0444);
MODULE_PARM_DESC(omci_tx_enable, "0=safe stub (default), 1=attempt QDMA OMCI TX (needs doorbell)");

/* ------------------------------------------------------------------ */
/* Device / GPIO state                                                 */
/* ------------------------------------------------------------------ */

struct air_pon {
	struct device		*dev;
	void __iomem		*mac_base;	/* PON MAC regs (real backend) */
	struct gpio_desc	*tx_disable;	/* active-low => laser on */
	struct gpio_desc	*rx_sd;		/* loss-of-signal */
	struct gpio_desc	*tx_sd;
	struct gpio_desc	*tx_fault;
	int			tx_disable_active; /* 0=high 1=low */
	int			laser;		/* 1 = enabled */
	enum pon_mode		mode;		/* public ABI line mode */

	enum pon_state		state;
	s32			rx_power;	/* dBm*100 */
	s32			tx_power;	/* dBm*100 */
	s32			bias;		/* mA*100 */
	s32			temperature;	/* degC*100 */
	u32			voltage;	/* mV */
	u8			fec;		/* 1 = enabled */

	/* OMCI indication fifo (records: u16 len + msg) */
	struct kfifo		ind_fifo;
	spinlock_t		fifo_lock;
	wait_queue_head_t	ind_wait;
	atomic_t		stop;

	/* sim state machine */
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
	/* drop oldest if full */
	if (kfifo_avail(&p->ind_fifo) < (unsigned int)(m->len + 2))
		kfifo_reset(&p->ind_fifo);
	kfifo_in(&p->ind_fifo, &m->len, 2);
	kfifo_in(&p->ind_fifo, m->msg, m->len);
	spin_unlock_irqrestore(&p->fifo_lock, flags);
	wake_up_interruptible(&p->ind_wait);
}

/* ------------------------------------------------------------------ */
/* HAL backend operations                                              */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* QDMA OMCI TX descriptor (reverse-engineered, see PON_OMCI_TX_RE.md)  */
/* ------------------------------------------------------------------ */

/* 2-word (8-byte) GWAN TX descriptor as built by stock xpon_10g.ko
 * gwan_prepare_tx_message(). Word layout confirmed from capstone disasm:
 *   word0[29:14] = OMCI frame length (16-bit)
 *   word0[8]     = OMCI/type flag (set on the msg-submit path)
 *   word1[31]    = OWN (DMA ownership)
 *   word1[30:24] = control field (observed 0x7f)
 *   word1[23:20] = queue/channel id (observed 0x2)
 *   word1[10:6]  = control field (observed 0x1f)
 *   word1[5:0]   = control field (observed 0x1f)
 * The actual data buffer is handed to the submit function separately
 * (it is NOT embedded in this 8-byte descriptor). */
struct gwan_tx_desc {
	__le32 word0;
	__le32 word1;
} __packed;

/* Build the descriptor from a userspace OMCI frame. Pure bit-pack, no MMIO. */
static void gwan_build_tx_desc(struct gwan_tx_desc *d, const struct air_pon_omci *m)
{
	u32 len = m->len > 0xffff ? 0xffff : m->len;

	d->word0 = cpu_to_le32(((len & 0xffff) << 14) | (1u << 8));
	d->word1 = cpu_to_le32((1u << 31) | (0x7fu << 24) |
			       (0x2u << 20) | (0x1fu << 6) | (0x1fu << 0));
}

/* Submit the OMCI frame to the PON MAC.
 *
 * Real hardware path: the stock module calls an *external* (relocated)
 * submit symbol that writes the descriptor into the GWAN DMA ring and rings
 * the doorbell. We have NOT resolved that symbol / the doorbell register yet
 * (see PON_OMCI_TX_RE.md, section 5). To stay safe on unknown hardware we
 * build the descriptor and, unless omci_tx_enable=1, refuse with -EOPNOTSUPP
 * instead of poking registers we cannot name.
 *
 * When the doorbell is resolved, the body below is where the ring write +
 * writel(doorbell) goes; the buffer still needs dma_map_single() of m->msg. */
static int omci_tx_submit(struct air_pon *p, const struct air_pon_omci *m)
{
	struct gwan_tx_desc d;

	gwan_build_tx_desc(&d, m);
	if (!omci_tx_enable) {
		dev_warn(p->dev,
			"OMCI TX: descriptor built (len=%u) but doorbell unresolved; "
			"load with omci_tx_enable=1 only after PON_OMCI_TX_RE.md §5 is done\n",
			m->len);
		return -EOPNOTSUPP;
	}
	/* TODO(§5): dma_map_single(m->msg, m->len, DMA_TO_DEVICE);
	 *           write d into GWAN TX ring slot; writel(DOORBELL, ring_base);
	 *           dma_unmap_single(...) on completion. */
	dev_warn(p->dev, "OMCI TX: doorbell path not implemented yet\n");
	return -EOPNOTSUPP;
}

/* Forward a raw OMCI message to the PON MAC. Returns 0 on success. */
static int hal_send_omci(const struct air_pon_omci *m)
{
	struct air_pon *p = g_pon;

	if (backend_param == BACKEND_REAL) {
		if (!p || !p->mac_base)
			return -ENODEV;
		return omci_tx_submit(p, m);
	}
	/* SIM: echo the message back as an indication so ponmgr sees a reply
	 * and the userspace OMCI codec is exercised end-to-end. */
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

/* Replay the reverse-engineered PON MAC init sequence (pon_mac_seq.h) into
 * the ioremapped MAC core register block. The sequence was captured at
 * set_xpon_data/get_xpon_data call sites in stock xpon_10g.ko (k5.4.55).
 * The PON mode is not yet encoded into the replay; once the SoC mode
 * register mapping is fully RE'd, xpon_mode_param will be written before
 * this sequence. */
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
		} else { /* PON_OP_RMW: reg = (reg & and_mask) | or_val */
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
			pon_mac_replay_seq(p);
			/* With only register init and no QDMA OMCI TX/RX, the MAC is
			 * brought to standby. A real O5 transition requires the OMCI
			 * handshake, which depends on the still-being-RE'd QDMA
			 * descriptor protocol. */
			p->state = PON_STATE_O2_STANDBY;
		} else {
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

/* sim: walk O1..O5 over a few seconds, pushing status + a synthetic OMCI */
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
	/* synthetic OMCI indication: a "MIB reset" style marker */
	ind.msg[0] = 0x0A; ind.msg[1] = (u8)p->sim_step; /* me/msg-type placeholder */
	ind_push(&ind);
	p->rx_power = -2300 + p->sim_step * 200; /* pretend signal climbs */
	p->sim_step++;
	/* ~1s per state */
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
	/* Peek the length first: if the caller's buffer is too small we must
	 * leave the record queued rather than dequeue-and-drop it. */
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
		/* Propagate the real errno instead of collapsing to -EIO:
		 * tuning xpon_func_id on hardware needs to tell "NPU rejected
		 * this mailbox func_id" (-EINVAL from the mailbox status field)
		 * apart from "no NPU attached" (-ENODEV) or -ENOMEM. */
		return hal_send_omci(&omci);

	case AIR_PON_GET_STATUS:
		hal_get_status(&st);
		if (copy_to_user((void __user *)arg, &st, sizeof(st)))
			return -EFAULT;
		return 0;

	case AIR_PON_SET_LASER:
		if (copy_from_user(&laser, (void __user *)arg, sizeof(laser)))
			return -EFAULT;
		if (p && p->tx_disable)
			gpiod_set_value_cansleep(p->tx_disable,
				laser ? !p->tx_disable_active : p->tx_disable_active);
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
/* generic-netlink management family (status / laser / provisioning)   */
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
		if (g_pon->tx_disable)
			gpiod_set_value_cansleep(g_pon->tx_disable,
				en ? !g_pon->tx_disable_active : g_pon->tx_disable_active);
		g_pon->laser = !!en;
	}
	hal_activate(en);
	return 0;
}

static const struct genl_ops air_pon_genl_ops[] = {
	{ .cmd = PON_CMD_GET_INFO,   .doit = genl_get_info },
	{ .cmd = PON_CMD_SET_ENABLE, .doit = genl_set_enable },
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

	/* Optional BOSA control / signal GPIOs from DT. */
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

	/* honour DT polarity hint */
	if (device_property_read_bool(dev, "tx-disable-active-low"))
		p->tx_disable_active = 1;
	else if (device_property_read_bool(dev, "tx-disable-active-high"))
		p->tx_disable_active = 0;
	else
		p->tx_disable_active = 1; /* Airoha BOSA: active-low */

	/* Real backend: map the PON MAC register block so we can replay the
	 * init sequence. Non-exclusive ioremap (the airoha_eth pon_pcs driver
	 * also maps this region). */
	if (backend_param == BACKEND_REAL) {
		p->mac_base = devm_ioremap(dev, PON_MAC_BASE_PHYS,
					   PON_MAC_IOMAP_SIZE);
		if (!p->mac_base) {
			dev_err(dev, "failed to ioremap PON MAC @0x%lx\n",
				PON_MAC_BASE_PHYS);
			ret = -ENOMEM;
			goto err_fifo;
		}
		dev_info(dev, "PON MAC regs mapped @0x%lx (real backend)\n",
			 PON_MAC_BASE_PHYS);
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
	genl_unregister_family(&air_pon_genl_family);
	misc_deregister(&air_pon_misc);
	kfifo_free(&p->ind_fifo);
	g_pon = NULL;
}

static const struct of_device_id air_pon_of_match[] = {
	{ .compatible = "airoha,pon" },
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
MODULE_AUTHOR("OpenWrt AN7581 PON porting");
MODULE_DESCRIPTION("Airoha AN7581 PON management-plane + OMCI transport driver");
MODULE_ALIAS("platform:airoha_pon");
