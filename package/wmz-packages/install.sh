#!/bin/sh
# wmz-packages/install.sh
#
# 把 wmz-packages/ 下的包接入 lede/openwrt 构建。
#
# 两种布局都支持：
#   A) 本仓布局：wmz-packages/ 已经在 package/wmz-packages/（推荐，lede 原生扫描
#      子目录，无需软链）。此时脚本检测到已就位，自动 no-op，不会重复扫描。
#   B) 移植布局：wmz-packages/ 在仓库根。把每个含 Makefile 的子包软链进 ./package/
#      让 lede 能发现。源仍在 wmz-packages/，方便修改/打包。
#
# 用法（在 lede 仓库根目录）：
#   ./package/wmz-packages/install.sh           # 自动检测布局
#   ./package/wmz-packages/install.sh --remove  # 仅在布局 B 下移除软链
#
# 提示：本仓（wmz-lede / wmz-lede-multisize）已是布局 A，本脚本 no-op 即可，
#       不需要执行；直接 make menuconfig 即可看到 luci-app-wuxuroute 与
#       luci-app-policyroute。

set -e

# 允许从 wmz-packages/ 或 package/wmz-packages/ 调用，都能正确推断 ROOT
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
case "$SELF_DIR" in
    */package/wmz-packages) ROOT="$(cd "$SELF_DIR/../.." && pwd)" ;;
    */wmz-packages)          ROOT="$(cd "$SELF_DIR/.." && pwd)" ;;
    *)                       ROOT="$(pwd)" ;;
esac

REMOVE=0
[ "${1:-}" = "--remove" ] && REMOVE=1

# 布局 A：已经在 package/wmz-packages/ 下 → lede 原生可扫，啥都不做
if [ -d "$ROOT/package/wmz-packages" ]; then
    if [ "$REMOVE" = "1" ]; then
        echo "[wmz-packages] layout A (package/wmz-packages/) -- nothing to remove."
    else
        echo "[wmz-packages] layout A (package/wmz-packages/) -- already integrated, no-op."
        echo "  make menuconfig -> LuCI -> Applications to select packages."
    fi
    exit 0
fi

# 布局 B：仓库根有 wmz-packages/ → 在 package/ 建软链
SRC="$ROOT/wmz-packages"
DEST="$ROOT/package"

if [ ! -d "$SRC" ]; then
    echo "[wmz-packages] neither package/wmz-packages/ nor wmz-packages/ found at repo root." >&2
    exit 1
fi

mkdir -p "$DEST"

for d in "$SRC"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ -f "$d/Makefile" ] || continue
    case "$name" in
        luci-app-*|*-app-*|wuxu*|policyroute*) ;;
        *) continue ;;
    esac

    link="$DEST/$name"
    if [ "$REMOVE" = "1" ]; then
        if [ -L "$link" ]; then rm -f "$link"; echo "removed $link"; fi
        continue
    fi
    if [ -e "$link" ]; then
        echo "[wmz-packages] $link already exists, skip (run --remove first to relink)."
        continue
    fi
    ln -sfn "../wmz-packages/$name" "$link"
    echo "linked $name -> package/$name"
done

echo "done."
[ "$REMOVE" = "1" ] || echo "现在可以 'make menuconfig' 选择这些包（LuCI -> Applications）。"