#!/bin/bash

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"

#预置HomeProxy数据
if [ -d *"homeproxy"* ]; then
	echo " "

	HP_RULE="surge"
	HP_PATH="homeproxy/root/etc/homeproxy"

	rm -rf ./$HP_PATH/resources/*

	git clone -q --depth=1 --single-branch --branch "release" "https://github.com/Loyalsoldier/surge-rules.git" ./$HP_RULE/
	cd ./$HP_RULE/ && RES_VER=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")

	echo $RES_VER | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
	awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
	sed 's/^\.//g' direct.txt > china_list.txt ; sed 's/^\.//g' gfw.txt > gfw_list.txt
	mv -f ./{china_*,gfw_list}.{ver,txt} ../$HP_PATH/resources/

	cd .. && rm -rf ./$HP_RULE/

	cd $PKG_PATH && echo "homeproxy date has been updated!"
fi

#修改argon主题字体和颜色
if [ -d *"luci-theme-argon"* ]; then
	echo " "

	cd ./luci-theme-argon/

	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon

	cd $PKG_PATH && echo "theme-argon has been fixed!"
fi

#修改qca-nss-drv启动顺序
NSS_DRV="../feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
if [ -f "$NSS_DRV" ]; then
	echo " "

	sed -i 's/START=.*/START=85/g' $NSS_DRV

	cd $PKG_PATH && echo "qca-nss-drv has been fixed!"
fi

#修改qca-nss-pbuf启动顺序
NSS_PBUF="./kernel/mac80211/files/qca-nss-pbuf.init"
if [ -f "$NSS_PBUF" ]; then
	echo " "

	sed -i 's/START=.*/START=86/g' $NSS_PBUF

	cd $PKG_PATH && echo "qca-nss-pbuf has been fixed!"
fi

#修复TailScale配置文件冲突
TS_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
if [ -f "$TS_FILE" ]; then
	echo " "

	sed -i '/\/files/d' $TS_FILE

	cd $PKG_PATH && echo "tailscale has been fixed!"
fi

#修复Rust编译失败
RUST_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
	echo " "

	sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE

	cd $PKG_PATH && echo "rust has been fixed!"
fi

#修复DiskMan编译失败
DM_FILE="./luci-app-diskman/applications/luci-app-diskman/Makefile"
if [ -f "$DM_FILE" ]; then
	echo " "

	sed -i 's/fs-ntfs/fs-ntfs3/g' $DM_FILE
	sed -i '/ntfs-3g-utils /d' $DM_FILE

	cd $PKG_PATH && echo "diskman has been fixed!"
fi

#移除luci-app-attendedsysupgrade概览页面
ASU_FILE=$(find ../feeds/luci/applications/luci-app-attendedsysupgrade/ -type f -name "11_upgrades.js")
if [ -f "$ASU_FILE" ]; then
	echo " "

	rm -rf $ASU_FILE

	cd $PKG_PATH && echo "attendedsysupgrade has been fixed!"
fi


# =======================================================
# 修复 NSS ECM 在 Kernel 6.x 下不自动加载的问题 (优化版)
# =======================================================
echo " "
# 1. 智能定位 base-files 路径
BF_PATH=$(find . -type d -name "base-files" | head -n 1)

if [ -n "$BF_PATH" ]; then
    # 确保目录存在
    mkdir -p "$BF_PATH/files/etc/uci-defaults"
    
    # 2. 写入自动化脚本 (99-fix-nss-ecm)
    cat > "$BF_PATH/files/etc/uci-defaults/99-fix-nss-ecm" << 'EOF'
#!/bin/sh
# Auto-fix ECM autoload for Kernel 6.x/5.x
# Optimized by user request

ECM_NEW="/lib/modules/$(uname -r)/ecm.ko"
ECM_OLD="/lib/modules/$(uname -r)/qca-nss-ecm.ko"

# 1. Check for New ECM name (Kernel 6.x / Mainstream)
if [ -f "$ECM_NEW" ]; then
    # Only append if not already present
    if ! grep -qxF "ecm" /etc/modules; then
        echo "ecm" >> /etc/modules
        logger -t nss_fix "ECM detected (ecm.ko). Added to /etc/modules"
    fi
    # Load immediately to avoid reboot requirement
    modprobe ecm 2>/dev/null

# 2. Check for Old ECM name (Kernel 5.x / QSDK Legacy)
elif [ -f "$ECM_OLD" ]; then
    if ! grep -qxF "qca-nss-ecm" /etc/modules; then
        echo "qca-nss-ecm" >> /etc/modules
        logger -t nss_fix "ECM detected (qca-nss-ecm.ko). Added to /etc/modules"
    fi
    modprobe qca-nss-ecm 2>/dev/null
fi

# Exit 0 to indicate success (OpenWrt will auto-delete this script after running)
exit 0
EOF
    
    # 3. 赋予执行权限
    chmod +x "$BF_PATH/files/etc/uci-defaults/99-fix-nss-ecm"
    echo "NSS ECM autoload fix (Optimized) has been injected!"
else
    echo "WARNING: base-files directory not found, NSS fix skipped."
fi
