# luci-app-wuxuroute

OpenWrt LuCI 插件：一键修改 WAN/LAN/WiFi MAC 地址、LAN IP、主机名。

支持：
- 一键随机所有 MAC / 主机名 / LAN IP
- 单独随机某一项
- 立即应用（写入配置 + reload 网络/无线）
- 立即重启（写入配置 + 3 秒后重启设备）
- **重启自动更新**：勾选后每次开机自动重新生成指定项

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
    │   │   ├── controller/wuxuroute.lua     # 路由 + 7 个子命令
    │   │   └── model/cbi/wuxuroute.lua      # CBI 表单 + JS 工具栏
    │   └── sbin/wuxuroute                   # 后端主程序
    └── etc/
        ├── config/wuxuroute                 # UCI 默认配置
        └── init.d/wuxuroute                 # 启动时按 auto_* 自动生成
```

## 依赖

- `luci-base`（LuCI 基础）
- `uci`（UCI 命令）
- `coreutils`（`hexdump` 等）

`coreutils-macaddr`/`uboot-envtools` 等不需要；随机 MAC 用 `/dev/urandom` 自实现。

## 工作流

1. 用户打开 **网络 → 无序路由配置**
2. 页面加载时自动调用 `/get` 获取当前值并回填
3. 用户点击各字段旁的"随机 X"按钮 → JS 调 `/gen_mac` 等 → 回填输入框
4. 用户点"保存并应用" → JS 把所有值 POST 给 `/apply` → 后端写入 `/etc/config/network`、`/etc/config/wireless`、`/etc/config/system` 并 reload 网络/无线
5. 用户点"保存并重启" → 类似但额外触发 `/sbin/reboot`
6. 勾选"开机更新 X"后 → 设备下次启动 `/etc/init.d/wuxuroute` 自动按勾选项重新生成

## 故障排查

- **"随机 MAC 地址"按钮不生效**：浏览器控制台查看是否有 JS 错误。最常见是 LuCI 缓存了旧 lua 模板，清浏览器缓存或 `rm /tmp/luci-indexcache` 后重试。
- **保存后无线没变**：`/etc/config/wireless` 里 wifi-iface 节点可能没识别到 band（2G/5G），看后端 `wuxuroute get` 是否能列出两个 radio。
- **开机更新不生效**：检查 `/etc/init.d/wuxuroute enabled`、日志 `logread -e wuxuroute`。
- **想完全清空手动 MAC**：页面底部（危险操作区域之外）也可在 ssh 用 `wuxuroute factory-reset`，或手动 `uci delete network.wan.macaddr` 等。

## 卸载

```bash
opkg remove luci-app-wuxuroute
```

配置会保留在 `/etc/config/wuxuroute`。
