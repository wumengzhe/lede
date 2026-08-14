// SPDX-License-Identifier: GPL-2.0
/*
 * kmod-airoha-pon - Airoha AN7581 PON management-plane + OMCI transport
 *
 * Two channels to userspace (both consumed by pon-manager/ponmgr):
 *
 *  1. generic-netlink family "airoha_pon"  - management state:
 *       laser on/off, LOS/TX-FAULT, provisioning, PON state (O1..O5),
 *       RX power. Driven by the BOSA control GPIOs described in the
 *       "airoha,pon" device tree node.
 *
 *  2. char device /dev/airoha_pon          - OMCI/GTC *frame* plane:
 *       SEND_OMCI ioctl pushes a raw OMCI G.988 message to the PON MAC,
 *       read() drains OMCI indications/alarms from the MAC. This is the
 *       transport that lets ponmgr actually talk OMCI with the OLT.
 *
 * The "engine" that terminates the optical link (trains the serdes, runs
 * GTC framing, does OMCI extraction) is the proprietary Airoha XPON HAL
 * running on the on-die NPU. It is selected with the `hal_backend` param:
 *
 *   hal_backend=sim   (default) synthesises a plausible O5 bring-up and
 *                     echoes OMCI so the whole userspace stack is exercisable
 *                     on real hardware without the proprietary firmware.
 *
 *   hal_backend=real  the PON MAC register init sequence (reverse-engineered
 *                     from stock xpon.ko, see pon_mac_seq.h) is replayed on
 *                     activation, and OMCI frames are shipped to the on-die
 *                     NPU XPON-HAL firmware - which is what actually trains
 *                     the serdes and terminates the optical link - through
 *                     the NPU mailbox transport added by airoha target patch
 *                     110-01 (airoha_npu_xpon_send_msg).
 *
 *                     The mailbox func_id the XPON-HAL listens on is not
 *                     published by Airoha, so it is *discovered at runtime*:
 *                     the firmware acknowledges mailbox messages, so an
 *                     unused id times out (-ETIMEDOUT) while the right one
 *                     returns 0. See hal_xpon_probe_func(). The resolved id
 *                     is readable at
 *                     /sys/module/airoha_pon/parameters/xpon_func_id_active
 *                     and can be pinned with xpon_func_id=<n>.
 *
 *                     Still open: the NPU->Linux OMCI *indication* payload
 *                     layout (proprietary xpon_bsp ABI). air_pon_xpon_ind()
 *                     receives the mailbox IRQ and wakes readers, but the
 *                     frame decode is not implemented - see the comment
 *                     there before adding it.
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

/* NPU XPON-HAL transport API (added by airoha target patch
 * 110-01-net-airoha-npu-Add-XPON-OMCI-mailbox-transport-API.patch).
 * The on-die NPU firmware terminates the optical link; we reach its XPON-HAL
 * through this mailbox transport. CONFIG_NET_AIROHA_NPU is built-in on the
 * airoha target, so these symbols are always exported to this module. */
#include <linux/soc/airoha/airoha_offload.h>

/* PON MAC register base (an7581.dtsi pon_pcs block). All offsets in
 * pon_mac_seq.h are relative to this physical address. Mapped non-exclusively
 * because the upstream airoha_eth driver also pokes this region for pon_pcs.
 * See pon_mac_seq.h header for the reverse-engineering provenance. */
#define PON_MAC_BASE_PHYS	0x1fa80000UL
#define PON_MAC_IOMAP_SIZE	0xc000UL	/* covers pon_pcs sub-blocks ..0x1fa8c000 */

/* ------------------------------------------------------------------ */
/* HAL backend                                                         */
/* ------------------------------------------------------------------ */

enum hal_backend {
	BACKEND_SIM = 0,
	BACKEND_REAL = 1,
};

static int backend_param = BACKEND_SIM;
module_param_named(hal_backend, backend_param, int, 0444);
MODULE_PARM_DESC(hal_backend, "0=sim (default), 1=real Airoha XPON HAL");

