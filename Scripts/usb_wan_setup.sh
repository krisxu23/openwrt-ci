#!/bin/bash
#
# USB WAN 自动配置脚本 - 终极增强版
# 版本: 2.0.7
# 适用: 高通 IPQ6018 (1GB 内存), OpenWrt 环境
# 功能: 自动检测和配置 USB WAN 设备 (DHCP 协议), 优化 ZTE/ASR/展锐支持
#

if [ -z "$GITHUB_WORKSPACE" ]; then 
    echo "错误：非 GitHub Actions 环境。"
    exit 1
fi

FILES_PATH="$GITHUB_WORKSPACE/wrt/files"

echo " "
echo "正在注入 USB WAN 自动配置脚本 (终极增强版 2.0.7)..."
echo " "

mkdir -p "$FILES_PATH/usr/bin" "$FILES_PATH/etc/hotplug.d/net" "$FILES_PATH/etc/init.d" "$FILES_PATH/etc/config"

# --- 1. 核心处理脚本 ---
cat << 'EOF' > "$FILES_PATH/usr/bin/usb-wan-core"
#!/bin/sh
# USB WAN 核心处理脚本 - 终极增强版
# 版本: 2.0.7

DEV="$1"
[ -n "$DEV" ] || { logger -t usb-wan "[ERROR] 未提供设备名称"; exit 1; }

log() {
    local level="$1"; shift
    [ "$level" = "DEBUG" ] && [ -z "$DEBUG" ] && return 0
    logger -t usb-wan "[$level] $@"
}

# --- 读取配置 ---
ENABLED=$(uci -q get usb_wan.global.enabled)
[ "$ENABLED" = "0" ] && { log INFO "USB WAN 自动配置已禁用"; exit 0; }
DEBUG=$(uci -q get usb_wan.global.debug_mode)

check_deps() {
    for cmd in uci ip ping jsonfilter; do
        command -v "$cmd" >/dev/null || { log ERROR "缺少依赖: $cmd"; exit 1; }
    done
}
check_deps

LOCK_FILE="/var/run/usb-wan-$DEV.lock"
if [ -e "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        log INFO "设备 '$DEV' 正在被其他进程处理，跳过"
        exit 0
    else
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit' EXIT INT TERM

# --- USB 验证 ---
USB_VERIFIED=0
if [ -d "/sys/class/net/$DEV/device" ]; then
    if readlink "/sys/class/net/$DEV/device" | grep -qi "usb"; then
        USB_VERIFIED=1
    elif [ -d "/sys/class/net/$DEV/device/driver" ]; then
        DRIVER_PATH=$(readlink "/sys/class/net/$DEV/device/driver" 2>/dev/null)
        echo "$DRIVER_PATH" | grep -qiE 'usb|cdc_ether|cdc_ncm|rndis|asix|rtl815|smsc95|ipheth|zte' && USB_VERIFIED=1
    elif [ -L "/sys/class/net/$DEV/device/subsystem" ]; then
        [ "$(basename "$(readlink -f "/sys/class/net/$DEV/device/subsystem")")" = "usb" ] && USB_VERIFIED=1
    fi
fi

[ $USB_VERIFIED -eq 0 ] && { log INFO "设备 '$DEV' 不是 USB，跳过"; exit 0; }

# --- ZTE VID 检查 ---
if [ -n "$DEBUG" ] && command -v lsusb >/dev/null && lsusb 2>/dev/null | grep -qi "19d2"; then
    log DEBUG "检测到中兴微电子设备 (VID:19d2)"
fi

# --- 配置网络 ---
uci export network > /tmp/network.backup
uci export firewall > /tmp/firewall.backup

uci set network.usb_wan=interface
uci set network.usb_wan.proto='dhcp'
uci set network.usb_wan.device="$DEV"
uci set network.usb_wan.defaultroute='1'
uci set network.usb_wan.peerdns='1'
uci set network.usb_wan.ipv6='0'
uci set network.usb_wan.metric='10'
uci set network.usb_wan.delegate='0'

if uci -q get network.@device[0] >/dev/null; then
    uci delete network.usb_wan.ifname 2>/dev/null
else
    uci set network.usb_wan.ifname="$DEV"
fi

WAN_ZONE=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
[ -z "$WAN_ZONE" ] && WAN_ZONE="wan"
uci remove_list firewall."$WAN_ZONE".network="usb_wan" 2>/dev/null
uci add_list firewall."$WAN_ZONE".network="usb_wan"

if ! uci commit network || ! uci commit firewall; then
    log ERROR "配置提交失败，回滚"
    uci import network < /tmp/network.backup 2>/dev/null
    uci import firewall < /tmp/firewall.backup 2>/dev/null
    uci commit network; uci commit firewall
    exit 1
fi

ifdown usb_wan 2>/dev/null; sleep 0.5; ifup usb_wan

# --- 网关检测 ---
for i in $(seq 1 10); do
    if ubus call network.interface.usb_wan status | grep -q '"up": true'; then
        GATEWAY=$(ubus call network.interface.usb_wan status | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' || jsonfilter -e '@.route[0].nexthop')
        [ -n "$GATEWAY" ] && break
    fi
    sleep 0.5
done

EXIT_CODE=0
if [ -n "$GATEWAY" ]; then
    log INFO "✅ 网关: $GATEWAY"
    if ! ip route show default | grep -q "dev $DEV"; then
        log INFO "修复默认路由..."
        ip route add default via "$GATEWAY" dev "$DEV" metric 10 2>/dev/null || true
    fi
    if ! ping -c 3 -W 2 -I "$DEV" "$GATEWAY" >/dev/null 2>&1; then
        log WARN "⚠️ 网关无法 ping 通"
        EXIT_CODE=1
    fi
else
    log ERROR "❌ 未获取网关"
    EXIT_CODE=1
fi

exit $EXIT_CODE
EOF

# --- 2. 热插拔触发器 ---
cat << 'EOF' > "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
#!/bin/sh
# USB WAN 热插拔触发脚本 - 终极增强版
# 版本: 2.0.7

log() {
    local level="$1"; shift
    [ "$level" = "DEBUG" ] && [ -z "$DEBUG" ] && return 0
    logger -t usb-wan "[$level] $@"
}

DEV="${DEVICENAME:-$INTERFACE}"
case "$ACTION" in
    add)
        if [ -n "$DEV" ]; then
            log INFO "热插拔: 检测到设备 '$DEV' 插入"
            [ "$(echo "$DEV" | grep -i '^rndis')" ] && sleep 1.5 || sleep 0.5
            /usr/bin/usb-wan-core "$DEV" &
        fi
        ;;
    remove)
        if [ -n "$DEV" ]; then
            log INFO "热插拔: 设备 '$DEV' 已移除"
            CURRENT_DEV=$(uci -q get network.usb_wan.device)
            if [ "$CURRENT_DEV" = "$DEV" ]; then
                uci -q delete network.usb_wan
                WAN_ZONE=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
                [ -n "$WAN_ZONE" ] && uci remove_list firewall."$WAN_ZONE".network="usb_wan"
                uci commit network; uci commit firewall
                log INFO "设备 '$DEV' 配置已清理"
            else
                log DEBUG "设备 '$DEV' 未匹配配置，跳过清理"
            fi
        fi
        ;;
