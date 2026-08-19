# wmz-packages

自定义 OpenWrt 软件包集合，**与具体源码仓库解耦**。无论你用的是 lede、官方
openwrt，还是其他衍生仓库，只要把本目录放进其 `package/` 即可参与编译。

## 目录布局

```
package/wmz-packages/
├── install.sh                 # 接入脚本（两种布局自动检测；本仓为 layout A，no-op）
├── README.md                  # 本文件
├── luci-app-wuxuroute/        # 无序路由配置：改 MAC / 主机名 / 多 SSID / OUI 伪装
└── luci-app-policyroute/      # 策略路由：按设备/端口指定出口（防关联，exit-agnostic）
```

## 用法

直接放在 lede/openwrt 源码树的 `package/wmz-packages/` 即可。lede 会自动扫描
`package/` 下所有子目录的 `Makefile`，无需额外步骤。

```sh
cd /path/to/lede
make menuconfig    # LuCI -> Applications 里即可看到 luci-app-wuxuroute / luci-app-policyroute
```

### 移植到其他 lede 仓库

如果你把 `wmz-packages/` 整个目录放在别的 lede 仓库**根目录**（不是 `package/` 下），
运行 `install.sh` 在 `package/` 建软链接入：

```sh
cd /path/to/other-lede
/path/to/wmz-packages/install.sh    # 自动建软链
# 或反向：
/path/to/wmz-packages/install.sh --remove
```

之后 `make menuconfig` → **LuCI → Applications** 里即可看到：

- `luci-app-wuxuroute`  → 网络 → 无序路由配置
- `luci-app-policyroute` → 网络 → 策略路由

## 设计原则

- **解耦**：包集中放在 `package/wmz-packages/`，不污染上游 `package/` 其它子目录。
- **联动归并**：与"网络身份"强相关的功能并进 `wuxuroute`；独立功能做独立包
  （`policyroute`、`smartqos`、`netnotify` 等），避免互相耦合。
- **出口无关（exit-agnostic）**：`policyroute` 只决定"哪个设备走哪根管子"，
  不造隧道；出口可以是多拨 `wan/wan1`、WireGuard/OpenVPN、或
  passwall/openclash 的 `utun`。

## 提交到本 fork 的约定

推送到 `wmz-lede` / `wmz-lede-multisize` 分支时，包位于 `package/wmz-packages/`
（lede 原生扫描该子目录，单次注册、无重复）；`master` 分支仅用于同步上游，
不提交自定义包。
