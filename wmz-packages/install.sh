#!/bin/sh
# wmz-packages/install.sh
#
# 把 wmz-packages/ 下的每个 OpenWrt 包软链进仓库的 package/ 目录，
# 使其参与 `make` 编译。源码始终留在 wmz-packages/（解耦、可移植），
# package/ 下只是相对软链，方便以后整套搬到任意仓库（不限于 lede）。
#
# 用法（在 lede 仓库根目录执行）：
#   ./wmz-packages/install.sh
#   ./wmz-packages/install.sh --remove   # 仅移除软链，不动 wmz-packages/

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/wmz-packages"
DEST="$ROOT/package"

REMOVE=0
[ "${1:-}" = "--remove" ] && REMOVE=1

mkdir -p "$DEST"

for d in "$SRC"/*/; do
	[ -d "$d" ] || continue
	name="$(basename "$d")"
	# 只软链含 Makefile、且看起来像 OpenWrt 包的目录
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
	# 相对软链，保证仓库任意克隆位置都能解析
	ln -sfn "../wmz-packages/$name" "$link"
	echo "linked $name -> package/$name"
done

echo "done."
[ "$REMOVE" = "1" ] || echo "现在可以 'make menuconfig' 选择这些包（LuCI -> Applications）。"
