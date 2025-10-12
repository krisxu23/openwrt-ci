#!/bin/bash
#
# Packages.sh - 自动管理 OpenWrt 插件（增强版且完整）
# - 自动追加 small-package feed
# - 优先使用 small-package feed；否则 fallback 到 GitHub
# - 更安全的目录匹配与删除
# - 依赖检查、日志记录、git/curl 重试
# - 版本比较不依赖 dpkg
# - 保留原始 UPDATE_VERSION 及调用示例注释
#

# -------------------------
# 全局配置
# -------------------------
LOG_FILE="packages_update.log"
FEEDS_CONF=${FEEDS_CONF:-"feeds.conf.default"}
FEEDS_DIR=${FEEDS_DIR:-"../feeds"}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

check_dependencies() {
    local deps=("git" "curl" "jq" "sha256sum" "sort")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log "[ERROR] Required tool '$dep' is not installed."
            exit 1
        fi
    done
}

git_clone_with_retry() {
    local repo_url=$1
    local branch=$2
    local retries=3
    local count=0
    until git clone --depth=1 --single-branch --branch "$branch" "$repo_url"; do
        count=$((count + 1))
        if [ $count -ge $retries ]; then
            log "[ERROR] Failed to clone $repo_url after $retries attempts."
            exit 1
        fi
        sleep 2
    done
}

curl_with_retry() {
    local url=$1
    local retries=3
    local count=0
    until curl -sL --connect-timeout 10 "$url"; do
        count=$((count + 1))
        if [ $count -ge $retries ]; then
            log "[ERROR] Failed to fetch $url after $retries attempts. Consider using a GitHub API token."
            exit 1
        fi
        sleep 2
    done
}

compare_versions() {
    local old_ver=$1
    local new_ver=$2
    if [[ "$(echo -e "$old_ver\n$new_ver" | sort -V | tail -n 1)" == "$new_ver" && "$old_ver" != "$new_ver" ]]; then
        return 0
    else
        return 1
    fi
}

# -------------------------
# 初始化 small-package feed
# -------------------------
INIT_SMALL_PACKAGE_FEED() {
    local FEED_LINE="src-git smpackage https://github.com/kenzok8/small-package"
    if ! grep -q "smpackage" "$FEEDS_CONF" 2>/dev/null; then
        log "[INFO] small-package feed 未配置，自动追加..."
        echo "$FEED_LINE" >> "$FEEDS_CONF"
    else
        log "[INFO] small-package feed 已存在，跳过追加。"
    fi

    log "[INFO] 更新 feeds..."
    ./scripts/feeds update -a
    ./scripts/feeds install -a

    # 避免与核心组件冲突（可按需调整或注释）
    if [ -d "feeds/smpackage" ]; then
        log "[INFO] 移除可能冲突的核心包（可按需修改列表）"
        rm -rf feeds/smpackage/{base-files,dnsmasq,firewall*,fullconenat,libnftnl,nftables,ppp,opkg,ucl,upx,vsftpd*,miniupnpd-iptables,wireless-regdb} || true
    fi
}

