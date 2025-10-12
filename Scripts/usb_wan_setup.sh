#!/bin/bash
#
# USB WAN 自动配置脚本
# 版本: 3.0.0
# 适用: 高通 IPQ6018 (1GB 内存), OpenWrt 环境
# 功能: 自动检测和配置 USB WAN 设备，增强性能监控和自动恢复
#

if [ -z "$GITHUB_WORKSPACE" ]; then 
    echo "错误：非 GitHub Actions 环境。"
    exit 1
fi

FILES_PATH="$GITHUB_WORKSPACE/wrt/files"

echo " "
echo "正在注入 USB WAN 自动配置脚本 (最终优化版 3.0.0)..."
echo " "

mkdir -p "$FILES_PATH/usr/bin" "$FILES_PATH/etc/hotplug.d/net" "$FILES_PATH/etc/init.d" "$FILES_PATH/etc/config"

# --- 1. 核心处理脚本 ---
cat << 'EOF' > "$FILES_PATH/usr/bin/usb-wan-core"
#!/bin/sh
# USB WAN 核心处理脚本 - 最终优化版
# 版本: 3.0.0

DEV="$1"
[ -n "$DEV" ] || { logger -t usb-wan "[ERROR] 未提供设备名称"; exit 1; }

# --- 增强日志系统 ---
log() {
    local level="$1"; shift
    local msg="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 日志级别控制
    [ "$level" = "DEBUG" ] && [ -z "$DEBUG" ] && return 0
    
    # 日志级别映射
    case "$level" in
        ERROR)   priority=3 ;;
        WARN)    priority=4 ;;
        INFO)    priority=6 ;;
        DEBUG)   priority=7 ;;
        *)       priority=6 ;;
    esac
    
    # 系统日志
    logger -p daemon.$priority -t usb-wan "[$level] $msg"
    
    # 文件日志（可选）
    if [ "$(uci -q get usb_wan.global.log_to_file)" = "1" ]; then
        echo "[$timestamp] [$level] $msg" >> /var/log/usb-wan.log
        
        # 日志轮转（保持最后1000行）
        if [ -f /var/log/usb-wan.log ] && [ $(wc -l < /var/log/usb-wan.log) -gt 1000 ]; then
            tail -n 500 /var/log/usb-wan.log > /var/log/usb-wan.log.tmp
            mv /var/log/usb-wan.log.tmp /var/log/usb-wan.log
        fi
    fi
}

# --- 读取配置 ---
ENABLED=$(uci -q get usb_wan.global.enabled)
[ "$ENABLED" = "0" ] && { log INFO "USB WAN 自动配置已禁用"; exit 0; }
DEBUG=$(uci -q get usb_wan.global.debug_mode)

# --- 依赖检查 ---
check_deps() {
    for cmd in uci ip ping jsonfilter; do
        command -v "$cmd" >/dev/null || { log ERROR "缺少依赖: $cmd"; exit 1; }
    done
}
check_deps

# --- 优化的锁文件机制 ---
acquire_lock() {
    local dev="$1"
    local lock_file="/var/lock/usb-wan-$dev.lock"
    local lock_fd=200
    
    # 创建锁文件
    eval "exec $lock_fd>$lock_file"
    
    # 尝试获取排他锁（非阻塞）
    if ! flock -n $lock_fd; then
        log INFO "设备 '$dev' 正在被处理，等待..."
        # 等待最多5秒
        if ! flock -w 5 $lock_fd; then
            log WARN "无法获取锁，跳过处理"
            return 1
        fi
    fi
    
    # 写入PID
    echo $$ >&$lock_fd
    
    # 设置trap以确保锁被释放
    trap "flock -u $lock_fd; eval \"exec $lock_fd>&-\"; rm -f $lock_file" EXIT INT TERM
    
    return 0
}

# 获取锁
acquire_lock "$DEV" || exit 0

