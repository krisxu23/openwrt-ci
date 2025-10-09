#!/bin/bash

echo " "
echo "Injecting SIMPLIFIED USB WAN auto-config (Mutually Exclusive Mode)..."

# 确保在正确目录
if [ -d "./wrt" ]; then
    cd ./wrt/
fi

# 创建目录
mkdir -p ./files/etc/hotplug.d/net
mkdir -p ./files/etc/init.d

# 1. 极简 net 热插拔脚本
cat <<'EOF' > ./files/etc/hotplug.d/net/99-usb-wan
#!/bin/sh
# USB WAN 自动配置 - 互斥模式
# 插入USB时自动创建并启动usb_wan，拔掉后自动回退到有线WAN

[ "$ACTION" = "add" ] || exit 0

DEV="${DEVICENAME:-$INTERFACE}"
[ -n "$DEV" ] || exit 0

logger -t usb-wan "USB设备检测: $DEV"

# USB网络设备匹配
case "$DEV" in
    usb*|eth*|wwan*|enx*|cdc*|rndis*|ncm*|ecm*|huawei*|zte*)
        if [ -d "/sys/class/net/$DEV/device" ] && readlink "/sys/class/net/$DEV/device" | grep -qi usb; then
            logger -t usb-wan "创建USB_WAN接口: $DEV"
            
            # 创建/更新usb_wan接口
            uci set network.usb_wan='interface'
            uci set network.usb_wan.proto='dhcp'
            uci set network.usb_wan.device="$DEV"
            uci set network.usb_wan.defaultroute='1'    # 直接作为默认路由
            uci set network.usb_wan.peerdns='1'
            uci set network.usb_wan.ipv6='0'            # 禁用IPv6
            
            # DSA架构兼容
            if uci -q get network.@device[0] >/dev/null; then
                uci delete network.usb_wan.ifname 2>/dev/null
            else
                uci set network.usb_wan.ifname="$DEV"
            fi
            
            # 防火墙配置
            WAN_ZONE=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
            [ -n "$WAN_ZONE" ] || WAN_ZONE="wan"
            
            if uci -q get firewall.$WAN_ZONE >/dev/null; then
                CUR_NETS=$(uci -q get firewall.$WAN_ZONE.network 2>/dev/null || echo '')
                echo "$CUR_NETS" | grep -qw "usb_wan" || uci add_list firewall.$WAN_ZONE.network="usb_wan"
            fi
            
            # 提交配置并启动
            uci commit network
            uci commit firewall
            
            # 立即启动USB_WAN（将成为默认路由）
            (sleep 3 && ifup usb_wan && logger -t usb-wan "USB_WAN已上线，成为默认路由") &
        fi
        ;;
esac
EOF

# 2. 简化启动脚本
cat <<'EOF' > ./files/etc/init.d/usb-wan
#!/bin/sh /etc/rc.common
# USB WAN 启动检测

START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "
        sleep 20
        logger -t usb-wan '启动USB设备扫描...'
        
        # 扫描启动时已插入的USB设备
        for dev in /sys/class/net/*; do
            dev_name=\$(basename \"\$dev\")
            case \"\$dev_name\" in
                usb*|eth*|wwan*|enx*|cdc*|rndis*)
                    if [ -d \"\$dev/device\" ] && readlink \"\$dev/device\" | grep -qi usb; then
                        logger -t usb-wan \"启动发现USB设备: \$dev_name\"
                        
                        # 配置USB_WAN
                        uci set network.usb_wan='interface'
                        uci set network.usb_wan.proto='dhcp'
                        uci set network.usb_wan.device=\"\$dev_name\"
                        uci set network.usb_wan.defaultroute='1'
                        uci set network.usb_wan.peerdns='1'
                        uci set network.usb_wan.ipv6='0'
                        
                        if uci -q get network.@device[0] >/dev/null; then
                            uci delete network.usb_wan.ifname 2>/dev/null
                        else
                            uci set network.usb_wan.ifname=\"\$dev_name\"
                        fi
                        
                        # 防火墙
                        WAN_ZONE=\$(uci show firewall | awk -F'[.=]' '/\\.name='\\''wan'\\''/{print \$2; exit}')
                        [ -n \"\$WAN_ZONE\" ] || WAN_ZONE=\"wan\"
                        
                        if uci -q get firewall.\$WAN_ZONE >/dev/null; then
                            CUR_NETS=\$(uci -q get firewall.\$WAN_ZONE.network 2>/dev/null || echo '')
                            echo \"\$CUR_NETS\" | grep -qw \"usb_wan\" || uci add_list firewall.\$WAN_ZONE.network=\"usb_wan\"
                        fi
                        
                        uci commit network
                        uci commit firewall
                        
                        # 启动USB_WAN
                        (sleep 5 && ifup usb_wan && logger -t usb-wan \"启动时USB_WAN已上线\") &
                        break
                    fi
                    ;;
            esac
        done
    "
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

boot() {
    start_service "$@"
}
EOF

# 权限设置
chmod +x ./files/etc/hotplug.d/net/99-usb-wan
chmod +x ./files/etc/init.d/usb-wan

echo "✅ 极简版 USB WAN 配置完成!"
echo " "
echo "🎯 工作模式: 互斥使用"
echo "  📱 插入USB → 自动创建usb_wan，设为默认路由"
echo "  🔌 拔掉USB → 自动回退到有线WAN"
echo "  🔄 不会同时使用两个网络"
echo " "
echo "⚡ 核心配置:"
echo "  - defaultroute=1 (USB直接作为默认路由)"
echo "  - 无需metric优先级"
echo "  - 无需防抖锁"
echo "  - 无需路由监控"
echo " "
echo "💡 使用方式:"
echo "  1. 用宽带: 插入网线到WAN口"
echo "  2. 用USB: 插入随身WiFi，自动切换"
echo "  3. 切换时无需任何手动配置"
echo " "