# -------------------------
# 包更新函数
# -------------------------
UPDATE_PACKAGE() {
    local PKG_NAME=$1
    local PKG_REPO=$2
    local PKG_BRANCH=$3
    local PKG_SPECIAL=$4
    local PKG_LIST=("$PKG_NAME" $5)
    local REPO_NAME=${PKG_REPO#*/}

    log "[INFO] Updating package: $PKG_NAME from $PKG_REPO ($PKG_BRANCH)"

    # 更安全的删除：精确匹配目录名
    for NAME in "${PKG_LIST[@]}"; do
        if [ -z "$NAME" ]; then
            continue
        fi
        log "[INFO] Searching for directory: $NAME"
        local FOUND_DIRS=$(find "${FEEDS_DIR}/luci/" "${FEEDS_DIR}/packages/" -maxdepth 3 -type d -name "$NAME" 2>/dev/null)
        if [ -n "$FOUND_DIRS" ]; then
            while read -r DIR; do
                if [[ -n "$DIR" && -d "$DIR" ]]; then
                    rm -rf "$DIR"
                    log "[INFO] Deleted directory: $DIR"
                fi
            done <<< "$FOUND_DIRS"
        else
            log "[INFO] Directory not found: $NAME"
        fi
    done

    git_clone_with_retry "https://github.com/$PKG_REPO.git" "$PKG_BRANCH"

    if [[ "$PKG_SPECIAL" == "pkg" ]]; then
        # 从多包仓库中提取指定包
        find "./$REPO_NAME"/*/ -maxdepth 3 -type d -name "$PKG_NAME" -prune -exec cp -rf {} ./ \;
        rm -rf "./$REPO_NAME/"
        log "[INFO] Processed package $PKG_NAME (pkg mode)"
    elif [[ "$PKG_SPECIAL" == "name" ]]; then
        mv -f "$REPO_NAME" "$PKG_NAME"
        log "[INFO] Renamed $REPO_NAME to $PKG_NAME"
    fi
}

SMART_UPDATE_PACKAGE() {
    local PKG_NAME=$1
    local PKG_REPO=$2
    local PKG_BRANCH=$3
    local PKG_SPECIAL=$4
    local PKG_ALIASES=$5

    local PKG_PATH=$(find feeds/smpackage/ -maxdepth 2 -type d -name "$PKG_NAME" 2>/dev/null)

    if [ -n "$PKG_PATH" ]; then
        log "[INFO] $PKG_NAME 已在 small-package feed 中，检查版本..."
        UPDATE_VERSION "$PKG_NAME"
    else
        log "[INFO] $PKG_NAME 不在 small-package feed 中，使用 UPDATE_PACKAGE 拉取。"
        UPDATE_PACKAGE "$PKG_NAME" "$PKG_REPO" "$PKG_BRANCH" "$PKG_SPECIAL" "$PKG_ALIASES"
    fi
}

# -------------------------
# 更新软件包版本（保留原始逻辑，增强健壮性）
# -------------------------
UPDATE_VERSION() {
    local PKG_NAME=$1
    local PKG_MARK=${2:-false}
    local PKG_FILES=$(find ./ ../feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

    if [ -z "$PKG_FILES" ]; then
        log "[WARN] $PKG_NAME not found!"
        return
    fi

    log "[INFO] $PKG_NAME version update has started!"

    for PKG_FILE in $PKG_FILES; do
        local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" "$PKG_FILE")
        if [ -z "$PKG_REPO" ]; then
            log "[WARN] $PKG_FILE 未找到 PKG_SOURCE_URL GitHub 仓库信息，跳过。"
            continue
        fi

        local RELEASES_JSON
        RELEASES_JSON=$(curl_with_retry "https://api.github.com/repos/$PKG_REPO/releases")
        local PKG_TAG
        PKG_TAG=$(echo "$RELEASES_JSON" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name")

        if [ -z "$PKG_TAG" ] || [[ "$PKG_TAG" == "null" ]]; then
            log "[WARN] $PKG_NAME 未找到合适的 release tag（prerelease=$PKG_MARK），跳过。"
            continue
        fi

        local OLD_VER OLD_URL OLD_FILE OLD_HASH
        OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
        OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
        OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
        OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

        local PKG_URL
        if [[ "$OLD_URL" == *"releases"* ]]; then
            PKG_URL="${OLD_URL%/}/$OLD_FILE"
        else
            PKG_URL="${OLD_URL%/}"
        fi

        local NEW_VER NEW_URL NEW_HASH
        NEW_VER=$(echo "$PKG_TAG" | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
        NEW_URL=$(echo "$PKG_URL" | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")

        # 拉取源码计算新哈希
        NEW_HASH=$(curl_with_retry "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

        log "old version: $OLD_VER $OLD_HASH"
        log "new version: $NEW_VER $NEW_HASH"

        if [[ "$NEW_VER" =~ ^[0-9].* ]] && compare_versions "$OLD_VER" "$NEW_VER"; then
            sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
            sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
            log "[INFO] $PKG_FILE version has been updated!"
        else
            log "[INFO] $PKG_FILE version is already the latest!"
        fi
    done
}

# -------------------------
# 主流程
# -------------------------
check_dependencies
INIT_SMALL_PACKAGE_FEED

# 主题
SMART_UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-24.10"
SMART_UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
SMART_UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "js"

# 网络代理相关
SMART_UPDATE_PACKAGE "homeproxy" "VIKINGYFY/homeproxy" "main"
SMART_UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
SMART_UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
SMART_UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev" "pkg"
SMART_UPDATE_PACKAGE "passwall" "xiaorouji/openwrt-passwall" "main" "pkg"
SMART_UPDATE_PACKAGE "passwall2" "xiaorouji/openwrt-passwall2" "main" "pkg"

# 工具类
SMART_UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"
SMART_UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
SMART_UPDATE_PACKAGE "diskman" "lisaac/luci-app-diskman" "master"
SMART_UPDATE_PACKAGE "easytier" "EasyTier/luci-app-easytier" "main"
SMART_UPDATE_PACKAGE "fancontrol" "rockjake/luci-app-fancontrol" "main"
SMART_UPDATE_PACKAGE "gecoosac" "lwb1978/openwrt-gecoosac" "main"
SMART_UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
SMART_UPDATE_PACKAGE "netspeedtest" "sirpdboy/luci-app-netspeedtest" "js" "" "homebox speedtest"
SMART_UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
SMART_UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
SMART_UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
SMART_UPDATE_PACKAGE "qmodem" "FUjr/QModem" "main"
SMART_UPDATE_PACKAGE "quickfile" "sbwml/luci-app-quickfile" "main"
SMART_UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "luci-app-timewol luci-app-wolplus"
SMART_UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"

# AdGuardHome 插件
SMART_UPDATE_PACKAGE "luci-app-adguardhome" "stevenjoezhang/luci-app-adguardhome" "dev" "" "adguardhome"

# -------------------------
# 可选：更新版本示例（原始注释保留）
# -------------------------
# UPDATE_VERSION "软件包名" "测试版，true，可选，默认为否"
# UPDATE_VERSION "sing-box"
# UPDATE_VERSION "tailscale"
