# PON OMCI TX 描述符逆向证据（Task #59 基础）

> 来源：`_src/_refs/an7581-tclinux/modules/xpon_10g.ko`（stock tclinux，k5.4.55，ARM64 LE）
> 工具：capstone 5.0.7（`_src/_refs/an7581-tclinux/disasm_xpon.py` / `disasm_tx_full.py` / `disasm_resolve.py`）
> 日期：2026-08-21

## 1. 结论速览

- OMCI 帧由 `gwan_prepare_tx_message()` 构造一个 **2 字（8 字节）QDMA 风格描述符**，再交给一个
  **外部/重定位（relocated）符号** 完成"写环 + 敲门铃"提交。该提交函数 **不在 xpon_10g.ko 自身符号表内**
  （被剥离），说明 OMCI 的 DMA 提交走的是主 Airoha 驱动导出的 API，而非本模块自包含实现。
- 描述符 **字布局已完全确认**（见 §3）。
- **最后一块未知**：提交函数的敲门铃（doorbell）寄存器地址 / 描述符环基址。它位于被重定位调用的
  目标里，需要 (a) 主 airoha_eth / airoha 平台驱动导出的符号名，或 (b) 实机寄存器 dump / Airoha SDK。
  **不能在无硬件 + 无 SDK 的情况下安全猜测**。

## 2. 函数边界

```
gwan_prepare_tx_message: ELF 0x440a4  size 3280   (file off 相同，.text base = 0)
gwan_process_rx_message : ELF 0x44f58  size 2388
```

`xpon_10g.ko` 引用的外部符号中与提交相关者有：`get_xpon_data` / `set_xpon_data` /
`get_xpon_dev` / `get_xpon_irq` / `qdma_wan_fwd_timer` / `dma_alloc_attrs` 等。
**没有任何** `omci_send` / `xpon_tx` / `airoha_qdma_*` 之类导出符号——印证提交走的是
`gwan_prepare_tx_message` 内部通过 `bl #0x...` 调用的、目标为 0（待重定位）的外部函数。

> 注：`bl #0x44378` 这类 capstone 输出其实是"立即数为 0、尚未应用模块重定位"的假象
> （目标 = PC），真实目标在 `insmod` 时由重定位项填入。因此这些分支是**去往外部 API 的调用**，
> 不是函数内基本块跳转。

## 3. 已确认的描述符字布局

`gwan_prepare_tx_message` 的描述符指针是 arg0（`[sp,#0x28]`）。实测位操作（AArch64 `bfi`/`and`/`orr`）：

### word0（偏移 0）

| 位域 | 值 | 来源 |
|------|-----|------|
| [29:14] | 16-bit 长度 | `bfi w0, w2, #14, #16`，w2 取自全局结构 `*(gptr+0x36a)` 的 16-bit 字段（TX 字节数）|
| [8]    | 1 | `orr w1, w1, #0x100`（arg1==1 即"OMCI 消息"分支）|
| [2:0]  | 保留 | `word0 & 0xffffff07` 仅保留 [2:0] 与 [31:8]，其余清零 |
| 其余   | 0 | 同上掩码清零 |

等价 C：
```c
desc->word0 = ((len & 0xFFFF) << 14) | (1u << 8);   /* len = OMCI 帧长(≤1980) */
```

### word1（偏移 4）

| 位域 | 值 | 来源 |
|------|-----|------|
| [31]   | 1 (OWN) | `orr w1, w1, #0x80000000` |
| [30:24]| 0x7f | `bfi w0, w2, #24, #7`，w2 = 局部 0x33（入口初值 0x7f，疑来自 OMCI 头）|
| [23:20]| 0x2 | `bfi w0, w2, #20, #4`，w2 = 2（入口固定，疑为队列/通道号 = 2）|
| [19:11]| 0 | `word1 & 0xfff07fff` 清零 |
| [10:6] | 0x1f | `bfi w0, w2, #6, #5`，w2 = 局部 0x32（入口初值 0x1f）|
| [5:0]  | 0x1f | `bfxil w0, w2, #0, #6`，w2 = 局部 0x31（入口初值 0x1f）|

等价 C：
```c
desc->word1 = (1u << 31) | (0x7f << 24) | (0x2 << 20) | (0x1f << 6) | (0x1f << 0);
```

> 局部 0x31/0x32/0x33 在函数入口被置为 0x1f/0x1f/0x7f，后续可能由调用方填入的 OMCI 消息头覆盖
> （完整反汇编在 0x444a8 之后还有一段，未在本轮抓取——见 `disasm_tx_full.py` 全量）。
> 首版实现暂用观测到的默认值。

### 提交调用（doorbell 候选）

主路径在构造完描述符后（约 0x44348）：
```
ldr  x1, [gptr]          ; gptr = 模块全局结构（0x44000 页），含 DMA 环指针
ldr  w2, [arg2 + 0x70]   ; arg2 是 OMCI 消息结构，0x70 偏移 = 待发送缓冲区指针/长度
ldr  w3, [desc]          ; word0
ldr  w0, [desc + 4]      ; word1 (→ w4)
bl   <重定位外部符号>    ; 真正的"写环 + 敲门铃"提交
```
即提交函数原型约为 `submit(gptr, word0, word1, buf_ptr)`。

## 4. RX 指示路径

`gwan_process_rx_message`（0x44f58）承担 OMCI 指示/告警的接收。其内部同样通过 `bl #0x...`
（重定位）去往外部 API 取 RX 完成。本驱动 `/dev/airoha_pon` 的 `read()` 目前由 `ind_fifo`
（内核 FIFO）供给，RX 真实来源需把"MAC 收到的 OMCI 帧"塞进该 FIFO——这部分也依赖上述
外部 RX DMA API，同样待 §5 的 unknown 解决。

## 5. 待解决（blocker）

1. **提交函数的外部符号名 / 门铃寄存器**：需要确认 `gwan_prepare_tx_message` 内部 `bl` 的真实目标。
   两条现实路径：
   - (A) 主 `airoha_eth` / `airoha` 平台驱动导出某 `omci`/`xpon` 发送符号 → kmod-airoha-pon 依赖它调用；
   - (B) 拿到 Airoha AN7581 SDK 或实机 `/sys/kernel/debug` 寄存器 dump，手工填门铃基址。
2. **描述符环基址**：全局结构 `*(0x44000 页)` 的环指针需定位（模块加载后由主驱动填充）。
3. **硬件验证**：以上任何实现都必须在该机型 + 福建移动 OLT 上实测，无法离线验证。

## 6. 当前驱动状态（2026-08-21）

`airoha_pon.c::hal_send_omci()` 的 real 后端已据本节字布局**构造描述符**，但提交（门铃）仍为
单点 `TODO`，默认返回 `-EOPNOTSUPP`（带明确 dev_warn 指向本文件），**不写任何猜测性 MMIO**，
确保驱动在未知硬件上安全可加载。启用需设置模块参数 `omci_tx_enable=1`（填好门铃后）。
