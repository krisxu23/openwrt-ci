#!/bin/bash

# =================================================================
#            USB WAN 自动配置脚本注入模块
# =================================================================
#
#   功能：在固件中添加一个热插拔脚本，用于自动识别
#         并通过 DHCP 配置 USB 网络共享（如手机共享）。
#
# =================================================================

echo " "
echo "Injecting USB WAN auto-config script..."

# 在编译目录的 files 文件夹下创建对应路径
# OpenWrt 编译系统会自动将 ./files/ 目录下的所有文件复制到固件根目录
mkdir -p ./files/etc/hotplug.d/iface

# 创建热插拔脚本文件
cat <<'EOF' > ./files/etc/hotplug.d/iface/99-usb-wan
#!/bin/sh
# Auto-create or update 'USB' WAN interface when a USB network device goes up
# Compatible with usbX / ethX / wwanX / enxXXXX interfaces
# Author: kris_xu | Final revision: 2025-10-08

[ "$ACTION" = "ifup" ] || exit 0

case "$INTERFACE" in
    usb[0-9]*|eth[1-9]*|wwan[0-9]*|enx*)
        logger -t usb-wan "Detected interface up: $INTERFACE (device: $DEVICE)"

        [ -x /sbin/uci ] || exit 0

        # Create or update 'USB' interface
        if ! uci -q get network.USB >/dev/null; then
            uci set network.USB='interface'
            uci set network.USB.proto='dhcp'
        fi
        uci set network.USB.device="$DEVICE"
        uci commit network

        # Find firewall zone named 'wan' (OpenWrt standard format)
        WAN_ZONE=$(uci show firewall | grep "=wan$" | cut -d. -f2 | head -n1)
        [ -n "$WAN_ZONE" ] || WAN_ZONE="wan"

        # Add USB interface to WAN zone if not already included
        if ! uci get firewall.$WAN_ZONE.network 2>/dev/null | grep -qw "USB"; then
            uci add_list firewall.$WAN_ZONE.network="USB"
            uci commit firewall
            /etc/init.d/firewall reload
            logger -t usb-wan "Added USB to firewall zone: $WAN_ZONE"
        fi

        /etc/init.d/network reload
        logger -t usb-wan "USB WAN interface configured successfully for $DEVICE"
        ;;
esac
EOF

# 赋予该热插拔脚本可执行权限
chmod +x ./files/etc/hotplug.d/iface/99-usb-wan

echo "USB WAN auto-config script injected successfully."
echo " "