# --- 优化的USB验证 ---
check_usb_device() {
    local dev="$1"
    local dev_path="/sys/class/net/$dev/device"
    
    [ ! -d "$dev_path" ] && return 1
    
    # 缓存readlink结果，避免重复调用
    local link_path=$(readlink -f "$dev_path" 2>/dev/null)
    
    # 一次性检查所有USB特征
    echo "$link_path" | grep -qE '/(usb|platform/.*usb)/' && return 0
    
    # 检查modalias
    [ -f "$dev_path/modalias" ] && grep -q "^usb:" "$dev_path/modalias" && return 0
    
    # 检查驱动
    if [ -d "$dev_path/driver" ]; then
        local driver_path=$(readlink -f "$dev_path/driver" 2>/dev/null)
        echo "$driver_path" | grep -qiE 'usb|cdc_ether|cdc_ncm|rndis|asix|rtl815|smsc95|ipheth|zte' && return 0
    fi
    
    return 1
}

if ! check_usb_device "$DEV"; then
    log INFO "设备 '$DEV' 不是 USB，跳过"
    exit 0
fi

# --- 获取设备优先级 ---
get_device_metric() {
    local dev="$1"
    local metric=$(uci -q get usb_wan.global.default_metric)
    metric=${metric:-50}
    
    # 检查特定设备优先级
    local priorities=$(uci -q get usb_wan.device_priority.priority 2>/dev/null)
    if [ -n "$priorities" ]; then
        for entry in $priorities; do
            local d="${entry%%:*}"
            local m="${entry##*:}"
            [ "$d" = "$dev" ] && { metric="$m"; break; }
        done
    fi
    
    echo "$metric"
}

METRIC=$(get_device_metric "$DEV")
log DEBUG "设备 '$DEV' 使用 metric: $METRIC"

# --- 配置网络 ---
configure_network() {
    local dev="$1"
    local metric="$2"
    
    # 备份当前配置
    uci export network > /tmp/network.backup
    uci export firewall > /tmp/firewall.backup
    
    # 设置网络接口
    uci set network.usb_wan=interface
    uci set network.usb_wan.proto='dhcp'
    uci set network.usb_wan.device="$dev"
    uci set network.usb_wan.defaultroute='1'
    uci set network.usb_wan.peerdns='1'
    uci set network.usb_wan.ipv6='0'
    uci set network.usb_wan.metric="$metric"
    uci set network.usb_wan.delegate='0'
    
    # 兼容性处理
    if uci -q get network.@device[0] >/dev/null; then
        uci delete network.usb_wan.ifname 2>/dev/null
    else
        uci set network.usb_wan.ifname="$dev"
    fi
    
    # 防火墙配置
    local wan_zone=$(uci show firewall | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
    [ -z "$wan_zone" ] && wan_zone="wan"
    uci remove_list firewall."$wan_zone".network="usb_wan" 2>/dev/null
    uci add_list firewall."$wan_zone".network="usb_wan"
    
    # 提交配置
    if ! uci commit network || ! uci commit firewall; then
        log ERROR "配置提交失败，回滚"
        uci import network < /tmp/network.backup 2>/dev/null
        uci import firewall < /tmp/firewall.backup 2>/dev/null
        uci commit network; uci commit firewall
        return 1
    fi
    
    return 0
}

# --- 增强网络连通性检测 ---
check_connectivity() {
    local dev="$1"
    local gateway="$2"
    local connectivity_score=0
    
    # 1. 检查网关
    if [ -n "$gateway" ]; then
        if ping -c 2 -W 2 -I "$dev" "$gateway" >/dev/null 2>&1; then
            log INFO "✅ 网关 $gateway 连通"
            connectivity_score=$((connectivity_score + 1))
        else
            log WARN "⚠️ 网关 $gateway 不可达"
        fi
    fi
    
    # 2. 检查DNS服务器
    local dns_servers="223.5.5.5 8.8.8.8 114.114.114.114"
    for dns in $dns_servers; do
        if ping -c 1 -W 1 -I "$dev" "$dns" >/dev/null 2>&1; then
            log INFO "✅ DNS $dns 可达"
            connectivity_score=$((connectivity_score + 1))
            break
        fi
    done
    
    # 3. 检查实际网络访问（如果有wget）
    if command -v wget >/dev/null; then
        local local_ip=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1 | head -n1)
        if [ -n "$local_ip" ]; then
            if wget -q --spider --timeout=5 --bind-address="$local_ip" http://www.baidu.com 2>/dev/null; then
                log INFO "✅ 互联网连接正常"
                connectivity_score=$((connectivity_score + 2))
            fi
        fi
    fi
    
    # 返回连通性评分
    return $((4 - connectivity_score))
}

