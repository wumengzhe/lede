# luci-app-policyroute

OpenWrt **源地址策略路由**面板。按 **设备（MAC / IP / DHCP 主机名）或目的端口**
把流量导向指定**出口接口**。专为「防关联 / 多设备隔离 / 多线分流」场景设计，
**exit-agnostic（出口无关）**——不依赖任何代理软件也能用。

## 适用场景

- **跨境电商防关联**：每个店铺设备固定走不同出口（不同住宅代理 / 不同 VPN / 不同宽带）。
- **游戏代练多账号隔离**：每台设备、每个号走独立出口，互不串 IP。
- **多宽带 / 多 VPN 分流**：按设备或服务把流量指到 `wan` / `wan1` / `wg0` / `tun0`。
- **主备切换兜底**：某出口不可达时，规则仍可回退到主路由表。

## 出口从哪来（关键设计）

面板**不自己建隧道**。它启动时自动枚举当前系统里所有可用的出口接口并列出供你选：

| 出口类型 | 典型接口 | 由谁创建 |
|---|---|---|
| 多拨宽带 | `wan` `wan1` | mwan3 / 多 WAN |
| 原生 VPN | `wg0` `tun0` | WireGuard / OpenVPN |
| 代理隧道 | `utun` | passwall / openclash（**需 TUN 模式**） |

所以：
- **没有 passwall/openclash 也能用**（多拨 + 原生 VPN 即可）。
- **有 passwall/openclash 也不冲突**：它们管「管子里的流量哪些域名绕、哪些直连」（L7），
  本面板管「这台设备从哪根管子出去」（L3/L4），两者是上下游。

> 注意：要把某设备路由进代理隧道，代理必须开 **TUN 模式**（生成真实 `utun` 接口）。
> 纯 TProxy / 重定向模式的代理没有可路由的接口，本面板指不进去，此时
> per-client 路由只能靠代理自身的访问控制。

## 机制

```
设备流量 ──nftables 打 mark（按 源MAC/IP/端口）──▶ ip rule fwmark ──▶ 每出口独立路由表
```

- `nftables` 在 `prerouting`（mangle）按源匹配并打 mark；
- `ip rule fwmark` 把带 mark 的包查对应的出口路由表；
- 每条出口接口对应一张独立路由表（复用代理已有的表，或新建 `table 200+` 并写默认路由）。

规则绑定**稳定标识**（静态租约名 / 固定 IP / 设备名）比裸 MAC 更稳：
若配合 `luci-app-wuxuroute` 重启随机化 MAC，建议策略按 IP/主机名绑定，避免 MAC 一变规则失效。

## 用法

1. `make menuconfig` → **LuCI → Applications → luci-app-policyroute**
2. 网络 → **策略路由**
3. 勾选启用 → 在「路由规则」里增删规则：
   - 源类型：`MAC 地址` / `IP 地址` / `DHCP 主机名`
   - 源值：对应值
   - 协议 / 目的端口：可选，做服务级分流
   - 出口接口：从自动枚举的出口里选
4. 保存并应用（自动下发 nftables + ip rule）。

## 依赖

`nftables` + `ip-full` + `kmod-nft-core`（OpenWrt 22.03+ 默认 nftables）。

## 命令行

```sh
/usr/sbin/policyroute list-ifaces    # 列出可用出口接口
/usr/sbin/policyroute list-devices   # 列出 LAN 设备
/usr/sbin/policyroute status         # 查看当前生效的 mark/table
/usr/sbin/policyroute apply          # 依据 UCI 重建规则
/usr/sbin/policyroute stop           # 清除本面板创建的全部规则/路由
```
