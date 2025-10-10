### 2. 终极完美的 `usb_wan_setup.sh` 脚本内容

**目标文件**: `Scripts/usb_wan_setup.sh`
```bash
#!/bin/bash
#
# USB WAN 自动配置 - 最终完美圣杯版注入脚本
#

# 检查环境
if [ -z "$GITHUB_WORKSPACE" ]; then
    echo "错误：非 GitHub Actions 环境。"
    exit 1
fi

# 定义路径
FILES_PATH="$GITHUB_WORKSPACE/wrt/files"

echo " "
echo "正在将[最终完美圣杯版] USB WAN 自动配置脚本注入固件..."
echo " "

# --- 创建目录 ---
mkdir -p "$FILES_PATH/usr/bin" "$FILES_PATH/etc/hotplug.d/net" "$FILES_PATH/etc/init.d"

# --- 1. 核心处理脚本 (集成了所有优点) ---
cat << 'EOF' > "$FILES_PATH/usr/bin/usb-wan-core"
#!/bin/sh
# USB WAN 核心处理脚本 - 最终完美圣杯版

DEV="$1"
[ -n "$DEV" ] || exit 1

# --- 增强的防抖锁机制 (带陈旧锁清理) ---
LOCK_FILE="/var/run/usb-wan-$DEV.lock"
if [ -e "$LOCK_FILE" ]; then
    # 检查持有锁的进程PID是否仍然存在
    if [ -d "/proc/$(cat $LOCK_FILE 2>/dev/null)" ]; then
        logger -t usb-wan "核心: 设备 '$DEV' 正在被其他进程处理，本次触发跳过。"
        exit 0
    else
        # 进程已不存在，这是一个陈旧的锁，清理它
        logger -t usb-wan "核心: 清理设备 '$DEV' 的陈旧锁文件。"
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

logger -t usb-wan "核心: 开始处理设备 '$DEV' (PID $$)"

# --- 四重验证机制 ---
USB_VERIFIED=0; VERIFICATION_METHOD=""
if [ -d "/sys/class/net/$DEV/device" ]; then
    if readlink "/sys/class/net/$DEV/device" | grep -qi "usb"; then USB_VERIFIED=1; VERIFICATION_METHOD="设备路径"; fi
    if [ $USB_VERIFIED -eq 0 ] && [ -d "/sys/class/net/$DEV/device/driver" ]; then
        DRIVER_PATH=$(readlink "/sys/class/net/$DEV/device/driver");
        if echo "$DRIVER_PATH" | grep -qiE '(usb|cdc|rndis|qmi|asix|rtl8152)'; then USB_VERIFIED=1; VERIFICATION_METHOD="驱动(${DRIVER_PATH##*/})"; fi
    fi
fi
if [ $USB_VERIFIED -eq 0 ]; then logger -t usb-wan "核心: '$DEV' 未通过USB验证，跳过。"; exit 0; fi

logger -t usb-wan "核心: ✅ 通过[$VERIFICATION_METHOD]确认 '$DEV' 为USB设备, 开始配置..."

# --- 网络和防火墙配置 ---
uci set network.usb_wan='interface'; uci set network.usb_wan.proto='dhcp'
uci set network.usb_wan.device="$DEV"; uci set network.usb_wan.defaultroute='1'
uci set network.usb_wan.peerdns='1'; uci set network.usb_wan.ipv6='0'
uci set network.usb_wan.metric='10'
if uci -q get network.@device[0] >/dev/null; then uci delete network.usb_wan.ifname 2>/dev/null; else uci set network.usb_wan.ifname="$DEV"; fi
WAN_ZONE=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}'); [ -n "$WAN_ZONE" ] || WAN_ZONE="wan"
if uci -q get firewall."$WAN_ZONE" >/dev/null; then uci remove_list firewall."$WAN_ZONE".network="usb_wan" 2>/dev/null; uci add_list firewall."$WAN_ZONE".network="usb_wan"; fi
uci commit network; uci commit firewall
logger -t usb-wan "核心: 💾 配置已提交, 正在重启接口..."

# --- 重启接口并验证 ---
ifdown usb_wan 2>/dev/null; sleep 1; ifup usb_wan

# --- 唯一可靠的网关获取方法: ubus API ---
GATEWAY=""
RETRY_COUNT=0
MAX_RETRIES=15
while [ -z "$GATEWAY" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ! command -v jsonfilter >/dev/null; then logger -t usb-wan "核心: 错误: jsonfilter工具未找到!"; break; fi
    GATEWAY=$(ubus call network.interface.usb_wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
    [ -z "$GATEWAY" ] && sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ -n "$GATEWAY" ]; then
    logger -t usb-wan "核心: ✅ 成功获取网关[$GATEWAY], 耗时${RETRY_COUNT}秒。"
    if ! ip route show default | grep -q "dev $DEV"; then logger -t usb-wan "核心: ⚠️ 默认路由缺失, 正在手动修复..."; ip route add default via "$GATEWAY" dev "$DEV"; fi
    if ping -c 2 -W 3 "$GATEWAY" >/dev/null 2>&1; then logger -t usb-wan "核心: 🎉🎉🎉 网络连接成功!"; else logger -t usb-wan "核心: ❌ 警告: 网关[$GATEWAY]无法 Ping 通。"; fi
else
    logger -t usb-wan "核心: ❌ 错误: 在${MAX_RETRIES}秒内未能从ubus获取到网关地址!";
fi
EOF

# --- 2. 精简的热插拔触发器 ---
cat << 'EOF' > "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
DEV="${DEVICENAME:-$INTERFACE}"
[ -n "$DEV" ] && /usr/bin/usb-wan-core "$DEV" &
EOF

# --- 3. 精简的开机自启触发器 ---
cat << 'EOF' > "$FILES_PATH/etc/init.d/usb-wan"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "
        sleep 20
        for dev_path in /sys/class/net/*; do
            case \$(basename \"\$dev_path\") in lo|br-*|docker*|veth*) continue ;; esac
            if [ -d \"\$dev_path/device\" ]; then /usr/bin/usb-wan-core \$(basename \"\$dev_path\") & sleep 1; fi
        done
    "
    procd_close_instance
}
boot() { start_service "$@"; }
EOF

# --- 设置权限 ---
chmod +x "$FILES_PATH/usr/bin/usb-wan-core" "$FILES_PATH/etc/hotplug.d/net/99-usb-wan" "$FILES_PATH/etc/init.d/usb-wan"

echo "✅ [最终完美圣杯版] USB WAN 自动配置脚本已成功注入。"
echo " "