# --- 自动恢复机制 ---
auto_recover() {
    local dev="$1"
    local max_retry=3
    local retry=0
    
    while [ $retry -lt $max_retry ]; do
        log INFO "尝试恢复连接 (第 $((retry+1))/$max_retry 次)..."
        
        # 重置接口
        ip link set "$dev" down 2>/dev/null
        sleep 1
        ip link set "$dev" up 2>/dev/null
        sleep 2
        
        # 重新配置
        ifdown usb_wan 2>/dev/null
        sleep 1
        ifup usb_wan
        
        # 等待DHCP
        local wait_count=0
        while [ $wait_count -lt 10 ]; do
            if ubus call network.interface.usb_wan status 2>/dev/null | grep -q '"up": true'; then
                log INFO "✅ 连接恢复成功"
                return 0
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        retry=$((retry + 1))
    done
    
    log ERROR "❌ 连接恢复失败"
    return 1
}

# --- 性能监控 ---
monitor_interface() {
    local dev="$1"
    
    # 获取接口统计
    local rx_bytes=$(cat /sys/class/net/$dev/statistics/rx_bytes 2>/dev/null || echo 0)
    local tx_bytes=$(cat /sys/class/net/$dev/statistics/tx_bytes 2>/dev/null || echo 0)
    local rx_errors=$(cat /sys/class/net/$dev/statistics/rx_errors 2>/dev/null || echo 0)
    local tx_errors=$(cat /sys/class/net/$dev/statistics/tx_errors 2>/dev/null || echo 0)
    local rx_dropped=$(cat /sys/class/net/$dev/statistics/rx_dropped 2>/dev/null || echo 0)
    local tx_dropped=$(cat /sys/class/net/$dev/statistics/tx_dropped 2>/dev/null || echo 0)
    
    # 保存统计信息
    uci set usb_wan.stats=interface_stats
    uci set usb_wan.stats.device="$dev"
    uci set usb_wan.stats.rx_bytes="$rx_bytes"
    uci set usb_wan.stats.tx_bytes="$tx_bytes"
    uci set usb_wan.stats.rx_errors="$rx_errors"
    uci set usb_wan.stats.tx_errors="$tx_errors"
    uci set usb_wan.stats.rx_dropped="$rx_dropped"
    uci set usb_wan.stats.tx_dropped="$tx_dropped"
    uci set usb_wan.stats.last_update="$(date '+%s')"
    uci commit usb_wan
    
    # 检查错误率
    local total_errors=$((rx_errors + tx_errors + rx_dropped + tx_dropped))
    if [ $total_errors -gt 100 ]; then
        log WARN "接口 $dev 错误率较高 (总错误: $total_errors)"
        return 1
    fi
    
    return 0
}

# === 主逻辑开始 ===

log INFO "开始配置设备 '$DEV'"

# 配置网络
if ! configure_network "$DEV" "$METRIC"; then
    log ERROR "网络配置失败"
    exit 1
fi

# 启动接口
ifdown usb_wan 2>/dev/null
sleep 0.5
ifup usb_wan

# 等待DHCP获取IP
log INFO "等待DHCP分配..."
DHCP_TIMEOUT=15
DHCP_WAIT=0
GATEWAY=""

