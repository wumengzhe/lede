# XG-040G-MD PON 移植状态与接⼝说明（NBELB45F6727 / 福建移动）

> 目标：Nokia Bell XG-040G-MD（Airoha AN7581，九州 BOSA）刷入 OpenWrt 后**真正起光、能用光口上 OLT**。
> 本文件记录从设备出厂备份（`NBELB45F6727-...tar`）提取的事实、当前代码状态、已打通与仍未打通的环节，以及测试/下一步。

---

## 1. 设备身份（从出厂备份 `etc/omci.log` + `configs/confignew_encryption.cfg` 提取）

| 项 | 值 | 来源 |
|----|----|------|
| vendor id | `NBEL` | omci.log `vendor_id = NBEL` |
| YP Serial | `NBELB45F6727` | omci.log `YP_Serial_Num` |
| 设备型号 | `XG-040G-MD` | omci.log `Mnemonic` |
| HW 版本 | `XG040GMDV10` | omci.log `HardwareVersion` |
| SW 版本 | `NXGS1426V07t01` | omci.log / config |
| MAC | `50:3D:7F:58:25:5E` | omci.log；`X_CMCC_CustomiseName=503D7F58255E` |
| CPU | `AN7581DT` | config `X_CMCC_CPUClass` |
| Flash | `FM25G02B`（256MB SPI-NAND） | config `X_CMCC_FlashClass` |
| BOSA | 九州 `JZ243117003420` | `logs/backup/configs/bosa/cfg.bob` |
| ONU 类型 | HGU | omci.log |
| OMCC 版本 | 134 (0x86) | omci.log |
| PON 鉴权类型 | 4（LOID+密码） | config `X_ASB_COM_PONRegType=4` |
| 接入类型 | **XG-PON**（`AccessType=XGPON`, `X_CMCC_UpLinkType=XG-PON`） | config |
| OMCI 工作模式 | 3 | omci.log |
| 能力 | 16 T-CONT / 256 GEM / 160 US-PQ / 32 DS-PQ / 16 流量调度器 | omci.log `getGponConfInfo` |
| 卡片 | VEIP(slot14,type48) · GE_1000BT(slot1,type47,4口) · XGPON(slot128,type237) | omci.log |
| 光参数 | bias 10mA · modTemp 23℃ · modVolt 3.375V · Rx -45..-1dBm · Tx -0.1..10dBm | omci.log `getGponOpticalAttr` |

**福建移动上机参数（用户提供）：** SN `NBELB45F6727`、LOID `5912519971`、密码 `123456`。

**出厂默认值（仅供对照，勿直接套用）：** SLID/LOID 样本 `w0054753dw`（浙江 OPID `ZJSC`）、PLOAM 密码 `pqjb@ip6`（诺基亚默认）。`/tmp/omciini/slidinfo` 格式为 `loid:loid`，SLID 即 LOID 的 ASCII。

---

## 2. 架构（clean-room，仅用公开事实，不搬运 EcoNet 源码）

```
           用户态                                   内核态
 ┌─────────────────────────┐            ┌──────────────────────────────────┐
 │ ponmgr / omcid2 (G.988)  │  /dev/airoha_pon (ioctl SEND_OMCI / read) │
 │  - seed MIB（XG-040G-MD）│<──────────>│  kmod-airoha-pon                │
 │  - LOID/密码/序列号      │  genl "airoha_pon" (状态/激Act/PROV)      │
 │  luci-app-pon (状态页)   │<──────────>│   - TX_OFF 寄存器 → 激光 ON/OFF │
 └─────────────────────────┘            │   - PON MAC 初始化序列回放        │
                                         │   - OMCI 虚拟网口 (0x88b5)       │
                                         └──────────────┬───────────────────┘
                                                        │  真实上纤：OMCI 经 OMCI GEM 端口 + MAC CMAC DMA 投递
                                                        │  （非 PWAN 专有；见 §4-B / §4.1）
                                                        ▼
                                                  XPON PHY / 光纤 ──► OLT
```

