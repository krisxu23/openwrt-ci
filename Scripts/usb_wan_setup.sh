#!/bin/bash
#
# USB WAN 自动配置 - 最终模块化安装脚本
#

echo " "
echo "正在安装模块化 USB WAN 自动配置脚本..."
echo "这将会创建三个文件："
echo "  1. /usr/bin/usb-wan-handler.sh  (核心逻辑)"
echo "  2. /etc/hotplug.d/net/99-usb-wan (热插拔触发器)"
echo "  3. /etc/init.d/usb-wan           (开机自启触发器)"
echo " "

# --- 1. 创建核心逻辑脚本 ---
# 这个脚本包含了所有的配置、重启和验证逻辑
mkdir -p /usr/bin
cat <<'EOF' > /usr/bin/usb-wan-handler.sh
#!/bin/sh
# USB WAN 核心处理逻辑脚本

# 从第一个参数获取设备名
DEV="$1"

# 如果没有提供设备名，则退出
if [ -z "$DEV" ]; then
    logger -t usb-wan-handler "错误：没有提供设备名称。"
    exit 1
fi

# --- 锁机制，防止并发执行 ---
LOCK_FILE="/var/run/usb-wan-handler.lock"
if [ -e "$LOCK_FILE" ] && [ -d "/proc/$(cat $LOCK_FILE)" ]; then
    logger -t usb-wan-handler "检测到已有进程正在配置，本次事件 '$DEV' 将被跳过。"
    exit 0
fi
echo $$ > "$LOCK_FILE"
# 脚本退出时自动删除锁文件
trap 'rm -f "$LOCK_FILE"' EXIT

logger -t usb-wan-handler "开始处理设备 '$DEV'..."

# 最终验证这确实是一个USB网络设备
if ! ([ -d "/sys/class/net/$DEV/device" ] && readlink "/sys/class/net/$DEV/device" | grep -qi "usb"); then
    logger -t usb-wan-handler "设备 '$DEV' 不是一个有效的USB网络设备，已跳过。"
    exit 0
fi

logger -t usb-wan-handler "✅ 确认 '$DEV' 是USB网络设备，开始配置..."

# 1. 配置 network 和 firewall
uci set network.usb_wan='interface'
uci set network.usb_wan.proto='dhcp'
uci set network.usb_wan.device="$DEV"
uci set network.usb_wan.defaultroute='1'
uci set network.usb_wan.peerdns='1'
uci set network.usb_wan.ipv6='0'
uci set network.usb_wan.metric='10'

# DSA 架构兼容
if uci -q get network.@device[0] >/dev/null; then
    uci delete network.usb_wan.ifname 2>/dev/null
else
    uci set network.usb_wan.ifname="$DEV"
fi

# 添加到 'wan' 防火墙区域
WAN_ZONE=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
[ -n "$WAN_ZONE" ] || WAN_ZONE="wan"
if uci -q get firewall."$WAN_ZONE" >/dev/null; then
    # 先清理旧的列表项再添加，防止重复
    uci remove_list firewall."$WAN_ZONE".network="usb_wan" 2>/dev/null
    uci add_list firewall."$WAN_ZONE".network="usb_wan"
fi

uci commit network
uci commit firewall
logger -t usb-wan-handler "💾 配置已保存。"

# 2. 关键修复：重启接口并等待网关就绪
logger -t usb-wan-handler "🚀 正在重启接口 'usb_wan'..."
ifdown usb_wan 2>/dev/null
sleep 1
ifup usb_wan

# 轮询获取网关，取代固定sleep
GATEWAY=""
RETRY_COUNT=0
MAX_RETRIES=15 # 最多等待15秒
logger -t usb-wan-handler "⏳ 正在等待网关地址就绪..."
while [ -z "$GATEWAY" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # 检查jsonfilter是否存在
    if [ ! -x "/usr/bin/jsonfilter" ]; then
        logger -t usb-wan-handler "错误: jsonfilter 工具未找到 (通常由 jshn 包提供)。"
        break
    fi
    GATEWAY=$(ubus call network.interface.usb_wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
    [ -z "$GATEWAY" ] && sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ -n "$GATEWAY" ]; then
    logger -t usb-wan-handler "✅ 成功获取到网关: $GATEWAY (耗时${RETRY_COUNT}秒)"
    # 再次验证默认路由
    if ! ip route show default | grep -q "dev $DEV"; then
        logger -t usb-wan-handler "⚠️ 默认路由仍缺失，尝试手动添加..."
        ip route add default via "$GATEWAY" dev "$DEV"
    fi
    # 测试连通性
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
# 这个脚本非常简单，只负责在事件发生时调用核心脚本
mkdir -p /etc/hotplug.d/net
cat <<'EOF' > /etc/hotplug.d/net/99-usb-wan
#!/bin/sh
# USB WAN 热插拔触发器

# 仅在设备添加时触发
[ "$ACTION" = "add" ] || exit 0

DEV="${DEVICENAME:-$INTERFACE}"
[ -n "$DEV" ] || exit 0

logger -t usb-wan-hotplug "检测到设备 '$DEV' 插入，正在调用核心处理器..."

# 在后台调用核心逻辑脚本，并传递设备名
/usr/bin/usb-wan-handler.sh "$DEV" &
EOF

# --- 3. 创建开机自启触发器 ---
# 这个脚本也只负责在开机时扫描设备并调用核心脚本
mkdir -p /etc/init.d
cat <<'EOF' > /etc/init.d/usb-wan
#!/bin/sh /etc/rc.common
# USB WAN 启动检测服务

START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "
        # 延迟20秒，等待系统完全就绪
        sleep 20
        logger -t usb-wan-init '系统启动: 开始扫描已连接的USB网络设备...'
        
        # 扫描所有网络接口
        for dev_path in /sys/class/net/*; do
            dev_name=\$(basename \"\$dev_path\")
            
            # 匹配可能的USB设备类型
            case \"\$dev_name\" in
                usb*|eth*|wwan*|enx*|cdc*|rndis*)
                    # 确认是USB设备
                    if [ -d \"\$dev_path/device\" ] && readlink \"\$dev_path/device\" | grep -qi 'usb'; then
                        logger -t usb-wan-init \"启动时发现USB设备: \$dev_name，正在调用核心处理器...\"
                        
                        # 在后台调用核心逻辑脚本
                        /usr/bin/usb-wan-handler.sh \"\$dev_name\" &
                        
                        # 找到第一个后就退出循环
                        break
                    fi
                    ;;
            esac
        done
        logger -t usb-wan-init '系统启动扫描完成。'
    "
    procd_close_instance
}

boot() {
    start_service "$@"
}
EOF

# --- 4. 设置权限并启用服务 ---
chmod +x /usr/bin/usb-wan-handler.sh
chmod +x /etc/hotplug.d/net/99-usb-wan
chmod +x /etc/init.d/usb-wan
/etc/init.d/usb-wan enable

echo " "
echo "✅ 安装完成！"
echo " "
echo "🎯 工作模式:"
echo "  - 核心逻辑分离，易于维护。"
echo "  - 支持热插拔和开机自动检测。"
echo "  - 自动修复路由，轮询等待网关，稳定可靠。"
echo " "
echo "💡 现在您可以插入USB网络设备进行测试了。"
echo "   使用 'logread -f' 命令可以实时查看日志。"
echo " "
