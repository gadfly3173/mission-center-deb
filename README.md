# mission-center-deb

通过 GitHub Actions 自动跟踪上游 [Mission Center](https://gitlab.com/mission-center-devs/mission-center) 的最新 Release，将对应提交重新打包为自包含的 `.deb` 包并发布到本仓库的 GitHub Release。

## 工作原理

1. 每 4 小时检查一次上游最新 Release。
2. 如果本仓库尚无同名 tag/release，触发一次新的打包流程。
3. 在 GitHub 的 `ubuntu-22.04` runner 上启动 `ubuntu:22.04` 容器完成构建。
4. 使用上游的 `support/build-with-gtk-libadwaita.sh` 构建自带 GTK 4 / libadwaita 的可移植安装树。
5. 将安装树重新封装为自包含的 `amd64` `.deb` 包，发布为 GitHub Release。

## 目录结构

```
.github/workflows/sync-release.yml   # 定时检查、构建与发布
scripts/get-upstream-release.sh       # 读取 GitLab 最新 Release 元数据
scripts/build-deb.sh                  # 克隆上游源码、构建、封装 .deb
```

## 触发方式

**定时触发**：cron 每 4 小时运行一次。

**手动触发**：在 Actions 页面运行 `Sync Mission Center release`：

- 不填 `upstream_tag`：构建上游最新 Release。
- 填写 `upstream_tag`：构建指定上游 tag，例如 `v1.1.0`。

## 包命名与安装路径

| 项目 | 值 |
|------|-----|
| deb 包名 | `io.missioncenter` |
| 安装路径 | `/opt/io.missioncenter/` |
| 主入口 | `/usr/bin/io.missioncenter`（wrapper 脚本） |
| 兼容符号链接 | `/usr/bin/missioncenter`、`/usr/bin/mission-center` |

## 产物说明

每次构建生成：

- `io.missioncenter_<version>-<release>_amd64.deb`
- 对应的 `.sha256` 校验文件
- JSON 构建元数据

### deb 包文件布局

```
/opt/io.missioncenter/              # 自包含运行时（二进制、GTK 4、libadwaita 等捆绑库）
  bin/missioncenter                 # 上游主程序
  lib/x86_64-linux-gnu/             # 捆绑的共享库
  share/
    glib-2.0/schemas/               # GSettings schema
    missioncenter/                  # 应用资源（gresource、hw.db）
    locale/                         # 翻译文件（构建时用，运行时通过符号链接生效）
    icons/hicolor/                  # 应用图标（Adwaita 已剔除，避免与系统包冲突）

/usr/bin/io.missioncenter           # wrapper 脚本，设置运行时环境变量后 exec 主程序
/usr/bin/missioncenter              # -> io.missioncenter
/usr/bin/mission-center             # -> io.missioncenter
/usr/share/applications/            # .desktop 文件
/usr/share/icons/hicolor/           # 应用图标
/usr/share/metainfo/                # AppStream 元数据
/usr/share/doc/io.missioncenter/    # copyright + changelog
/usr/share/locale/*/LC_MESSAGES/    # missioncenter.mo 符号链接 -> /opt/io.missioncenter/...
```

## wrapper 脚本设置的环境变量

| 变量 | 说明 |
|------|------|
| `PATH` | 前置捆绑的 `bin/` 目录 |
| `LD_LIBRARY_PATH` | 捆绑的共享库路径 |
| `GI_TYPELIB_PATH` | GObject Introspection typelib 路径 |
| `XDG_DATA_DIRS` | 前置捆绑的 `share/` 目录 |
| `GSETTINGS_SCHEMA_DIR` | GSettings schema 路径 |
| `GDK_PIXBUF_MODULE_FILE` | gdk-pixbuf 加载器缓存（路径已修正） |
| `MC_RESOURCE_DIR` | 应用 gresource 路径 |
| `MC_MAGPIE_HW_DB` | 硬件数据库（存在时设置） |

## 安装时行为

**postinst**：

- 更新 desktop-database 和 icon-cache。
- 为每个 locale 目录下的 `missioncenter.mo` 在 `/usr/share/locale/` 创建符号链接，使翻译生效（上游二进制硬编码 `LOCALEDIR=/usr/share/locale`）。

**postrm**：

- 卸载时清理上述 locale 符号链接。
- 更新 desktop-database 和 icon-cache。

## 构建脚本细节

`scripts/build-deb.sh` 除了封装 deb 外，还处理以下问题：

- **上游构建脚本兼容性修补**：替换过时的 soname（如 `libffi.so.7` -> `libffi.so.8`）、容错处理缺失的宿主库、为 curl 添加重试。
- **gdk-pixbuf loaders.cache 路径修正**：将 `/usr/lib/...` 替换为 `/opt/io.missioncenter/lib/...`，确保捆绑的图片格式加载器可被定位。
- **剔除 Adwaita 图标**：上游可移植构建会附带完整的 Adwaita 主题图标，deb 包中剔除以避免与系统 `adwaita-icon-theme` 包冲突。
- **过滤 metainfo 文件**：仅复制 `io.missioncenter.*` 的 AppStream 元数据，剔除上游附带的无关文件。
- **运行时依赖自动检测**：通过 `ldd` 分析捆绑 ELF 文件的宿主库依赖，自动生成 `Depends` 字段。

## 环境变量

可通过环境变量覆盖构建脚本的默认行为：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PACKAGE_NAME` | `io.missioncenter` | deb 包名，同时决定安装路径 |
| `PACKAGE_RELEASE` | `1` | deb 修订号 |
| `UPSTREAM_REPO_URL` | 上游 GitLab 地址 | 上游仓库地址 |
| `DEB_MAINTAINER` | `Gadfly <gadfly@gadfly.vip>` | 包维护者 |
| `DEB_HOMEPAGE` | 本仓库地址 | 包主页 |

## 限制

- 当前只构建 `amd64`。
- 构建过程较重，会重新编译 GTK 4、libadwaita 等依赖；仅在检测到新的上游 Release 时执行。
- 如需 `arm64`，可将工作流扩展到 ARM runner 或交叉构建流程。