寄存器地图（来自参考仓库 README DTSI / `ecnt_xpon.c` / `ecnt_pon_phy.c`，仅地址/偏移/位域）：
- PON MAC core `0x1fb64000`；GPON 子块 `+0x4000`、XGPON 子块 `+0x5000`、EPON 子块 `+0x6000`
- PON PHY `0x1faf0000`；`PON_PHY_FPGA_RG_TX_OFF` `0x1fa2ff24`（写 0=激光开，写 1=强制 TX off）
- OMCI 成帧：Ethernet，dst `00:00:00:00:00:02`、src `00:00:00:00:00:01`、EtherType `0x88b5`
- XGSPON OMCI 通道寄存器（相对 mac_base `0x1fb64000`，在 +0x5000 窗口内，clean-room 提取自 `xgpon_mac_reg_c_header.h` + `gpon_dvt.c`）：`GEM_PORT_CFG@0x5274`（gem_port_id[15:0]/gpid_vld[18]/gpid_cmd[31]）、`TX_OMCI_PRE_GET@0x528C`（tx_pre_get_omci_en[0]/tx_limit_get_omci_en[8]/tx_limit_get_omci_size[16:31]，DVT 值 `0x300101`）、`RX_OMCI_PRE_GET@0x5290`（rx_omci_intr_eth_en[0]，DVT 值 `0x1`）、`OMCI_LEN_CTRL@0x59BC`（max_omci_len[13:0]）、`TCONT_ID_CFG@0x5250`（wr_tcont_id[13:0]/tcont_id_index[24:20]/wr_tcont_id_vld[16]/tcont_cmd[31]）、OMCI GEM 端口号 `0x048`。
- XGSPON CMAC（AES-CMAC MIC 引擎）寄存器（相对 mac_base，**2026-08-21 经 OEM `xpon_10g.ko` 反汇编真机确认**）：`INT_STATUS@0x5044`（sw0_mic_done_int bit21=0x200000）、OMCI IK0 密钥 RAM `OIK0_0..3@0x5380..0x538C`、`SW0_ENCSTART@0x5400`（bit0=start）、`SW0_MADDR@0x5404`、`SW0_RADDR@0x5408`、`SW0_KADDR@0x540C`、`SW0_ENCLEN@0x5410`（mdtlen[15:0]/rdtlen[31:16]）、`SW0_ENCINFO@0x5414`（enckidx[18:16]/encdic[1:0]）；key 索引 `GPON_CMAC_OMCI_IDX0=2`、方向 `GPON_CMAC_UPSTREAM=2`。
- AN7581 OMCI 上行 QDMA 描述符（`gwan_prepare_tx_message` 反汇编确认）：word0 的 GEM 端口标签 bits 14..29、bit8、bit30；word1 bit31 有效位、TCONT/队列 bits 20..23 —— 与 `airoha_kernel` `QDMA_ETH_TXMSG_SP_TAG`/`QUEUE`/`CHAN` 一致。

---

## 3. 当前已打通 / 已实现

