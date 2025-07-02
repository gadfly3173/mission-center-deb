#!/bin/bash
set -e

# 获取版本信息
VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

# 设置构建目录
BUILD_DIR="$PWD/build"
PACKAGE_DIR="mission-center_${VERSION}_amd64"
DEB_ROOT="$PWD/$PACKAGE_DIR"

echo "Building Mission Center $VERSION..."

# 清理之前的构建
rm -rf "$BUILD_DIR" "$PACKAGE_DIR" "$PACKAGE_DIR.deb"

# 进入 mission-center 目录
cd mission-center

# 修改 .gitmodules 中的 gng 仓库 URL（参考 GitLab CI）
sed -i 's/= ..\/gng.git/= https:\/\/gitlab.com\/mission-center-devs\/gng.git/g' .gitmodules || true

# 更新子模块
git submodule update --init --recursive

# 构建项目
meson setup "$BUILD_DIR" -Dbuildtype=release -Dskip-codegen=true --prefix=/usr
ninja -C "$BUILD_DIR"

# 安装到临时目录
DESTDIR="$DEB_ROOT" ninja -C "$BUILD_DIR" install

# 创建 DEBIAN 目录
mkdir -p "$DEB_ROOT/DEBIAN"

# 创建控制文件
cat > "$DEB_ROOT/DEBIAN/control" << EOF
Package: mission-center
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-4-1, libadwaita-1-0, libdbus-1-3, libudev1, libdrm2, libgbm1
Maintainer: GitHub Actions <noreply@github.com>
Description: Mission Center - System monitor
 Monitor your CPU, Memory, Disk, Network and GPU usage with Mission Center.
 Features include monitoring overall or per-thread CPU usage, system process
 and thread count, RAM and Swap usage, disk utilization and transfer rates,
 network utilization and transfer speeds, and GPU usage.
EOF

# 创建 postinst 脚本
cat > "$DEB_ROOT/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e

# 更新桌面数据库
if command -v update-desktop-database >/dev/null; then
    update-desktop-database /usr/share/applications
fi

# 更新图标缓存
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
fi

# 编译 GSettings schemas
if command -v glib-compile-schemas >/dev/null; then
    glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true
fi

exit 0
EOF

# 创建 postrm 脚本
cat > "$DEB_ROOT/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "remove" ]; then
    # 更新桌面数据库
    if command -v update-desktop-database >/dev/null; then
        update-desktop-database /usr/share/applications
    fi

    # 更新图标缓存
    if command -v gtk-update-icon-cache >/dev/null; then
        gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
    fi

    # 编译 GSettings schemas
    if command -v glib-compile-schemas >/dev/null; then
        glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true
    fi
fi

exit 0
EOF

# 设置脚本权限
chmod 755 "$DEB_ROOT/DEBIAN/postinst"
chmod 755 "$DEB_ROOT/DEBIAN/postrm"

# 返回到项目根目录
cd ..

# 构建 deb 包
dpkg-deb --build "$PACKAGE_DIR"

echo "Successfully built $PACKAGE_DIR.deb"
