# mission-center-deb

这个仓库用于通过 GitHub Actions 自动跟踪上游 [`mission-center`](https://gitlab.com/mission-center-devs/mission-center) 的最新 Release，并把对应提交重新打包成当前仓库的 GitHub Release 附件。

## 这个仓库会做什么

- 每 4 小时检查一次上游最新 Release。
- 如果当前仓库里还没有同名 tag/release，就触发一次新的打包流程。
- 在 GitHub 的 `ubuntu-22.04` runner 上启动一个 `ubuntu:22.04` 容器完成构建。
- 使用上游的 `support/build-with-gtk-libadwaita.sh` 脚本先构建自带 GTK/libadwaita 的可移植安装树。
- 再把该安装树重新封装为一个自包含的 `amd64` `.deb` 包，并发布为当前仓库的 Release。

## 目录说明

- `.github/workflows/sync-release.yml`：定时检查、构建与发布流程。
- `scripts/get-upstream-release.sh`：读取 GitLab 最新 Release 元数据。
- `scripts/build-deb.sh`：克隆上游源码、执行构建、封装 `.deb`。

## 触发方式

### 定时触发

工作流使用 cron：每 4 小时运行一次。

### 手动触发

可以在 Actions 页面手动运行 `Sync Mission Center release`：

- 不填 `upstream_tag`：构建上游最新 Release。
- 填写 `upstream_tag`：构建指定上游 tag，例如 `v1.1.0`。

## 产物说明

当前实现会生成：

- `mission-center_<version>-1_amd64.deb`
- 对应的 `sha256` 校验文件
- 一份简单的 JSON 构建元数据

`.deb` 的主体内容会放到 `/opt/mission-center`，并通过 `/usr/bin/missioncenter` 包装器补充运行时环境变量，例如：

- `LD_LIBRARY_PATH`
- `GI_TYPELIB_PATH`
- `XDG_DATA_DIRS`
- `GSETTINGS_SCHEMA_DIR`
- `MC_RESOURCE_DIR`
- `MC_MAGPIE_HW_DB`

## 注意事项

- 当前只构建 `amd64`。
- 构建过程比较重，因为它会重新编译 GTK、libadwaita 等依赖；不过只有检测到新的上游 Release 时才会真正执行重型构建。
- 如果将来需要 `arm64`，可以复用同样思路，把工作流扩展到 ARM runner 或交叉构建流程。
