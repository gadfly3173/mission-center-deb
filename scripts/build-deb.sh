#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <upstream-tag> <upstream-version> <upstream-commit>" >&2
  exit 1
fi

upstream_tag="$1"
upstream_version="$2"
upstream_commit="$3"

package_name="${PACKAGE_NAME:-io.missioncenter}"
package_release="${PACKAGE_RELEASE:-1}"
repo_url="${UPSTREAM_REPO_URL:-https://gitlab.com/mission-center-devs/mission-center.git}"
workspace_dir="${WORKSPACE_DIR:-$PWD}"
build_root="${BUILD_ROOT:-$workspace_dir/.build/$upstream_tag}"
output_dir="${OUTPUT_DIR:-$workspace_dir/dist}"
source_dir="$build_root/source"
portable_dir="$build_root/portable"
pkgroot="$build_root/pkgroot"
app_root="/opt/$package_name"
app_dir="$pkgroot$app_root"
deb_arch="$(dpkg --print-architecture)"
multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
deb_version="${upstream_version}-${package_release}"
maintainer="${DEB_MAINTAINER:-Gadfly <gadfly@gadfly.vip>}"
homepage="${DEB_HOMEPAGE:-https://github.com/${GITHUB_REPOSITORY:-homolo/mission-center-deb}}"
release_file_prefix="${package_name}_${deb_version}_${deb_arch}"

authored_changelog_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

patch_upstream_build_script() {
  local script_path="$1"
  declare -A token_aliases=(
    [python-openssl]=python3-openssl
    [libffi.so.7]=libffi.so.8
    [libssl.so.1.1]=libssl.so.3
    [libcrypto.so.1.1]=libcrypto.so.3
    [libldap_r-2.4.so.2]=libldap-2.5.so.0
    [liblber-2.4.so.2]=liblber-2.5.so.0
    [libhogweed.so.5]=libhogweed.so.6
    [libnettle.so.7]=libnettle.so.8
    [libwebp.so.6]=libwebp.so.7
    [libicuuc.so.66]=libicuuc.so.70
    [libicudata.so.66]=libicudata.so.70
  )
  local old_token=""
  local new_token=""
  local escaped_old_token=""
  local escaped_new_token=""

  if [[ ! -f "$script_path" ]]; then
    echo "Upstream build script not found: $script_path" >&2
    exit 1
  fi

  for old_token in "${!token_aliases[@]}"; do
    new_token="${token_aliases[$old_token]}"

    if grep -Fq "$old_token" "$script_path"; then
      escaped_old_token="$(printf '%s' "$old_token" | sed 's/[][\\/.^$*+?{}|()-]/\\&/g')"
      escaped_new_token="$(printf '%s' "$new_token" | sed 's/[\\/&]/\\&/g')"
      echo "Patching obsolete upstream token ${old_token} -> ${new_token} for Ubuntu 22.04 compatibility"
      sed -i "s/${escaped_old_token}/${escaped_new_token}/g" "$script_path"
    fi
  done

  if grep -Fq 'cp -Lv /usr/lib/$(arch)-linux-gnu/' "$script_path" && ! grep -Fq '|| true' "$script_path"; then
    echo 'Patching host library copy step to tolerate unavailable Ubuntu 22.04 sonames'
    sed -E -i 's#^(cp -Lv /usr/lib/\$\(arch\)-linux-gnu/\{.*\} \$OUT_PATH/usr/lib/\$\(arch\)-linux-gnu/)$#\1 || true#' "$script_path"
  fi

  echo 'Patching curl downloads with retry logic for transient network failures'
  sed -i 's/curl \(-L\|\)-LO /curl --retry 3 --retry-delay 5 \1-LO /g' "$script_path"

  # Ubuntu 22.04 does not ship the glslc package (it was added in 24.04+), and
  # the upstream apt list omits libvulkan-dev anyway, so GTK4's optional vulkan
  # backend cannot be built in this container. Mission Center only displays the
  # GPU's vulkan_version string (read from hardware) and never uses the vulkan
  # backend at runtime, so drop glslc from the apt list and disable the backend.
  if grep -qF -- 'glslc' "$script_path"; then
    echo 'Patching upstream apt list: removing glslc (unavailable on Ubuntu 22.04)'
    sed -i -E 's/[[:space:]]+glslc([[:space:]])/\1/g' "$script_path"
  fi

  if grep -qF -- '-Dvulkan=enabled' "$script_path"; then
    echo 'Patching GTK4 build: disabling optional vulkan backend (glslc/libvulkan-dev unavailable on Ubuntu 22.04)'
    sed -i 's/-Dvulkan=enabled/-Dvulkan=disabled/g' "$script_path"
  fi
}

