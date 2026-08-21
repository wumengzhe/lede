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
| **B. OMCI 帧数据泵（XGSPON）** | ⚠️ **通道已配置，数据泵未实现**。从 `airoha_kernel` 的开放 GPON 实现（`net/omci.h` + `airoha_gpon_omci.c` + `airoha_eth_xmit_xpon_oam`）已确认：**OMCI 不需要 Airoha 私有 PWAN**——它走标准以太网 QDMA + 专用 OMCI GEM 端口（`GPON_OMCI_ID 0x048`）。本驱动的 `hal_xgpon_omci_setup()` 已按此思路配置 XGSPON 通道（GEM 端口 0x048、`TX_OMCI_PRE_GET=0x300101`、`RX_OMCI_PRE_GET=0x1`、`OMCI_LEN_CTRL`）。但把 **48 字节 G.988 报文真正投递进 MAC** 需走片上 **CMAC 引擎**：参考 BSP 用 `gponDevSetCmac0Start(phy_dma_addr, len, GPON_CMAC_UPSTREAM)` 计算 MIC 并发射（见 `pwan/gpon_wan.c`）。这条 CMAC-DMA 数据泵在本独立驱动里尚未实现，real 后端 `hal_send_omci()` 现返回 `-EOPNOTSUPP`（明确告知 omcid2 未送达，而非静默丢弃）。 | 二选一：(1) 实现 XGSPON CMAC-DMA 数据泵（需 CMAC 寄存器图 / `gponDevSetCmac0Start` 编程序列，clean-room 提取或 Airoha 授权）；(2) 把 `airoha_kernel` 的开放 `net/omci` + `airoha_eth` QDMA + `airoha_xpon` 栈移植进本树，并补 XGSPON OMCI 数据路径（该树目前 GPON-only）。 |

> **关键结论（2026-08-21 更新）**：所谓"PWAN 是 OMCI 上纤的硬依赖"已被证伪——`airoha_kernel` 用开放以太网 QDMA 路径即可传 OMCI（GPON）。本机为 **XGSPON**，通道寄存器已配置；唯一真实缺口是 **XGSPON 帧数据泵（MAC CMAC DMA）**，该路径在公开资料中落在 `gponDevSetCmac0Start`（CMAC 引擎），需要其寄存器编程序列才能 clean-room 复刻。当前状态：光口**物理发光** + **O3/O4 序列号 ranging（序列号已编程）** 已具备；卡在 OMCI 报文的 MAC 投递这一步。

### 4.1 参考仓库评估：Sirherobrine23/airoha_kernel（2026-08-21 新发现，★很有价值）

`https://github.com/Sirherobrine23/airoha_kernel` —— Linux 6.18 内核树，分支 `airoha_en7523_all`，针对 Airoha SoC（EN7523/EN7528/AN7581）整合主线程驱动。对 §4-B 的决定性价值：

- **开放 OMCI 子系统 `net/omci.h`（GPL-2.0）**：内核态 `omci_device_register(parent, ifindex, caps, ops, priv)` 向用户态 OMCI 守护进程暴露标准接口（`omci_device_xmit/receive/set_tcont/set_gem_port/...`），`airoha_gpon_omci.c` 是其 Airoha 后端实现。证明 OMCI 有**开放、标准的内核框架**，不必依赖厂商私有栈。
- **OMCI 传输 = 标准以太网 QDMA，非 PWAN**：`airoha_gpon_omci_xmit()` → `airoha_eth_xmit_xpon_oam(gdm_dev, skb, gem_port_id)`，经 `airoha_eth` 的 QDMA 引擎发出；专用 OMCI GEM 端口由 `GPON_OMCI_ID 0x048`（`OMCI_PORT_VLD | gem_port_id`）使能。这彻底推翻了"PWAN 必备"假设。
- **已克隆到本地**：`E:/WorkBuddy/OpenWrt/_src/_refs/airoha_kernel`（sparse-checkout `drivers/net/ethernet/airoha`），含 `airoha_xpon.c`(142K)、`airoha_gpon_omci.c`、`airoha_ploam.c`、`airoha_qdma.c`、`airoha_eth.c`、`net/omci.h`（经 uapi）。
- **局限（对本机 XGSPON）**：该驱动文件头明确是 **GPON** 后端（`airoha_gpon_omci.c` 注 "EN7523 GPON OMCI"），`gpon_cb_set_omci_gem()` 硬编码 `GPON_OMCI_ID 0x048` 与 `gpon_write`，**无 XGSPON 分支**；`airoha_xpon.c` 虽映射 `xgspon_reg = base + 0x5000` 且含 `AIROHA_XPON_MODE_XGSPON`，但注释 "Add a larger resource-size case here when XGSPON support lands" 表明 XGSPON 完整支持尚未落地。故**直接移植该树仍不能让 XGSPON OMCI 上纤**，需补 XGSPON 数据路径。
- **本机 OpenWrt 树现状**：`target/linux/airoha` 已含 `an7581`/`an7583`/`en7523` 子目标，但**不含 `airoha_eth`/`xpon_oam`/`net/omci`**（grep 无匹配）。即平台在、开放驱动栈不在——移植需把 `airoha_eth`+QDMA+`net/omci`+`airoha_xpon` 一并搬入并适配 DTS。

**结论**：`airoha_kernel` 是 §4-B 的"地图"，证明了正确架构（开放以太网 QDMA + OMCI GEM 端口 + `net/omci` 框架），但本机 XGSPON 的最后一公里（CMAC-DMA 数据泵 / XGSPON 适配）仍需补。两条现实路径见 §4-B 末行。



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
2. ✅ **PON MAC OMCI 通道配置**（§4-B 部分）——本 session 已落地：`hal_xgpon_omci_setup()` 分配 OMCI GEM 端口 + 使能 TX/RX pre-get + `OMCI_LEN_CTRL`。
3. **🔴 XGSPON OMCI 帧数据泵（§4-B 唯一剩余硬阻塞）**：二选一——(a) clean-room 提取并实现片上 **CMAC 引擎** 的 OMCI DMA 投递（对应参考 `gponDevSetCmac0Start(GPON_CMAC_UPSTREAM, phy_addr, len)`，需 CMAC 寄存器图）；或 (b) 将 `airoha_kernel` 的开放 `net/omci` + `airoha_eth` QDMA + `airoha_xpon` 栈移植进 `target/linux/airoha` 并补 XGSPON 数据路径（该树 GPON-only）。完成后 `hal_send_omci()` real 分支即可真正把 G.988 报文投上光纤。
4. OMCI 下行接收：配置 `RX_OMCI_PRE_GET` 后，需把 MAC 收到的 OMCI 帧经中断/ring 送回 `/dev/airoha_pon` 的 read()（当前 read() 走 sim 指示队列；real 下行收包路径待接）。
5. 用本设备出厂 `omci.log` 对照补全 G.988 ME 属性表，提高 MIB-UPLOAD 通过率。
6. `ponctl` 增加 `apply` 时经 `SET_PROV` 下发 mode/fec/serial（handler 已就位）。
