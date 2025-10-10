#!/bin/bash
#
# USB WAN 自动配置 - 注入脚本 (编译环境专用)
#

# 检查环境变量 $GITHUB_WORKSPACE 是否存在，确保在正确的环境中运行
if [ -z "$GITHUB_WORKSPACE" ]; then
    echo "错误：请在 GitHub Actions 环境中运行此脚本。"
    exit 1
fi

# 定义编译目标中的 files 目录路径
FILES_PATH="$GITHUB_WORKSPACE/wrt/files"

echo " "
echo "正在将模块化 USB WAN 自动配置脚本注入固件..."
echo "目标目录: $FILES_PATH"
echo " "

# --- 1. 创建核心逻辑脚本 ---
mkdir -p "$FILES_PATH/usr/bin"
cat <<'EOF' > "$FILES_PATH/usr/bin/usb-wan-handler.sh"
#!/bin/sh
# USB WAN 核心处理逻辑脚本

DEV="$1"
[ -z "$DEV" ] && exit 1

LOCK_FILE="/var/run/usb-wan-handler.lock"
if [ -e "$LOCK_FILE" ] && [ -d "/proc/$(cat $LOCK_FILE)" ]; then exit 0; fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

logger -t usb-wan-handler "开始处理设备 '$DEV'..."

if ! ([ -d "/sys/class/net/$DEV/device" ] && readlink "/sys/class/net/$DEV/device" | grep -qi "usb"); then
    logger -t usb-wan-handler "设备 '$DEV' 不是有效的USB网络设备，跳过。"
    exit 0
fi

logger -t usb-wan-handler "✅ 确认 '$DEV' 是USB网络设备，开始配置..."

uci set network.usb_wan='interface'
uci set network.usb_wan.proto='dhcp'
uci set network.usb_wan.device="$DEV"
uci set network.usb_wan.defaultroute='1'
uci set network.usb_wan.peerdns='1'
uci set network.usb_wan.ipv6='0'
uci set network.usb_wan.metric='10'

if uci -q get network.@device[0] >/dev/null; then
    uci delete network.usb_wan.ifname 2>/dev/null
else
    uci set network.usb_wan.ifname="$DEV"
fi

WAN_ZONE=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
[ -n "$WAN_ZONE" ] || WAN_ZONE="wan"
if uci -q get firewall."$WAN_ZONE" >/dev/null; then
    uci remove_list firewall."$WAN_ZONE".network="usb_wan" 2>/dev/null
    uci add_list firewall."$WAN_ZONE".network="usb_wan"
fi

uci commit network
uci commit firewall
logger -t usb-wan-handler "💾 配置已保存。"

logger -t usb-wan-handler "🚀 正在重启接口 'usb_wan'..."
ifdown usb_wan 2>/dev/null; sleep 1; ifup usb_wan

GATEWAY=""
RETRY_COUNT=0
MAX_RETRIES=15
logger -t usb-wan-handler "⏳ 正在等待网关地址就绪..."
while [ -z "$GATEWAY" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if [ ! -x "/usr/bin/jsonfilter" ]; then
        logger -t usb-wan-handler "错误: jsonfilter 工具未找到。"
        break
    fi
    GATEWAY=$(ubus call network.interface.usb_wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
    [ -z "$GATEWAY" ] && sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ -n "$GATEWAY" ]; then
    logger -t usb-wan-handler "✅ 成功获取到网关: $GATEWAY (耗时${RETRY_COUNT}秒)"
    if ! ip route show default | grep -q "dev $DEV"; then
        logger -t usb-wan-handler "⚠️ 默认路由仍缺失，尝试手动添加..."
        ip route add default via "$GATEWAY" dev "$DEV"
    fi
    if ping -c 2 -W 3 "$GATEWAY" >/dev/null 2>&1; then
        logger -t usb-wan-handler "🎉🎉🎉 网络连接成功！网关 ($GATEWAY) 可达。"
    else
        logger -t usb-wan-handler "❌ 警告：网关 ($GATEWAY) 无法 Ping 通。"
    fi
else
    logger -t usb-wan-handler "❌ 错误：在${MAX_RETRIES}秒内未能获取到网关地址！"
fi
EOF

# --- 2. 创建热插拔触发器 ---
mkdir -p "$FILES_PATH/etc/hotplug.d/net"
cat <<'EOF' > "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
DEV="${DEVICENAME:-$INTERFACE}"
[ -n "$DEV" ] && /usr/bin/usb-wan-handler.sh "$DEV" &
EOF

# --- 3. 创建开机自启触发器 ---
mkdir -p "$FILES_PATH/etc/init.d"
cat <<'EOF' > "$FILES_PATH/etc/init.d/usb-wan"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "
        sleep 20
        for dev_path in /sys/class/net/*; do
            dev_name=\$(basename \"\$dev_path\")
            if [ -d \"\$dev_path/device\" ] && readlink \"\$dev_path/device\" | grep -qi 'usb'; then
                /usr/bin/usb-wan-handler.sh \"\$dev_name\" &
                break
            fi
        done
    "
    procd_close_instance
}
boot() { start_service "$@"; }
EOF

# --- 4. 设置脚本执行权限 ---
chmod +x "$FILES_PATH/usr/bin/usb-wan-handler.sh"
chmod +x "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
chmod +x "$FILES_PATH/etc/init.d/usb-wan"

# --- 5. 设置服务开机自启 ---
# OpenWrt的编译系统会自动处理init.d目录下的脚本，无需手动创建软链接
# 我们只需要确保init.d脚本存在并且有可执行权限即可

echo " "
echo "✅ USB WAN 自动配置脚本已成功注入到编译目录。"
echo " "
