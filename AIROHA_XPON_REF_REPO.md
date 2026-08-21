# Airoha XPON 参考仓库分析（Sirherobrine23/airoha_xpon_en757x）

> 用途：本项目（Nokia Bell XG-040G-MD / AN7581 XGS-PON ONT OpenWrt 移植）的寄存器与
> 架构参考来源。**仅作 clean-room 参考，绝不可将仓库内 EcoNet 代码原样复制进 wumengzhe/lede。**

## 0. 法律/合规红线（务必遵守）
- 该仓库 README 自述为 "leaked/founded MAC and PHY codes ... for documentation purposes only"。
- 源码头带有 EcoNet (HK) Limited 版权声明（confidential and proprietary）。
- **正确做法**：把它当寄存器地图 / 架构蓝图读，提取"寄存器地址、位域、QDMA 用法、
  模式枚举值"等事实，用我们自己的代码重新实现（clean-room）。
- **禁止**：把 `ecnt_xpon.c` / `gpon_dev.c` / `mapping.c` 等任何文件整段粘贴进本仓库。
- 即便未来 wumengzhe/lede 设为 private，引入 EcoNet 专有驱动也会带来版权风险；
  个人/爱好用途可研究，分发固件需谨慎。

## 1. 仓库与我们的目标是否对得上 —— 对得上
- 目标芯片 AN7581（ARM64）在仓库内有专属 DTSI（`an7581/en7580 | GPON/EPON/XGPON`）。
- 其 DTSI 寄存器布局与我之前 capstone 反编译 `xpon_10g.ko` 的结果**互相印证**：
  - PON MAC `@0x1fb64000`，`compatible = "econet,ecnt-xpon"`，IRQ 42（XPON MAC INT）
  - PON PHY `@0x1faf0000`，`compatible = "econet,ecnt-pon_phy"`
  - SerDes ANA/PMA `@0x1fa8A000` / `@0x1fa8B000`（与 an7581-base.dtsi 一致）
- an7581 DTSI 用 64 位 `reg = <0x0 0x1fb64000 0x0 0x3e8>` 写法 → 6.x 设备树风格，
  与我们的 **6.12** 构建对得上（stock 5.4.55 的 `qdma_wan.ko` 门铃是死路，见 PON_OMCI_TX_RE.md）。

## 2. 代码结构（与我们的移植对应关系）
```
仓库根
├── ecnt_xpon.c           # MAC 寄存器访问垫片（平台驱动，compatible=econet,ecnt-xpon）
│                         #   EXPORT_SYMBOL: get_xpon_data / set_xpon_data / get_xpon_irq / get_xpon_dev
│                         #   AN7581 分支: XGPON_BASE_OFFSET=0x5000 (gpon=0x4000, epon=0x6000)
│                         #   TCSUPPORT_CPU_EN7581 宏区分 ARM64 vs MIPS(EN757x)
├── ecnt_pon_phy.c        # PHY 寄存器访问垫片（compatible=econet,ecnt-pon_phy）
│                         #   PON_PHY_RG_BASE_1=0x1faf0000, TX_OFF=0x1fa2ff24
│                         #   导出 set_pon_phy_mode_config / get_pon_phy_trans_status(函数指针,NULL)
├── tried_first_implementation_for_driver.patch  # 早期 PHY 驱动骨架补丁(仅 EN757x,无 OMCI/无 an7581)
├── v1/xpon, v1/xpon_phy  # 早期版本
├── v2/xpon_10g/          # ★ 原厂 xpon_10g.ko 的真实源码（OMCI/GWAN 应用层）
│   ├── src/xpondrv.c         # 驱动骨架/事件路由/QDMA 初始化
│   │                         #   QDMA_API_INIT(ECNT_QDMA_WAN,...); cbRecvPkts=pwan_cb_rx_packet
│   │                         #   module_param(mode); XMCS_IF_WAN_DETECT_MODE_XGSPON 枚举
│   ├── src/gpon/gpon_dev.c   # ★★★ OMCI TX 真实实现在此文件后部(gwan_prepare_tx_message 等)
│   │                         #   WebFetch 截断在前半(PLOAM/T-CONT/AES),门铃在更后段
│   ├── src/gpon/gpon_act.c / gpon_init.c / gpon_ploam.c / gpon_proc.c ...
│   ├── src/omci_oam_monitor.c  # OMCI/OAM 监控
│   ├── src/xpon_mci.c          # ★ 字符设备(/dev/omci 用户态接口)
│   └── src/pwan/               # pwan_net_start_xmit / pwan_cb_rx_packet / QDMA 描述符
├── v2/xpon_map/          # ★ 130KB 寄存器地图: mapping.c(74K) + xpon_mapping.c(56K) + .h
├── v2/xpon_phy_10g/      # 10G PHY 驱动
├── v2/econet_bob/        # 校准 blob (bob_check magic 0x0705070X @ offset 0x94)
├── v2/pon_vlan, pon_mac_filter, gpon_igmp, lddla, xpon_1g, xpon_igmp  # 数据面/特性
└── README.md             # AFE/LD 芯片清单(AN7562/63, EN7561G/DU, EN7570/71/73) + DTSI + i2c hw info
```