- ✅ **激光物理起光**：`hal_laser_enable()` 写 `TX_OFF=0`，real 后端 `hal_activate(1)` 调用。装上固件后光口会发光、OLT 侧能看到光功率（进 O2 待机）。
- ✅ **OMCI 守护进程骨架** `omcid2.c`：G.988 编解码、`/dev/airoha_pon` 收发、MIB-RESET/UPLOAD/UPLOAD-NEXT/CREATE/DELETE/SET/GET 处理、GEM/T-CONT 自创建、MIB 落盘。
- ✅ **seed MIB 已按 XG-040G-MD 重写**：ONU-G(256) 身份、ANI-G(263)@0x8001、16 T-CONT(262)@0x8001..0x8010、3 卡片(5)、4 UNI-G(11)@0x0101..0x0104 + VEIP UNI @0x0e01、SW(7) `NXGS1426V07t01`。
- ✅ **配置 `pon.config`**：填入 SN/LOID/密码、mode=xgpon、auth=loid，并注释出厂默认值。
- ✅ **init 脚本**：把 SN/LOID/密码/mode 经 env 传给 omcid2；modprobe 默认 `hal_backend=1`（real）。
- ✅ **LuCI 状态页**：显示 ONU 状态、模式、激光、收/发功率、偏置、温度、电压、FEC、LOS、TX-FAULT、序列号、LOID。
- ✅ **ABI 同步**：userspace `pon_abi.h` 已与内核版逐字节对齐（之前字段号错位会导致 `ponctl` 编译失败/读错），并修内核 `spin_unlock_irqirqrestore` 笔误、新增 genl `SET_PROV`。
- ✅ **PON MAC 序列号寄存器已编程**（前 session，§4-A 已闭合）：从 Airoha AN7581 XGSPON MAC 寄存器图（`xgpon_mac_reg_c_header.h`，clean-room 提取）取得 `VENDOR_ID@0x500C` / `VS_SN@0x5010`。`hal_set_serial()` 写入 `sn[0..3]→VENDOR_ID`、`sn[4..7]→VS_SN`，使 `Serial_Number_ONU` PLOAM 携带正确身份（`NBEL`+`B45F`）。
- ✅ **PON MAC OMCI 通道已配置**（本 session，§4-B 部分解决）：从 `xgpon_mac_reg_c_header.h` + `gpon_dvt.c` 提取 XGSPON OMCI 寄存器，`hal_xgpon_omci_setup()` 在 `hal_activate()` 上电路径分配 OMCI GEM 端口（0x048）、使能 `TX_OMCI_PRE_GET=0x300101` / `RX_OMCI_PRE_GET=0x1`、设 `OMCI_LEN_CTRL=53`。但 OMCI **帧数据泵**（MAC CMAC DMA 投递 48 字节 G.988 报文）仍未实现，见 §4-B。

---

## 4. 仍未打通 / 剩余阻塞点（诚实）

| 阻塞点 | 说明 | 需要什么 |
|--------|------|----------|
| **A. PON MAC 序列号寄存器** | ✅ **已闭合**（前 session）：`VENDOR_ID`/`VS_SN` 由 `hal_set_serial()` 编程。`LOID`/`密码` 不是 PON MAC 寄存器，归 OMCI 层（§4-B）。XGSPON 模式为软件态，无独立模式寄存器。 | —（已闭合） |
| **B. OMCI 帧数据泵（XGSPON）** | 🔴 **唯一剩余硬阻塞**。通道已配置（GEM 端口 0x048 + TX/RX pre-get + `OMCI_LEN_CTRL`）；**CMAC MIC 已实现**（本 session：`hal_omci_compute_mic()` 按真机确认的寄存器序列算 G.988 报文 MIC，`omci_mic_enable=1` 可上机验证）。仍缺的是把 48 字节报文**投上光纤**：OEM `xpon_10g.ko`（本机原厂固件）证实 AN7581 的 OMCI 上行走 **SoC QDMA 引擎**——`gwan_prepare_tx_message()` 构建 QDMA TX 描述符（GEM 端口标签在 bits 14..29、OAM 标志），该引擎由本树 6.12 `airoha_eth`（`CONFIG_NET_AIROHA=y`）拥有。故必须把 `airoha_kernel` 的 **`xpon_oam` 钩子**（`airoha_eth_register_xpon_oam`/`xmit_xpon_oam`，OMCI 帧经 QDMA 以 GEM 0x048 发出）回溯进本树 6.12 `airoha_eth`，并把本驱动的 OMCI 发送改挂到该钩子。 | 回溯 `xpon_oam` QDMA 钩子（见 §4.1/§6 路线 B），在用户本地 wmz-lede 编译验证。 |