collect_runtime_packages() {
  local search_root="$1"
  declare -A packages=()
  local candidate=""
  local resolved_lib=""
  local package_owner=""

  while IFS= read -r -d '' candidate; do
    if ! file --brief --dereference "$candidate" | grep -q '^ELF '; then
      continue
    fi

    while IFS= read -r resolved_lib; do
      [[ -z "$resolved_lib" ]] && continue
      [[ "$resolved_lib" == "$search_root"* ]] && continue

      package_owner="$(dpkg-query -S "$resolved_lib" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
      [[ -z "$package_owner" ]] && continue
      if [[ ! "$package_owner" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
        echo "Skipping invalid package name: $package_owner" >&2
        continue
      fi

      packages["$package_owner"]=1
    done < <(ldd "$candidate" 2>/dev/null | awk '/=> \/ / { print $3 } /=> \// { print $3 } /^\/.* \(0x/ { print $1 }' | sort -u)
  done < <(find "$search_root" -type f -print0)

  packages["libc6"]=1
  packages["libgcc-s1"]=1
  packages["libstdc++6"]=1

  printf '%s\n' "${!packages[@]}" | LC_ALL=C sort | paste -sd ',' -
}

rm -rf "$build_root"
mkdir -p "$build_root" "$output_dir"

git clone "$repo_url" "$source_dir"
git -C "$source_dir" checkout "$upstream_commit"
git -C "$source_dir" submodule sync --recursive
git -C "$source_dir" submodule update --init --recursive

patch_upstream_build_script "$source_dir/support/build-with-gtk-libadwaita.sh"

for build_attempt in 1 2; do
  echo "=== Upstream build attempt $build_attempt/2 ===" >&2
  if SRC_PATH="$source_dir" OUT_PATH="$portable_dir" bash "$source_dir/support/build-with-gtk-libadwaita.sh"; then
    break
  fi
  if [[ $build_attempt -eq 2 ]]; then
    echo "Upstream build failed after 2 attempts" >&2
    exit 1
  fi
  echo "Cleaning up and retrying..." >&2
  rm -rf "$portable_dir"
  mkdir -p "$portable_dir"
done

mkdir -p \
  "$pkgroot/DEBIAN" \
  "$app_dir" \
  "$pkgroot/usr/bin" \
  "$pkgroot/usr/share/doc/$package_name"

cp -a "$portable_dir/usr/." "$app_dir/"
if [[ -d "$portable_dir/dependencies/usr" ]]; then
  cp -a "$portable_dir/dependencies/usr/." "$app_dir/"
fi

loaders_cache="$app_dir/lib/$multiarch/gdk-pixbuf-2.0/2.10.0/loaders.cache"
if [[ -f "$loaders_cache" ]]; then
  sed -i "s|/usr/lib/$multiarch/gdk-pixbuf-2.0|${app_root}/lib/$multiarch/gdk-pixbuf-2.0|g" "$loaders_cache"
fi

for share_dir in applications dbus-1 icons metainfo; do
  if [[ -d "$app_dir/share/$share_dir" ]]; then
    mkdir -p "$pkgroot/usr/share/$share_dir"
    if [[ "$share_dir" == "icons" ]]; then
      for icon_theme in "$app_dir/share/icons"/*/; do
        theme_name="$(basename "$icon_theme")"
        if [[ "$theme_name" == "Adwaita" ]]; then
          continue
        fi
        mkdir -p "$pkgroot/usr/share/icons/$theme_name"
        cp -a "$icon_theme/." "$pkgroot/usr/share/icons/$theme_name/"
      done
    elif [[ "$share_dir" == "metainfo" ]]; then
      for metainfo_file in "$app_dir/share/$share_dir"/io.missioncenter.*; do
        [[ -f "$metainfo_file" ]] || continue
        cp -a "$metainfo_file" "$pkgroot/usr/share/$share_dir/"
      done
    else
      cp -a "$app_dir/share/$share_dir/." "$pkgroot/usr/share/$share_dir/"
    fi
  fi
done

cat >"$pkgroot/usr/bin/$package_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail

append_path() {
  local current_value="\${1:-}"
  shift || true
  local values=()
  local candidate=""

  for candidate in "\$@"; do
    if [[ -n "\$candidate" && -d "\$candidate" ]]; then
      values+=("\$candidate")
    fi
  done

  local joined=""
  if (( \${#values[@]} > 0 )); then
    joined="\$(IFS=:; printf '%s' "\${values[*]}")"
  fi

  if [[ -n "\$joined" && -n "\$current_value" ]]; then
    printf '%s:%s' "\$joined" "\$current_value"
  elif [[ -n "\$joined" ]]; then
    printf '%s' "\$joined"
  else
    printf '%s' "\$current_value"
  fi
}

APP_ROOT="$app_root"
MULTIARCH_DIR="$multiarch"

export PATH="\$APP_ROOT/bin\${PATH:+:\$PATH}"
export LD_LIBRARY_PATH="\$(append_path "\${LD_LIBRARY_PATH:-}" "\$APP_ROOT/lib/\$MULTIARCH_DIR" "\$APP_ROOT/lib")"
export GI_TYPELIB_PATH="\$(append_path "\${GI_TYPELIB_PATH:-}" "\$APP_ROOT/lib/\$MULTIARCH_DIR/girepository-1.0" "\$APP_ROOT/lib/girepository-1.0")"
export XDG_DATA_DIRS="\$(append_path "\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" "\$APP_ROOT/share")"
export GSETTINGS_SCHEMA_DIR="\$APP_ROOT/share/glib-2.0/schemas"
export GDK_PIXBUF_MODULE_FILE="\$APP_ROOT/lib/\$MULTIARCH_DIR/gdk-pixbuf-2.0/2.10.0/loaders.cache"
export MC_RESOURCE_DIR="\$APP_ROOT/share/missioncenter"
if [[ -f "\$APP_ROOT/share/missioncenter/hw.db" ]]; then
  export MC_MAGPIE_HW_DB="\$APP_ROOT/share/missioncenter/hw.db"
fi

exec "\$APP_ROOT/bin/missioncenter" "\$@"
EOF
chmod 0755 "$pkgroot/usr/bin/$package_name"

for compat_name in missioncenter mission-center; do
  if [[ ! -e "$pkgroot/usr/bin/$compat_name" ]]; then
    ln -s "$package_name" "$pkgroot/usr/bin/$compat_name"
  fi
done

cp "$source_dir/COPYING" "$pkgroot/usr/share/doc/$package_name/copyright"
cat >"$pkgroot/usr/share/doc/$package_name/changelog.Debian" <<EOF
mission-center-deb ($deb_version) unstable; urgency=medium

  * Repackage upstream Mission Center release $upstream_tag as a self-contained Debian package.

 -- $maintainer  $authored_changelog_date
EOF
gzip -n -9 "$pkgroot/usr/share/doc/$package_name/changelog.Debian"

cat >"$pkgroot/DEBIAN/postinst" <<EOF
#!/usr/bin/env bash
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
app_locale="$app_root/share/locale"
if [[ -d "\$app_locale" ]]; then
  find "\$app_locale" -name 'missioncenter.mo' -type f | while read -r mo_file; do
    locale_dir="\$(dirname "\$(dirname "\$mo_file")")"
    locale_name="\$(basename "\$locale_dir")"
    target_dir="/usr/share/locale/\$locale_name/LC_MESSAGES"
    mkdir -p "\$target_dir"
    ln -sf "\$mo_file" "\$target_dir/missioncenter.mo"
  done
fi
exit 0
EOF
chmod 0755 "$pkgroot/DEBIAN/postinst"

cat >"$pkgroot/DEBIAN/postrm" <<EOF
#!/usr/bin/env bash
set -e
if [[ "\$1" = "remove" || "\$1" = "purge" ]]; then
  find /usr/share/locale -name 'missioncenter.mo' -type l | while read -r link; do
    target="\$(readlink -f "\$link" 2>/dev/null || true)"
    if [[ "\$target" == $app_root/* ]]; then
      rm -f "\$link"
    fi
  done
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
exit 0
EOF
chmod 0755 "$pkgroot/DEBIAN/postrm"

runtime_depends="$(collect_runtime_packages "$app_dir")"
installed_size="$(du -sk "$pkgroot" | cut -f1)"

cat >"$pkgroot/DEBIAN/control" <<EOF
Package: $package_name
Version: $deb_version
Section: utils
Priority: optional
Architecture: $deb_arch
Maintainer: $maintainer
Depends: $runtime_depends
Homepage: $homepage
Installed-Size: $installed_size
Description: Monitor system resource usage
 Mission Center monitors CPU, memory, disk, network and GPU usage.
 It also shows per-application and per-process statistics in a modern GTK interface.
 This package bundles the newer GTK and libadwaita runtime under $app_root
 so it can be built and distributed from GitHub Actions while remaining runnable
 on Ubuntu 22.04 and newer systems.
EOF

deb_path="$output_dir/$release_file_prefix.deb"
dpkg-deb --build --root-owner-group "$pkgroot" "$deb_path"

(
  cd "$output_dir"
  sha256sum "$(basename "$deb_path")" >"$(basename "$deb_path").sha256"
)

cat >"$output_dir/$release_file_prefix.json" <<EOF
{
  "package": "$package_name",
  "version": "$deb_version",
  "architecture": "$deb_arch",
  "upstream_tag": "$upstream_tag",
  "upstream_version": "$upstream_version",
  "upstream_commit": "$upstream_commit",
  "output": "$(basename "$deb_path")"
}
EOF

echo "Built Debian package: $deb_path"