## 3. 关键架构事实（决定移植路线）
1. **OMCI TX = Airoha QDMA WAN 引擎，不是 PON MAC 裸 MMIO。**
   `xpondrv.c` 调 `QDMA_API_INIT(ECNT_QDMA_WAN,...)` 并 `#include <linux/qdma>`。
   OMCI 帧经 QDMA WAN 的某个专用队列/通道送出，门铃在 QDMA 层。
   → 上一轮"抠 PON MAC 门铃"方向错；正确方向是 **QDMA WAN 门铃**。
2. **两层驱动模型**（与我们现有 kmod-airoha-pon 思路一致）：
   - 低层 `ecnt_xpon`/`ecnt_pon_phy`：只映射寄存器 + 提供 `get/set_xpon_data` 给上层。
   - 上层 `xpon_10g` 应用层：用 QDMA 做 OMCI TX/RX、模式切换、T-CONT/GEM、PLOAM。
3. **模式枚举**：`XMCS_IF_WAN_DETECT_MODE_XGSPON`（XGSPON）/ `..._XGPON`；经
   `xmcs_set_link_detection(mode)` 写寄存器（函数在本文件外，待提取）。
4. **用户态接口**：`xpon_mci.c` 提供字符设备（OMCI 收发），对应我们 omcid2 的
   `/dev/airoha_pon` 思路——但本仓库是 `/dev/omci` 类 netdev/char 模型。

## 4. 待提取（Task #59 真正需要的）
- [ ] `v2/xpon_10g/src/gpon/gpon_dev.c` **后半段**：`gwan_prepare_tx_message` 的 2 字 QDMA
      描述符(word0[29:14]=帧长, word1[31]=OWN...) 与 **QDMA WAN 门铃寄存器地址/值**。
      （WebFetch 截断，需抓文件后段或 grep gwan_prepare_tx_message）
- [ ] `v2/xpon_10g/src/pwan/`：QDMA WAN 描述符/门铃封装（pwan_net_start_xmit）。
- [ ] `v2/xpon_map/xpon_mapping.c`：OMCI TX 相关寄存器（QDMA WAN base、doorbell offset）。
- [ ] `xmcs_set_link_detection`：XGSPON 模式寄存器写法。

## 5. 与现有工作的衔接
- 我们 kmod-airoha-pon 已 RE 出描述符字布局（PON_OMCI_TX_RE.md），与仓库 `gpon_dev.c`
  的 gwan 描述符应一致，可交叉验证。
- 现有 `omci_tx_enable` 门铃 stub（默认关闭、绝不写猜测 MMIO）保持不变，直到从上述
  来源确认 QDMA WAN 门铃基址/偏移，再以 clean-room 方式实现。
- 本仓库 6.x 风格 → 门铃若走 airoha_eth 的 QDMA（6.12 构建已含），则可落地；
  若需独立 qdma 模块，则引入 Airoha 参考 BSP 的 qdma 部分（仍 clean-room）。