> **关键结论（2026-08-21 深夜更新，已反汇编 OEM 真机驱动验证）**：所谓"PWAN 是 OMCI 上纤的硬依赖"已被证伪——OMCI 走**标准 SoC QDMA**。本 session 反汇编本机原厂固件的 `xpon_10g.ko`（`_src/stock_xg040g/rootfs/lib/modules/`，未去符号，ARM64），提取并**真机确认**了：
> - **CMAC（MIC）寄存器**：`SW0_ENCSTART@0x5400`、`SW0_ENCINFO@0x5414`（enckidx[18:16]、encdic[1:0]）、`SW0_ENCLEN@0x5410`、`SW0_MADDR@0x5404`、`SW0_RADDR@0x5408`、`INT_STATUS@0x5044`（sw0_mic_done_int bit21=0x200000）、OMCI IK0 密钥 RAM `OIK0_0..3@0x5380..0x538C`（`gponDevSetCmac0Start`/`gponDevSetOmciIk0`）——与 v2 参考头一致。
> - **OMCI 上行 = QDMA TX 描述符**（`gwan_prepare_tx_message`，0x4404c）：word0 内 GEM 端口标签在 bits 14..29、bit8、bit30；word1 bit31 有效位、TCONT/队列在 bits 20..23 —— 与 `airoha_kernel` 的 `QDMA_ETH_TXMSG_SP_TAG`/`QUEUE`/`CHAN` 模型一致。
> - **`airoha_kernel` 是 EN7523/GPON-only，不覆盖 AN7581**：其 `airoha_xpon.c` 只绑定 `airoha,en7523-xpon`/`econet,en751221-xpon`，且 gen2 `__airoha_dev_xmit()` 的 xpon OAM TX 路径硬性 `!airoha_is(eth, airoha_en7523) → goto error`。对本机（AN7581 XGSPON）不能直接用。
>
> 当前状态：光口**物理发光** + **O3/O4 序列号 ranging** + **OMCI 通道已配置** + **CMAC MIC 可算**（上机 `omci_mic_enable=1` 验证）；唯一剩余硬阻塞 = **AN7581 QDMA 数据泵**（把报文经 airoha_eth 的 QDMA 以 GEM 0x048 投上光纤），需回溯 `xpon_oam` 钩子。

### 4.1 参考仓库评估：Sirherobrine23/airoha_kernel（2026-08-21 新发现，★很有价值）

`https://github.com/Sirherobrine23/airoha_kernel` —— Linux 6.18 内核树，分支 `airoha_en7523_all`，针对 Airoha SoC（EN7523/EN7528/AN7581）整合主线程驱动。对 §4-B 的决定性价值：

- **开放 OMCI 子系统 `net/omci.h`（GPL-2.0）**：内核态 `omci_device_register(parent, ifindex, caps, ops, priv)` 向用户态 OMCI 守护进程暴露标准接口（`omci_device_xmit/receive/set_tcont/set_gem_port/...`），`airoha_gpon_omci.c` 是其 Airoha 后端实现。证明 OMCI 有**开放、标准的内核框架**，不必依赖厂商私有栈。
- **OMCI 传输 = 标准以太网 QDMA，非 PWAN**：`airoha_gpon_omci_xmit()` → `airoha_eth_xmit_xpon_oam(gdm_dev, skb, gem_port_id)`，经 `airoha_eth` 的 QDMA 引擎发出；专用 OMCI GEM 端口由 `GPON_OMCI_ID 0x048`（`OMCI_PORT_VLD | gem_port_id`）使能。这彻底推翻了"PWAN 必备"假设。
- **已克隆到本地**：`E:/WorkBuddy/OpenWrt/_src/_refs/airoha_kernel`（sparse-checkout `drivers/net/ethernet/airoha`），含 `airoha_xpon.c`(142K)、`airoha_gpon_omci.c`、`airoha_ploam.c`、`airoha_qdma.c`、`airoha_eth.c`、`net/omci.h`（经 uapi）。
- **局限（对本机 AN7581 XGSPON，本 session 反汇编判定）**：该树 **GPON/EN7523-only**——`airoha_xpon.c` 的 `of_device_id` 仅 `airoha,en7523-xpon`/`econet,en751221-xpon`；gen2 `__airoha_dev_xmit()` 的 xpon OAM TX 分支硬性 `!airoha_is(qdma->common.eth, airoha_en7523) → goto error`。**不覆盖 AN7581**，无法直接搬运。
- **本机 OpenWrt 树现状（本 session 确认）**：`target/linux/airoha` 已含 `an7581`/`an7583`/`en7523` 子目标，`CONFIG_NET_AIROHA=y`（`airoha_eth` QDMA 在 6.12 内核 + 补丁里，补丁到 v6.15/6.16 水平），但**不含 `xpon_oam`/`net/omci`/OMCI 钩子**。即 QDMA 引擎在、OMCI 钩子不在——需把 `xpon_oam`（`airoha_eth_register_xpon_oam`/`xmit_xpon_oam` + OAM RX 分发 + `QDMA_ETH_TXMSG_OAM`/SP_TAG 位域，去 EN7523 门控）作为补丁回溯进 6.12 `airoha_eth`。

