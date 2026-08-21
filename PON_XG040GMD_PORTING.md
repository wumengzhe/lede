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
                                                        │  ⚠ 真实上纤需 Airoha PWAN QDMA 后端
                                                        ▼
                                                  XPON PHY / 光纤 ──► OLT
```

寄存器地图（来自参考仓库 README DTSI / `ecnt_xpon.c` / `ecnt_pon_phy.c`，仅地址/偏移/位域）：
- PON MAC core `0x1fb64000`；GPON 子块 `+0x4000`、XGPON 子块 `+0x5000`、EPON 子块 `+0x6000`
- PON PHY `0x1faf0000`；`PON_PHY_FPGA_RG_TX_OFF` `0x1fa2ff24`（写 0=激光开，写 1=强制 TX off）
- OMCI 成帧：Ethernet，dst `00:00:00:00:00:02`、src `00:00:00:00:00:01`、EtherType `0x88b5`

---

## 3. 当前已打通 / 已实现

- ✅ **激光物理起光**：`hal_laser_enable()` 写 `TX_OFF=0`，real 后端 `hal_activate(1)` 调用。装上固件后光口会发光、OLT 侧能看到光功率（进 O2 待机）。
- ✅ **OMCI 守护进程骨架** `omcid2.c`：G.988 编解码、`/dev/airoha_pon` 收发、MIB-RESET/UPLOAD/UPLOAD-NEXT/CREATE/DELETE/SET/GET 处理、GEM/T-CONT 自创建、MIB 落盘。
- ✅ **seed MIB 已按 XG-040G-MD 重写**：ONU-G(256) 身份、ANI-G(263)@0x8001、16 T-CONT(262)@0x8001..0x8010、3 卡片(5)、4 UNI-G(11)@0x0101..0x0104 + VEIP UNI @0x0e01、SW(7) `NXGS1426V07t01`。
- ✅ **配置 `pon.config`**：填入 SN/LOID/密码、mode=xgpon、auth=loid，并注释出厂默认值。
- ✅ **init 脚本**：把 SN/LOID/密码/mode 经 env 传给 omcid2；modprobe 默认 `hal_backend=1`（real）。
- ✅ **LuCI 状态页**：显示 ONU 状态、模式、激光、收/发功率、偏置、温度、电压、FEC、LOS、TX-FAULT、序列号、LOID。
- ✅ **ABI 同步**：userspace `pon_abi.h` 已与内核版逐字节对齐（之前字段号错位会导致 `ponctl` 编译失败/读错），并修内核 `spin_unlock_irqirqrestore` 笔误、新增 genl `SET_PROV`。
- ✅ **PON MAC 序列号寄存器已编程**（本 session，§4-A 部分解决）：从 Airoha AN7581 XGSPON MAC 寄存器图（`xgpon_mac_reg_c_header.h`，clean-room 提取）取得 `VENDOR_ID@0x500C` / `VS_SN@0x5010`（偏移相对 PON MAC core `0x1fb64000`，已含 +0x5000 XGSPON 窗口基）。`hal_set_serial()` 在 `hal_activate()` 与 genl `SET_PROV`（`serial_no`）两条路径写入 `sn[0..3]→VENDOR_ID`、`sn[4..7]→VS_SN`，使 O3/O4 ranging 的 `Serial_Number_ONU` PLOAM 携带正确身份（`NBEL`+`B45F`）。XGSPON 模式为软件态（参考默认 XGSPON），无独立模式寄存器需写。

---

## 4. 仍未打通（诚实的上机阻塞点）

| 阻塞点 | 说明 | 需要什么 |
|--------|------|----------|
| **A. PON MAC 序列号寄存器** | ✅ **本 session 已解决**：`VENDOR_ID`/`VS_SN` 由 `hal_set_serial()` 编程（见上）。`LOID`/`密码` **不是 PON MAC 寄存器**——它们是 OMCI 层语义（ONU2-G ME 的 Password 属性、LOID 经 OMCI 下发），归 §4-B 的传输通道负责；XGSPON 模式为软件态（默认 XGSPON），无需专门寄存器。 | —（已闭合） |
| **B. OMCI 真实上纤传输（PWAN QDMA）** | OMCI 帧已按 `0x88b5` 封装并经虚拟 `omci` 网口，但 `ndo_start_xmit` 当前丢帧并标 `PWAN TODO`——Airoha 私有 PWAN QDMA 子系统（`v2/xpon_10g/src/pwan`）未开源，无法 clean-room 复刻。OLT 鉴权（LOID/密码）与 MIB 协商全部走 OMCI，因此 **§4-B 是上机真正“用起来”的唯一硬阻塞**。 | 要么引入 Airoha 的 PWAN 后端（专有，需授权），要么找到不走 QDMA 的 OMCI DMA 通道（如参考 `pwan/gpon_wan.c` 中是否暴露独立 OMCI ring）。 |

> 结论：**当前代码能让光口“物理发光”（OLT 看得到光），并完成 O3/O4 序列号 ranging（序列号已编程）；但无法完成与 OLT 的 GTC 注册下行的 LOID/密码鉴权 + OMCI 协商**，因为 §4-B 的 OMCI 上纤传输尚未取得。这是上机真正“用起来”的硬阻塞，不是配置问题。



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

1. ✅ **PON MAC 序列号寄存器**（§4-A）——本 session 已闭合：`hal_set_serial()` 编程 `VENDOR_ID`/`VS_SN`，由 genl `SET_PROV`(`serial_no`) 或 `hal_activate()` 触发。
2. **确认/接入 OMCI 传输通道**（§4-B，唯一剩余硬阻塞）：优先反汇编/审阅 `v2/xpon_10g/src/pwan/gpon_wan.c` 与 `xpon_netif.c`，确认 AN7581 是否暴露可绕过 PWAN QDMA 的 OMCI 专用 DMA ring；否则需 Airoha 授权后端（PWAN 固件/驱动）。
3. 用本设备出厂 `omci.log` 对照补全 G.988 ME 属性表（卡片/ANI-G 光阈值等），提高 MIB-UPLOAD 通过率。
4. `ponctl` 增加 `apply` 时经 `SET_PROV` 下发 mode/fec/serial（handler 已就位）。