/* NPU mailbox function id the firmware's XPON-HAL listens on for OMCI /
 * G.988 messages. Airoha does not publish this value (it lives in the
 * proprietary xpon_bsp), so by default we *discover* it at runtime instead
 * of guessing: see hal_xpon_probe_func(). Set the param to 0-15 to pin a
 * known id and skip probing. -1 = auto (default). */
static int xpon_func_id = -1;
module_param_named(xpon_func_id, xpon_func_id, int, 0444);
MODULE_PARM_DESC(xpon_func_id,
		 "NPU mailbox func_id for XPON-HAL OMCI: -1=auto-probe (default), 0-15=pin");

/* The id that auto-probing settled on, exported read-only so userspace can
 * read it back from /sys/module/airoha_pon/parameters/xpon_func_id_active
 * and pin it on later boots. -1 = not resolved yet. */
static int xpon_active_func = -1;
module_param_named(xpon_func_id_active, xpon_active_func, int, 0444);
MODULE_PARM_DESC(xpon_func_id_active,
		 "read-only: NPU mailbox func_id auto-probing resolved to (-1 = none yet)");

/* Candidate mailbox func_ids probed in this order when xpon_func_id = -1.
 *
 * The in-tree NPU driver's own enum (airoha_npu.c) is lifted from Airoha's
 * SDK and reads: WIFI=0, TUNNEL=1, NOTIFY=2, DBA=3, TR471=4, PPE=5. "DBA"
 * is Dynamic Bandwidth Allocation - a PON-only concept (upstream bandwidth
 * grants in G.987/G.9807 XGS-PON) - which is direct evidence that the NPU
 * firmware exposes PON functionality inside this very id space. So DBA is
 * tried first, then NOTIFY (generic event channel), then the ids the
 * in-tree driver never uses (6..15), where a proprietary XPON-HAL entry
 * point would sit.
 *
 * WIFI(0) and PPE(5) are deliberately never probed: they are owned by the
 * in-tree wlan / flow-offload datapaths and a stray message there could
 * disturb a working datapath. TUNNEL(1) and TR471(4) are tried last.
 */
static const u8 xpon_func_candidates[] = {
	3, 2, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 1, 4,
};

/* ------------------------------------------------------------------ */
/* Device / GPIO state                                                 */
/* ------------------------------------------------------------------ */

struct air_pon {
	struct device		*dev;
	void __iomem		*mac_base;	/* PON MAC regs (real backend) */
	struct airoha_npu	*npu;		/* NPU XPON-HAL handle (real backend) */
	struct gpio_desc	*tx_disable;	/* active-low => laser on */
	struct gpio_desc	*rx_sd;		/* loss-of-signal */
	struct gpio_desc	*tx_sd;
	struct gpio_desc	*tx_fault;
	int			tx_disable_active; /* 0=high 1=low */
	int			laser;		/* 1 = enabled */

