# luci-app-wuxuroute

OpenWrt LuCI 插件：一键修改 WAN/LAN/WiFi MAC 地址、LAN IP、主机名。

支持：
- 一键随机所有 MAC / 主机名 / LAN IP
- 单独随机某一项
- **多 SSID 支持**：自动读取所有 WiFi 信号（2.4G / 5G / 访客 / IoT…数量不限），每个 SSID 单独设置 MAC
- **MAC 厂商伪装**：随机 MAC 时可伪装成 Apple / Xiaomi / Huawei / Samsung / TP-Link 等厂商前缀，让路由器看起来像普通终端
- 立即应用（写入配置 + reload 网络/无线）
- 立即重启（写入配置 + 3 秒后重启设备）
- **恢复出厂 MAC**：一键清空所有手动 MAC，回到硬件原始地址
- **重启自动更新**：勾选后每次开机自动重新生成指定项
- **定时自动更新**：通过 cron 每天 / 每周自动重新生成（无需重启）
- **实时状态显示**：页面底部展示当前配置值 vs 系统实际生效的 MAC

## 在 lede 源码中编译

1. 复制整个 `wuxuroute/` 目录到 lede 源码的 `package/` 目录下：

   ```bash
   # 假设 lede 源码在 ~/lede/
   cp -r package/wuxuroute ~/lede/package/
   ```

2. 回到 lede 根目录：

   ```bash
   cd ~/lede
   ./scripts/feeds update -a   # 第一次需要，更新 feeds 索引
   ./scripts/feeds install -a  # 可选，让 LuCI base 依赖就绪
   make menuconfig
   ```

3. 在 `menuconfig` 中选择：

   ```
   LuCI ─── Applications
       <*> luci-app-wuxuroute............ Wuxu Route Config (MAC/Hostname randomizer)
   ```

4. 编译：

   ```bash
   make package/luci-app-wuxuroute/compile V=s
   # 或全量
   make V=s -j$(nproc)
   ```

编译后产出的 ipk 在 `bin/packages/<arch>/luci/luci-app-wuxuroute_1.0.0-1_all.ipk`，
全量编译时会被一并刷入固件。

## 菜单位置

- 路径：**网络 → 无序路由配置**（Network → Wuxu Route Config）
- URL：`/cgi-bin/luci/admin/network/wuxuroute`

## 文件清单

```
wuxuroute/
├── Makefile
├── LICENSE
├── README.md
└── files/
    ├── usr/
    │   ├── lib/lua/luci/
    │   │       ├── controller/wuxuroute.lua     # 路由 + 子命令（gen_mac/gen_hostname/get/list_wifi/status/apply/reboot/factory_reset）
    │   │   └── model/cbi/wuxuroute.lua      # CBI 表单 + 动态 WiFi + JS 工具栏
    │   └── sbin/wuxuroute                   # 后端主程序
    └── etc/
        ├── config/wuxuroute                 # UCI 默认配置
        └── init.d/wuxuroute                 # 启动时按 auto_* 自动生成
```

## 依赖

- `luci-base`（LuCI 基础）
- `uci`（UCI 命令）
- `coreutils`（`hexdump` 等）
- **定时更新需要 `cron`**：多数 OpenWrt 固件自带 busybox `crond` 与 `/etc/init.d/cron`。插件会自动 `enable` 并 `restart` cron。若固件精简掉了 cron，定时更新不会生效（不影响其它功能）。

`coreutils-macaddr`/`uboot-envtools` 等不需要；随机 MAC 用 `/dev/urandom` 自实现。

## 工作流

1. 用户打开 **网络 → 无序路由配置**
2. 页面加载时自动调用 `/get`（回填值）与 `/status`（展示实际生效 MAC）
3. 后端 `/list-wifi` 枚举所有 `wifi-iface` 段，界面按 SSID 数量动态生成每行 MAC + 随机按钮
4. 用户点击各字段旁的"随机 X"按钮 → JS 调 `/gen_mac`（可带 `oui` 厂商伪装）→ 回填输入框
5. 用户点"保存并应用" → JS 把所有值（含每个 WiFi SSID）POST 给 `/apply` → 后端写入 `/etc/config/network`、`/etc/config/wireless`、`/etc/config/system` 并 reload 网络/无线
6. 用户点"保存并重启" → 类似但额外触发 `/sbin/reboot`
7. 勾选"开机更新 X"后 → 设备下次启动 `/etc/init.d/wuxuroute` 自动按勾选项重新生成
8. 设置"定时自动更新" → 后端写 `/etc/crontabs/root` 并启用 cron，周期性重跑开机更新逻辑

## 故障排查

- **"随机 MAC 地址"按钮不生效**：浏览器控制台查看是否有 JS 错误。最常见是 LuCI 缓存了旧 lua 模板，清浏览器缓存或 `rm /tmp/luci-indexcache` 后重试。
- **WiFi MAC 改了但某 SSID 没变**：确认该 SSID 在 `/etc/config/wireless` 是独立 `wifi-iface` 段（桥接/相同 ifname 的多个 SSID 共享一个 MAC，属正常）。
- **实时状态里"实际"显示 none**：该 WiFi 当前未启动（未 connect），硬件地址需无线 up 后才可读到。
- **开机/定时更新不生效**：检查 `/etc/init.d/wuxuroute enabled`、日志 `logread -e wuxuroute`；定时还需 `logread | grep cron` 确认 cron 在跑。
- **想完全清空手动 MAC**：页面点"恢复出厂 MAC"，或 ssh 用 `wuxuroute factory-reset`。

## 卸载

```bash
opkg remove luci-app-wuxuroute
```

配置会保留在 `/etc/config/wuxuroute`。
