# wmz-packages

自定义 OpenWrt 软件包集合，**与具体源码仓库解耦**。无论你用的是 lede、官方
openwrt，还是其他衍生仓库，只要把这些目录软链进其 `package/` 即可参与编译。

## 目录布局

```
wmz-packages/
├── install.sh                 # 把本目录各包软链进 <lede>/package/（参与编译）
├── README.md                  # 本文件
├── luci-app-wuxuroute/        # 无序路由配置：改 MAC / 主机名 / 多 SSID / OUI 伪装
└── luci-app-policyroute/      # 策略路由：按设备/端口指定出口（防关联，exit-agnostic）
```

## 用法

在你的 lede / openwrt 源码根目录执行：

```sh
# 把 wmz-packages 整个目录放进源码树（git submodule / 复制 / 软链均可）
git clone <this-repo> && cp -r wmz-packages /path/to/lede/

# 或在仓库根目录建软链，让包参与编译
cd /path/to/lede
/path/to/wmz-packages/install.sh        # 默认把各包软链进 ./package/
# 或指定目标：  install.sh /absolute/path/to/lede
```

之后 `make menuconfig` → **LuCI → Applications** 里即可看到：

- `luci-app-wuxuroute`  → 网络 → 无序路由配置
- `luci-app-policyroute` → 网络 → Policy Route

## 设计原则

- **解耦**：包只放在 `wmz-packages/`，不污染上游 `package/`；通过软链接入编译。
- **联动归并**：与"网络身份"强相关的功能并进 `wuxuroute`；独立功能做独立包
  （`policyroute`、`smartqos`、`netnotify` 等），避免互相耦合。
- **出口无关（exit-agnostic）**：`policyroute` 只决定"哪个设备走哪根管子"，
  不造隧道；出口可以是多拨 `wan/wan1`、WireGuard/OpenVPN、或
  passwall/openclash 的 `utun`。

## 提交到本 fork 的约定

推送到 `wmz-lede` / `wmz-lede-multisize` 分支时，包位于仓库根的 `wmz-packages/`
目录；`master` 分支仅用于同步上游，不提交自定义包。