	enum pon_state		state;
	s32			rx_power;	/* dBm*100 */

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

/* NPU XPON-HAL unsolicited-indication callback. Invoked from the shared NPU
 * mailbox IRQ (hard IRQ context, must not sleep). The NPU raises this
 * interrupt for every event coming from the XPON-HAL. The exact NPU->Linux
 * OMCI payload protocol (which mailbox queue / shared-memory region carries
 * the indication frame) is proprietary (Airoha xpon_bsp) and is still being
 * reverse-engineered; once captured, decode the frame here and enqueue it
 * with ind_push() so userspace receives it via /dev/airoha_pon read().
 * For now we wake the reader so the OMCI read() contract stays live and the
 * event is observable in the kernel log. */
static void air_pon_xpon_ind(void *priv)
{
	struct air_pon *p = priv;

	if (!p)
		return;
	dev_dbg(p->dev, "XPON indication from NPU (payload decode pending)\n");
	wake_up_interruptible(&p->ind_wait);
}

/* Discover which NPU mailbox func_id the XPON-HAL answers on.
 *
 * This works because the mailbox handshake is *acknowledged* by the firmware:
 * airoha_npu_send_msg() polls MBOX_MSG_DONE for 100 ms and then checks the
 * MBOX_MSG_STATUS field, so an id nobody listens on returns -ETIMEDOUT and an
 * id that rejects the payload returns -EINVAL, while only a function that
 * actually consumed the message returns 0. That gives us a reliable runtime
 * oracle for a value Airoha never published.
 *
 * Worst case cost is ARRAY_SIZE(candidates) * 100 ms (~1.4 s), paid once, in
 * process context (ioctl), on the first OMCI transmission.
 *
 * Must be called from process context: the mailbox poll runs under
 * spin_lock_bh() inside the NPU driver.
 */
static int hal_xpon_probe_func(struct air_pon *p, const struct air_pon_omci *m)
{
	int i, err = -ENODEV;

	for (i = 0; i < (int)ARRAY_SIZE(xpon_func_candidates); i++) {
		u8 fid = xpon_func_candidates[i];

		err = airoha_npu_xpon_send_msg(p->npu, fid, m->msg, m->len,
					       GFP_KERNEL);
		if (!err) {
			xpon_active_func = fid;
			dev_info(p->dev,
				 "XPON-HAL answers on NPU mailbox func_id %u (auto-probed); pin with xpon_func_id=%u\n",
				 fid, fid);
			return 0;
		}
		dev_dbg(p->dev, "XPON func_id %u probe: %d\n", fid, err);
	}

	dev_warn(p->dev,
		 "no NPU mailbox func_id accepted OMCI (last err %d); XPON-HAL firmware may not be running\n",
		 err);
	return err;
}

/* Forward a raw OMCI message to the PON MAC. Returns 0 on success. */
static int hal_send_omci(const struct air_pon_omci *m)
{
	struct air_pon *p = g_pon;

	if (backend_param == BACKEND_REAL) {
		/* Deliver the OMCI G.988 frame to the NPU XPON-HAL through the
		 * shared NPU mailbox (MBQ0), routed by func_id. The on-die
		 * firmware does the GTC framing + OMCI extraction; this just
		 * ships the bytes. */
		if (!p || !p->npu)
			return -ENODEV;

		/* Explicitly pinned id: use it as-is. */
		if (xpon_func_id >= 0) {
			dev_dbg(p->dev, "hal_send_omci: %u bytes -> func_id %d (pinned)\n",
				m->len, xpon_func_id);
			return airoha_npu_xpon_send_msg(p->npu,
							(u8)xpon_func_id,
							m->msg, m->len,
							GFP_KERNEL);
		}

		/* Auto mode: first OMCI doubles as the discovery probe, so the
		 * message is delivered by the probe itself once it hits. */
		if (xpon_active_func < 0)
			return hal_xpon_probe_func(p, m);

		dev_dbg(p->dev, "hal_send_omci: %u bytes -> func_id %d\n",
			m->len, xpon_active_func);
		return airoha_npu_xpon_send_msg(p->npu, (u8)xpon_active_func,
						m->msg, m->len, GFP_KERNEL);
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
	s->state    = p->state;
	s->laser    = p->laser;
	s->rx_power = p->rx_power;
	s->los      = p->rx_sd ? !gpiod_get_value_cansleep(p->rx_sd) : 0;
	s->tx_fault = p->tx_fault ? gpiod_get_value_cansleep(p->tx_fault) : 0;
}

/* Replay the reverse-engineered PON MAC init sequence (pon_mac_seq.h) into
 * the ioremapped MAC register block. Safe to call once the laser GPIO is
 * already asserted by the caller. All entries are real register accesses
 * captured at set_xpon_data/get_xpon_data call sites in stock xpon.ko. */
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
	dev_info(p->dev, "PON MAC init sequence replayed (%d ops)\n",
		 PON_MAC_SEQ_N);
}

static void hal_activate(int on)
{
	struct air_pon *p = g_pon;

	if (!p)
		return;
	if (backend_param == BACKEND_REAL) {
		/* The on-die NPU XPON-HAL firmware (airoha-en7581-npu-firmware)
		 * performs serdes training + GTC/OMCI sync. Its bootstrap mailbox
		 * handshake is still being reverse-engineered, so here we only
		 * (re)program the PON MAC registers and report the MAC as ready
		 * (standby). The link reaches O5 once the NPU firmware completes
		 * synchronisation - that is driven by the firmware, not this
		 * register block. See re_omci.py RE notes. */
		if (on) {
			pon_mac_replay_seq(p);
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
	    nla_put_u8(msg, PON_ATTR_LASER, st.laser) ||
	    nla_put_u8(msg, PON_ATTR_LOS, st.los) ||
	    nla_put_u8(msg, PON_ATTR_TX_FAULT, st.tx_fault))
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
	p->state = PON_STATE_O1_INIT;
	p->rx_power = -4000;
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
	 * init sequence, and attach to the NPU XPON-HAL mailbox transport.
	 * Non-exclusive ioremap (the airoha_eth pon_pcs driver also maps this
	 * region). The NPU handle comes from the "airoha,npu" phandle on this
	 * device tree node (see an7581-nokia_xg-040g-md-common.dtsi). */
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

		p->npu = airoha_npu_get(&pdev->dev);
		if (IS_ERR(p->npu)) {
			ret = PTR_ERR(p->npu);
			p->npu = NULL;
			/* -ENODEV means the NPU driver has not probed yet;
			 * defer so we are retried once it is available. */
			if (ret == -ENODEV)
				ret = -EPROBE_DEFER;
			else
				dev_err(dev, "failed to get NPU handle: %d\n",
					ret);
			goto err_fifo;
		}
	}

	p->laser = 0;
	if (p->tx_disable)
		gpiod_set_value_cansleep(p->tx_disable, p->tx_disable_active);

	INIT_DELAYED_WORK(&p->sim_work, sim_work_fn);

	g_pon = p;
	platform_set_drvdata(pdev, p);

	/* Attach the NPU indication callback only now that g_pon and drvdata
	 * are live: it fires from the shared NPU mailbox hard IRQ, which can
	 * happen (PPE/wlan traffic on the same mailbox) before we finish
	 * probing, so it must never observe a half-initialised device. */
	if (p->npu) {
		airoha_npu_xpon_register_ind(p->npu, air_pon_xpon_ind, p);
		if (xpon_func_id >= 0)
			dev_info(dev, "Airoha NPU XPON transport attached (func_id=%d, pinned)\n",
				 xpon_func_id);
		else
			dev_info(dev, "Airoha NPU XPON transport attached (func_id auto-probed on first OMCI)\n");
	}

	ret = misc_register(&air_pon_misc);
	if (ret)
		goto err_ind;

	ret = genl_register_family(&air_pon_genl_family);
	if (ret)
		goto err_misc;

	dev_info(dev, "Airoha PON driver probed (hal_backend=%d, %s)\n",
		 backend_param, backend_param ? "real" : "sim");
	return 0;

err_misc:
	misc_deregister(&air_pon_misc);
err_ind:
	/* Detach the hard-IRQ callback *before* the device goes away, else the
	 * next NPU mailbox interrupt would dereference freed memory. */
	if (p->npu)
		airoha_npu_xpon_register_ind(p->npu, NULL, NULL);
	g_pon = NULL;
	platform_set_drvdata(pdev, NULL);
	if (p->npu) {
		airoha_npu_put(p->npu);
		p->npu = NULL;
	}
err_fifo:
	kfifo_free(&p->ind_fifo);
	return ret;
}

static void air_pon_remove(struct platform_device *pdev)
{
	struct air_pon *p = platform_get_drvdata(pdev);

	if (p->npu) {
		airoha_npu_xpon_register_ind(p->npu, NULL, NULL);
		airoha_npu_put(p->npu);
		p->npu = NULL;
	}
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