esac
EOF

# --- 3. 开机自启脚本 ---
cat << 'EOF' > "$FILES_PATH/etc/init.d/usb-wan"
#!/bin/sh /etc/rc.common
# USB WAN 开机自启脚本 - 终极增强版
# 版本: 2.0.7

START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "
        MAX_WAIT=15
        WAIT_COUNT=0
        logger -t usb-wan '[BOOT] 等待 USB 网络设备初始化...'
        while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
            [ -d /sys/class/net ] && [ -n \"\$(ls /sys/class/net)\" ] && break
            sleep 1
            WAIT_COUNT=\$((WAIT_COUNT + 1))
        done
        logger -t usb-wan '[BOOT] 开始扫描 USB 网络设备...'
        for dev_path in /sys/class/net/*; do
            dev=\$(basename \"\$dev_path\")
            case \"\$dev\" in
                lo|br-*|docker*|veth*|tun*|tap*|wlan*|bond*|gre*)
                    continue
                    ;;
            esac
            if [ -d \"\$dev_path/device\" ]; then
                if readlink \"\$dev_path/device\" | grep -qi 'usb' || \
                   readlink \"\$dev_path/device/driver\" 2>/dev/null | grep -qiE 'usb|cdc_ether|cdc_ncm|rndis|asix|rtl815|smsc95|ipheth|zte'; then
                    logger -t usb-wan \"[BOOT] 发现 USB 设备: \$dev，启动配置...\"
                    /usr/bin/usb-wan-core \"\$dev\"
                    sleep 1
                fi
            fi
        done
        logger -t usb-wan '[BOOT] USB WAN 扫描完成'
    "
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF

# --- 权限 ---
chmod +x "$FILES_PATH/usr/bin/usb-wan-core"
chmod +x "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
chmod +x "$FILES_PATH/etc/init.d/usb-wan"

# --- 配置文件 ---
cat << 'EOF' > "$FILES_PATH/etc/config/usb_wan"
config usb_wan 'global'
    option enabled '1'
    option debug_mode '0'
EOF

echo "✅ USB WAN 自动配置脚本 (终极增强版 2.0.7) 已成功注入。"
echo "📋 功能特性:"
echo "   • 优化开机扫描，移除 eth0 排除，支持 USB 网卡命名为 eth0"
echo "   • 精确匹配 firewall .name='wan'，避免自定义名称误判"
echo "   • 移除 auto_setup，精简逻辑"
echo "   • 支持 ZTE (VID:19d2), ASR, 展锐 USB 网卡"
echo "   • 动态等待设备初始化 (最多 15 秒)"
echo " "
echo "🔧 使用说明:"
echo "   • 插入 USB 网卡后自动配置"
echo "   • 设置 uci set usb_wan.global.debug_mode=1 启用调试"
echo "   • 查看日志: logread | grep usb-wan"
echo " "