**结论**：`airoha_kernel` 是 §4-B 的"地图"，证明了正确架构（开放以太网 QDMA + OMCI GEM 端口 + `net/omci` 框架），但它本身只实现 EN7523/GPON；本机 AN7581 XGSPON 的最后一公里（把 `xpon_oam` 钩子去 EN7523 门控地回溯进本树 6.12 `airoha_eth`，再让本驱动挂到该钩子）仍需在编译/上机中迭代（见 §6 路线 B）。



---

## 5. 编译与测试

```sh
# 在 wmz-lede 仓库根
make package/kernel/airoha-pon/{clean,compile} V=s
make package/network/config/pon-manager/{clean,compile} V=s
make package/luci/applications/luci-app-pon/{clean,compile} V=s

# 上机后
logread | grep airoha_pon     # 确认 real 后端 probe、TX_OFF 映射
ponctl status                 # 看 state / laser / 收光
# 期望：laser=1，插纤后 rx_power 从 -40 上升（若 OLT 已发光）
# 若 state 长期 O2/O3：多半卡在 §4-A（序列号/密码未编程）或 §4-B（无 OMCI 上纤）
```

---

## 6. 下一步（按价值排序）

1. ✅ **PON MAC 序列号寄存器**（§4-A）——已闭合：`hal_set_serial()` 编程 `VENDOR_ID`/`VS_SN`。
2. ✅ **PON MAC OMCI 通道配置**——已落地：`hal_xgpon_omci_setup()` 分配 OMCI GEM 端口 + 使能 TX/RX pre-get + `OMCI_LEN_CTRL`。
3. ✅ **CMAC MIC 计算**——本 session 已落地：`hal_omci_compute_mic()`（真机确认寄存器 `SW0_ENCSTART@0x5400`/`ENCINFO@0x5414`/`INT_STATUS@0x5044`/`OIK0@0x5380`）+ `hal_omci_set_ik0()`；上机 `omci_mic_enable=1` 后 `logread` 应见 `OMCI MIC OK len=.. mic=..`（证明 MAC 引擎/DMA/IK 存活）。
4. **🔴 AN7581 QDMA 数据泵（§4-B 唯一剩余硬阻塞）——路线 B（推荐）**：把 `airoha_kernel` 的 **`xpon_oam` 钩子**回溯进本树 6.12 `airoha_eth`（`airoha_eth_register_xpon_oam`/`unregister_xpon_oam`/`xmit_xpon_oam` + OAM RX 分发，去掉 `!airoha_is(eth, airoha_en7523)` 门控，使 AN7581 可用），然后本驱动 `hal_send_omci()` real 分支改挂 `airoha_eth_xmit_xpon_oam(gdm_ndev, skb, 0x048)`；OMCI 下行把 QDMA 收到的 OAM 帧经 `omci_packet_rcv` 送入 `/dev/airoha_pon` read()。**这一步需要你的本地 wmz-lede 编译环境配合**（内核补丁无法在本沙箱编译验证，需在真机/构建机上迭代）。备选路线 A：向 Airoha 要 AN7581 xpon 驱动（v2/xpon_10g 私有 QDMA 路径）。
5. OMCI 下行接收（随路线 B 一并完成）。
6. 用本设备出厂 `omci.log` 对照补全 G.988 ME 属性表，提高 MIB-UPLOAD 通过率。
7. `ponctl` 增加 `apply` 时经 `SET_PROV` 下发 mode/fec/serial（handler 已就位）。
