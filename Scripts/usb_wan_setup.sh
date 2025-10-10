#!/bin/bash
#
# USB WAN 自动配置脚本 - 修复版
#

# 检查环境
if [ -z "$GITHUB_WORKSPACE" ]; then 
    echo "错误：非 GitHub Actions 环境。"
    exit 1
fi

# 定义路径
FILES_PATH="$GITHUB_WORKSPACE/wrt/files"

echo " "
echo "正在注入 USB WAN 自动配置脚本..."
echo " "

# --- 创建目录 ---
mkdir -p "$FILES_PATH/usr/bin" "$FILES_PATH/etc/hotplug.d/net" "$FILES_PATH/etc/init.d"

# --- 1. 核心处理脚本 ---
cat << 'EOF' > "$FILES_PATH/usr/bin/usb-wan-core"
#!/bin/sh
# USB WAN 核心处理脚本

DEV="$1"
[ -n "$DEV" ] || exit 1

# --- 防抖锁机制 ---
LOCK_FILE="/var/run/usb-wan-$DEV.lock"
if [ -e "$LOCK_FILE" ]; then
    if [ -d "/proc/$(cat $LOCK_FILE 2>/dev/null)" ]; then
        logger -t usb-wan "设备 '$DEV' 正在被其他进程处理，跳过。"
        exit 0
    else
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

logger -t usb-wan "开始处理设备 '$DEV'"

# --- USB 设备验证 ---
USB_VERIFIED=0
if [ -d "/sys/class/net/$DEV/device" ]; then
    if readlink "/sys/class/net/$DEV/device" | grep -qi "usb"; then 
        USB_VERIFIED=1
    fi
    if [ $USB_VERIFIED -eq 0 ] && [ -d "/sys/class/net/$DEV/device/driver" ]; then
        DRIVER_PATH=$(readlink "/sys/class/net/$DEV/device/driver")
        if echo "$DRIVER_PATH" | grep -qiE '(usb|cdc|rndis|qmi|asix|rtl8152)'; then 
            USB_VERIFIED=1
        fi
    fi
fi

if [ $USB_VERIFIED -eq 0 ]; then 
    logger -t usb-wan "'$DEV' 未通过USB验证，跳过。"
    exit 0
fi

logger -t usb-wan "确认 '$DEV' 为USB设备，开始配置..."

# --- 网络配置 ---
uci set network.usb_wan=interface
uci set network.usb_wan.proto=dhcp
uci set network.usb_wan.device="$DEV"
uci set network.usb_wan.defaultroute=1
uci set network.usb_wan.peerdns=1
uci set network.usb_wan.ipv6=0
uci set network.usb_wan.metric=10

if uci -q get network.@device[0] >/dev/null; then
    uci delete network.usb_wan.ifname 2>/dev/null
else
    uci set network.usb_wan.ifname="$DEV"
fi

# --- 防火墙配置 ---
WAN_ZONE=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
[ -n "$WAN_ZONE" ] || WAN_ZONE="wan"
if uci -q get firewall."$WAN_ZONE" >/dev/null; then
    uci remove_list firewall."$WAN_ZONE".network="usb_wan" 2>/dev/null
    uci add_list firewall."$WAN_ZONE".network="usb_wan"
fi

uci commit network
uci commit firewall

logger -t usb-wan "配置已提交，重启接口..."

# --- 重启接口 ---
ifdown usb_wan 2>/dev/null
sleep 1
ifup usb_wan

# --- 获取网关 ---
GATEWAY=""
RETRY_COUNT=0
MAX_RETRIES=15

while [ -z "$GATEWAY" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ! command -v jsonfilter >/dev/null; then
        logger -t usb-wan "错误: jsonfilter工具未找到!"
        break
    fi
    GATEWAY=$(ubus call network.interface.usb_wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
    [ -z "$GATEWAY" ] && sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ -n "$GATEWAY" ]; then
    logger -t usb-wan "成功获取网关: $GATEWAY"
    if ! ip route show default | grep -q "dev $DEV"; then
        logger -t usb-wan "修复默认路由"
        ip route add default via "$GATEWAY" dev "$DEV"
    fi
    if ping -c 2 -W 3 "$GATEWAY" >/dev/null 2>&1; then
        logger -t usb-wan "网络连接成功"
    else
        logger -t usb-wan "网关无法ping通"
    fi
else
    logger -t usb-wan "未能获取网关地址"
fi
EOF

# --- 2. 热插拔触发器 ---
cat << 'EOF' > "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
DEV="${DEVICENAME:-$INTERFACE}"
[ -n "$DEV" ] && /usr/bin/usb-wan-core "$DEV" &
EOF

# --- 3. 开机自启脚本 ---
cat << 'EOF' > "$FILES_PATH/etc/init.d/usb-wan"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "
        sleep 20
        for dev_path in /sys/class/net/*; do
            dev=\$(basename \"\$dev_path\")
            case \"\$dev\" in 
                lo|br-*|docker*|veth*) continue ;;
            esac
            if [ -d \"\$dev_path/device\" ]; then 
                /usr/bin/usb-wan-core \"\$dev\" &
                sleep 1
            fi
        done
    "
    procd_close_instance
}

boot() {
    start_service "$@"
}
EOF

# --- 设置权限 ---
chmod +x "$FILES_PATH/usr/bin/usb-wan-core"
chmod +x "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
chmod +x "$FILES_PATH/etc/init.d/usb-wan"

echo "✅ USB WAN 自动配置脚本已成功注入。"
echo " "