while [ $DHCP_WAIT -lt $DHCP_TIMEOUT ]; do
    STATUS=$(ubus call network.interface.usb_wan status 2>/dev/null)
    if echo "$STATUS" | grep -q '"up": true'; then
        GATEWAY=$(echo "$STATUS" | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' 2>/dev/null)
        [ -z "$GATEWAY" ] && GATEWAY=$(echo "$STATUS" | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
        [ -n "$GATEWAY" ] && break
    fi
    sleep 1
    DHCP_WAIT=$((DHCP_WAIT + 1))
    [ $((DHCP_WAIT % 5)) -eq 0 ] && log DEBUG "等待DHCP... ($DHCP_WAIT/$DHCP_TIMEOUT)"
done

# 检查配置结果
if [ -z "$GATEWAY" ]; then
    log WARN "未获取到网关，尝试恢复..."
    if auto_recover "$DEV"; then
        # 重新获取网关
        STATUS=$(ubus call network.interface.usb_wan status 2>/dev/null)
        GATEWAY=$(echo "$STATUS" | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' 2>/dev/null)
    fi
fi

# 最终结果
EXIT_CODE=0
if [ -n "$GATEWAY" ]; then
    log INFO "✅ 获取网关: $GATEWAY"
    
    # 确保默认路由
    if ! ip route show default | grep -q "dev $DEV"; then
        log INFO "添加默认路由..."
        ip route add default via "$GATEWAY" dev "$DEV" metric "$METRIC" 2>/dev/null || true
    fi
    
    # 连通性检测
    if check_connectivity "$DEV" "$GATEWAY"; then
        log INFO "✅ 网络连接正常"
    else
        log WARN "⚠️ 网络连接存在问题"
        EXIT_CODE=1
    fi
    
    # 性能监控
    monitor_interface "$DEV"
    
    # 记录成功配置
    uci set usb_wan.last_config=status
    uci set usb_wan.last_config.device="$DEV"
    uci set usb_wan.last_config.gateway="$GATEWAY"
    uci set usb_wan.last_config.metric="$METRIC"
    uci set usb_wan.last_config.timestamp="$(date '+%s')"
    uci commit usb_wan
    
else
    log ERROR "❌ 配置失败：未获取到网关"
    EXIT_CODE=1
fi

log INFO "设备 '$DEV' 配置完成 (退出码: $EXIT_CODE)"
exit $EXIT_CODE
EOF

# --- 2. 热插拔触发器 ---
cat << 'EOF' > "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
#!/bin/sh
# USB WAN 热插拔触发脚本 - 最终优化版
# 版本: 3.0.0

log() {
    local level="$1"; shift
    logger -t usb-wan-hotplug "[$level] $@"
}

DEV="${DEVICENAME:-$INTERFACE}"
[ -z "$DEV" ] && exit 0

case "$ACTION" in
    add)
        log INFO "检测到设备 '$DEV' 插入"
        
        # 对RNDIS设备延迟处理
        [ "$(echo "$DEV" | grep -i '^rndis')" ] && sleep 1.5 || sleep 0.3
        
        # 异步启动配置
        ( /usr/bin/usb-wan-core "$DEV" 2>&1 | logger -t usb-wan ) &
        ;;
        
    remove)
        log INFO "设备 '$DEV' 已移除"
        
        # 清理配置
        CURRENT_DEV=$(uci -q get network.usb_wan.device)
        if [ "$CURRENT_DEV" = "$DEV" ]; then
            # 停止接口
            ifdown usb_wan 2>/dev/null
            
            # 删除配置
            uci -q delete network.usb_wan
            WAN_ZONE=$(uci show firewall 2>/dev/null | awk -F'[.=]' '/\.name='\''wan'\''/{print $2; exit}')
            [ -n "$WAN_ZONE" ] && uci remove_list firewall."$WAN_ZONE".network="usb_wan" 2>/dev/null
            
            # 清理统计信息
            uci -q delete usb_wan.stats 2>/dev/null
            uci -q delete usb_wan.last_config 2>/dev/null
            
            # 提交更改
            uci commit network
            uci commit firewall
            uci commit usb_wan
            
            log INFO "设备 '$DEV' 配置已清理"
        fi
        
        # 清理锁文件
        rm -f "/var/lock/usb-wan-$DEV.lock" 2>/dev/null
        ;;
esac
EOF

# --- 3. 开机自启脚本 ---
cat << 'EOF' > "$FILES_PATH/etc/init.d/usb-wan"
#!/bin/sh /etc/rc.common
# USB WAN 开机自启脚本 - 最终优化版
# 版本: 3.0.0

START=99
STOP=10
USE_PROCD=1

start_service() {
    # 检查是否启用
    [ "$(uci -q get usb_wan.global.enabled)" = "0" ] && {
        logger -t usb-wan "[BOOT] USB WAN 自动配置已禁用"
        return 0
    }
    
    procd_open_instance
    procd_set_param command /bin/sh -c '
        # 等待系统基本服务就绪
        sleep 3
        
        logger -t usb-wan "[BOOT] 开始扫描USB网络设备..."
        
        # 并行扫描所有网络设备
        scan_count=0
        process_count=0
        
        for dev_path in /sys/class/net/*; do
            [ ! -d "$dev_path" ] && continue
            
            dev=$(basename "$dev_path")
            
            # 跳过虚拟和无关接口
            case "$dev" in
                lo|br-*|docker*|veth*|tun*|tap*|wlan*|bond*|gre*|ppp*|sit*|ip6*)
                    continue
                    ;;
            esac
            
            scan_count=$((scan_count + 1))
            
            # 异步检查和处理每个设备
            (
                # 快速USB检查
                is_usb=0
                if [ -f "$dev_path/device/modalias" ]; then
                    grep -q "^usb:" "$dev_path/device/modalias" 2>/dev/null && is_usb=1
                elif [ -d "$dev_path/device" ]; then
                    readlink "$dev_path/device" 2>/dev/null | grep -q "usb" && is_usb=1
                fi
                
                if [ $is_usb -eq 1 ]; then
                    logger -t usb-wan "[BOOT] 发现USB设备: $dev"
                    /usr/bin/usb-wan-core "$dev"
                    process_count=$((process_count + 1))
                fi
            ) &
            
            # 限制并发数
            if [ $((scan_count % 5)) -eq 0 ]; then
                wait
            fi
        done
        
        # 等待所有后台任务完成
        wait
        
        logger -t usb-wan "[BOOT] 扫描完成，共检查 $scan_count 个设备"
    '
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    # 清理所有USB WAN配置
    if uci -q get network.usb_wan >/dev/null; then
        ifdown usb_wan 2>/dev/null
        uci -q delete network.usb_wan
        uci commit network
    fi
    
    # 清理锁文件
    rm -f /var/lock/usb-wan-*.lock 2>/dev/null
}

reload_service() {
    stop
    start
}
EOF

# --- 4. 健康检查脚本 ---
cat << 'EOF' > "$FILES_PATH/usr/bin/usb-wan-health"
#!/bin/sh
# USB WAN 健康检查脚本 - 最终优化版
# 版本: 3.0.0

log() {
    logger -t usb-wan-health "$@"
}

check_interface_health() {
    local iface="usb_wan"
    
    # 检查是否启用
    [ "$(uci -q get usb_wan.global.enabled)" = "0" ] && return 0
    
    # 检查接口是否存在
    if ! uci -q get network.$iface >/dev/null; then
        return 0  # 没有配置，正常
    fi
    
    # 获取接口状态
    local status=$(ubus call network.interface.$iface status 2>/dev/null)
    [ -z "$status" ] && {
        log "无法获取接口状态"
        return 1
    }
    
    # 检查是否UP
    if ! echo "$status" | grep -q '"up": true'; then
        log "接口 $iface 状态异常，尝试恢复"
        ifup $iface
        sleep 3
        
        # 再次检查
        status=$(ubus call network.interface.$iface status 2>/dev/null)
        if ! echo "$status" | grep -q '"up": true'; then
            log "接口恢复失败"
            return 1
        fi
    fi
    
    # 检查连通性
    local device=$(echo "$status" | jsonfilter -e '@.device' 2>/dev/null)
    if [ -n "$device" ]; then
        # 获取网关
        local gateway=$(echo "$status" | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' 2>/dev/null)
        
        if [ -n "$gateway" ]; then
            # Ping网关
            if ! ping -c 2 -W 2 -I "$device" "$gateway" >/dev/null 2>&1; then
                log "网关 $gateway 不可达，重启接口"
                ifdown $iface && sleep 2 && ifup $iface
                return 1
            fi
            
            # 检查DNS
            local dns_ok=0
            for dns in 223.5.5.5 8.8.8.8; do
                if ping -c 1 -W 1 -I "$device" "$dns" >/dev/null 2>&1; then
                    dns_ok=1
                    break
                fi
            done
            
            if [ $dns_ok -eq 0 ]; then
                log "DNS服务器不可达"
                # 尝试重新获取DHCP
                kill -USR1 $(cat /var/run/udhcpc-$iface.pid 2>/dev/null) 2>/dev/null
            fi
        fi
        
        # 检查接口错误
        local errors=$(cat /sys/class/net/$device/statistics/*_errors 2>/dev/null | awk '{s+=$1} END {print s}')
        if [ -n "$errors" ] && [ $errors -gt 1000 ]; then
            log "接口错误过多 ($errors)，重置接口"
            ip link set "$device" down && sleep 1 && ip link set "$device" up
        fi
    fi
    
    return 0
}

# 执行健康检查
check_interface_health
exit $?
EOF

# --- 5. 状态查询脚本 ---
cat << 'EOF' > "$FILES_PATH/usr/bin/usb-wan-status"
#!/bin/sh
# USB WAN 状态查询脚本
# 版本: 3.0.0

echo "========================================="
echo "         USB WAN 状态信息"
echo "========================================="

# 配置状态
echo -e "\n[配置状态]"
enabled=$(uci -q get usb_wan.global.enabled)
echo "自动配置: ${enabled:-1} (0=禁用, 1=启用)"
debug=$(uci -q get usb_wan.global.debug_mode)
echo "调试模式: ${debug:-0}"

# 接口状态
echo -e "\n[接口状态]"
if uci -q get network.usb_wan >/dev/null; then
    device=$(uci -q get network.usb_wan.device)
    echo "配置设备: $device"
    
    status=$(ubus call network.interface.usb_wan status 2>/dev/null)
    if [ -n "$status" ]; then
        up=$(echo "$status" | jsonfilter -e '@.up')
        echo "接口状态: $([ "$up" = "true" ] && echo "已连接" || echo "未连接")"
        
        if [ "$up" = "true" ]; then
            ipaddr=$(echo "$status" | jsonfilter -e '@["ipv4-address"][0].address')
            gateway=$(echo "$status" | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop')
            dns=$(echo "$status" | jsonfilter -e '@["dns-server"][0]')
            
            echo "IP 地址: ${ipaddr:-无}"
            echo "网关地址: ${gateway:-无}"
            echo "DNS 服务器: ${dns:-无}"
        fi
    fi
else
    echo "未配置USB WAN接口"
fi

# 统计信息
echo -e "\n[统计信息]"
if [ -n "$(uci -q get usb_wan.stats.device)" ]; then
    dev=$(uci -q get usb_wan.stats.device)
    rx_bytes=$(uci -q get usb_wan.stats.rx_bytes)
    tx_bytes=$(uci -q get usb_wan.stats.tx_bytes)
    rx_errors=$(uci -q get usb_wan.stats.rx_errors)
    tx_errors=$(uci -q get usb_wan.stats.tx_errors)
    last_update=$(uci -q get usb_wan.stats.last_update)
    
    echo "统计设备: $dev"
    echo "接收字节: $(numfmt --to=iec-i --suffix=B ${rx_bytes:-0} 2>/dev/null || echo ${rx_bytes:-0})"
    echo "发送字节: $(numfmt --to=iec-i --suffix=B ${tx_bytes:-0} 2>/dev/null || echo ${tx_bytes:-0})"
    echo "接收错误: ${rx_errors:-0}"
    echo "发送错误: ${tx_errors:-0}"
    
    if [ -n "$last_update" ]; then
        echo "更新时间: $(date -d "@$last_update" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo $last_update)"
    fi
else
    echo "暂无统计信息"
fi

# USB设备列表
echo -e "\n[USB网络设备]"
found_usb=0
for dev_path in /sys/class/net/*; do
    [ ! -d "$dev_path" ] && continue
    dev=$(basename "$dev_path")
    
    # 跳过虚拟接口
    case "$dev" in
        lo|br-*|docker*|veth*|tun*|tap*|wlan*|bond*|gre*) continue ;;
    esac
    
    # 检查是否为USB设备
    if [ -f "$dev_path/device/modalias" ] && grep -q "^usb:" "$dev_path/device/modalias" 2>/dev/null; then
        found_usb=1
        echo "• $dev"
        
        # 显示驱动信息
        if [ -d "$dev_path/device/driver" ]; then
            driver=$(basename $(readlink "$dev_path/device/driver" 2>/dev/null) 2>/dev/null)
            [ -n "$driver" ] && echo "  驱动: $driver"
        fi
        
        # 显示状态
        if [ -f "$dev_path/operstate" ]; then
            state=$(cat "$dev_path/operstate")
            echo "  状态: $state"
        fi
    fi
done

[ $found_usb -eq 0 ] && echo "未检测到USB网络设备"

echo -e "\n========================================="
EOF

# --- 6. 配置文件 ---
cat << 'EOF' > "$FILES_PATH/etc/config/usb_wan"
config usb_wan 'global'
    option enabled '1'
    option debug_mode '0'
    option log_to_file '0'
    option default_metric '50'

config device_priority 'device_priority'
    list priority 'eth1:10'
    list priority 'eth2:15'
    list priority 'usb0:20'
    list priority 'usb1:25'
    list priority 'rndis0:30'
    list priority 'rndis1:35'
    list priority 'cdc-wdm0:40'
    list priority 'wwan0:45'
EOF

# --- 7. 添加 cron 健康检查（可选） ---
cat << 'EOF' > "$FILES_PATH/etc/cron.d/usb-wan-health"
# USB WAN 健康检查 - 每5分钟执行一次
*/5 * * * * /usr/bin/usb-wan-health >/dev/null 2>&1
EOF

# --- 设置权限 ---
chmod +x "$FILES_PATH/usr/bin/usb-wan-core"
chmod +x "$FILES_PATH/usr/bin/usb-wan-health"
chmod +x "$FILES_PATH/usr/bin/usb-wan-status"
chmod +x "$FILES_PATH/etc/hotplug.d/net/99-usb-wan"
chmod +x "$FILES_PATH/etc/init.d/usb-wan"

echo " "
echo "✅ USB WAN 自动配置脚本 (最终优化版 3.0.0) 已成功注入！"
echo " "
echo "📋 主要功能特性:"
echo "   • 智能USB设备识别与验证"
echo "   • 设备优先级管理 (可配置metric)"
echo "   • 增强的连通性检测 (网关/DNS/互联网)"
echo "   • 自动故障恢复机制 (3次重试)"
echo "   • 实时性能监控与统计"
echo "   • 健康检查与自动修复"
echo "   • 优化的并发处理"
echo "   • 完善的日志系统"
echo " "
echo "🔧 使用说明:"
echo "   • 启用/禁用: uci set usb_wan.global.enabled=1/0"
echo "   • 调试模式: uci set usb_wan.global.debug_mode=1"
echo "   • 文件日志: uci set usb_wan.global.log_to_file=1"
echo "   • 查看状态: /usr/bin/usb-wan-status"
echo "   • 健康检查: /usr/bin/usb-wan-health"
echo "   • 系统日志: logread | grep -E 'usb-wan'"
echo "   • 文件日志: cat /var/log/usb-wan.log"
echo " "
echo "📝 配置优先级:"
echo "   • 编辑 /etc/config/usb_wan 中的 device_priority"
echo "   • 格式: list priority 'device:metric'"
echo "   • metric值越小优先级越高"
echo " "
echo "⚡ 性能优化:"
echo "   • 使用flock确保进程安全"
echo "   • 并行扫描USB设备"
echo "   • 智能缓存系统调用"
echo "   • 自动日志轮转"
echo " "
