<div align="center">

<h1>OpenWrt — 云编译</h1>

## 特别提示

**本人不对任何人因使用本固件所遭受的任何理论或实际的损失承担责任！**

**本固件禁止用于任何商业用途，请务必严格遵守国家互联网使用相关法律规定！**

</div>

## ℹ️ 项目说明
- 默认管理地址：**`192.168.2.1`**
- 默认用户：**`root`**
- 默认密码：**`none`**
- 源码来源：[VIKINGYFY](https://github.com/VIKINGYFY/immortalwrt)
- 云编译参考：[haiibo](https://github.com/haiibo/OpenWrt) | [视频教程](https://www.youtube.com/watch?v=6j4ofS0GT38&t=507s)

---

## 🚀 京东云亚瑟 (IPQ60xx) 1GB 硬改专用 | 满血 NSS + Docker

> **⚠️ 警告：本固件专为硬改 1GB 内存的亚瑟 (JDCloud RE-SS-01) 打造，未改内存的原厂 512M 设备请勿刷入！**

本固件基于 ImmortalWrt 源码深度优化，集成 Qualcomm 闭源 NSS 驱动，彻底释放 IPQ60xx 性能潜力。
剔除冗余开发工具，专注于网络转发性能与容器化扩展能力。

### 🌟 核心亮点
- **1GB 内存解锁**：启用 `MEM_PROFILE_1024`，完整映射 1GB 物理内存，专为大内存环境优化的 WiFi 缓冲区配置。
- **NSS 满血硬解**：集成 `qca-nss-ecm` 全家桶，路由转发、桥接、PPPoE、VLAN、WiFi 数据包全部由 NPU 硬件接管。
- **零负载转发**：在跑满千兆/2.5G 网络时，CPU 占用率近乎 0%。
- **Docker 容器平台**：内置完整 Docker 引擎 (`dockerd`) 及图形化管理 (`dockerman`)。
- **无限扩展**：利用 1GB 内存优势，可稳定运行 HomeAssistant、Python 脚本、Alist 等容器。

### ⚡ 性能与加速
- **加密硬件加速**：启用 ARMv8 CE 指令集 + NSS Crypto 协处理器双重加速，HTTPS、VPN 解密性能飞跃。
- **硬件级 QoS**：采用 `sqm-scripts-nss`，利用硬件队列管理流量，彻底告别 CPU 软算 CAKE 带来的性能瓶颈。
- **ZRAM 内存优化**：启用 ZRAM Swap 与 LZ4 压缩，进一步压榨内存空间，多任务切换更流畅。

### 💾 存储与文件系统
- **全能文件系统**：原生支持 NTFS3 (内核级高性能驱动，非 Fuse)、Btrfs、XFS、exFAT、EXT4。
- **磁盘管理** (`luci-app-diskman`)：可视化的磁盘挂载与管理界面。
- **分区扩展** (`luci-app-partexp`)：刷机后一键分区扩容，轻松利用剩余空间。
- **磁盘工具**：预装 `parted` + `smartmontools`，支持专业分区与硬盘健康监控 (S.M.A.R.T)。

### 🔌 接口与扩展
- **USB 网卡/模组**：内置几十种 USB 网卡驱动，支持 RNDIS、NCM、QMI 协议。
- **兼容性**：兼容主流 4G/5G 模组及 RTL8152/AX88179 等常见 USB 网卡。
- **外设支持**：支持 USB 打印机共享 (`p910nd`)、USB 摄像头 (`uvc`)、USB 转串口 (CH341/CP210x 等)。

### 🛠️ 实用插件与工具
- **网络增强**：集成 MosDNS、HomeProxy、Passwall、OpenClash、UPnP。
- **系统管理**：Argon 主题 (带配置)、TTYD (网页终端)、CPU 频率调节、定时重启、内存释放。
- **运维工具**：curl (SSL), wget, htop, iperf3, bind-dig。
- **解压全能**：7zip, unrar, unzip, zstd (比 Busybox 自带的更强)。

---

## 🔨 定制与编译说明

1.  **Fork 项目**：首先登录 Github 账号，Fork 此项目到你自己的 Github 仓库。
2.  **修改配置**：修改 `configs` 目录对应的文件添加或删除插件，或者上传自己的 `xx.config` 配置文件。
3.  **启用插件**：不需要的软件包请把 `y` 改成 `n`，仅在前面添加 `#` 是无效的。
4.  **插件查询**：插件对应名称及功能请参考：[OpenWrt软件包全量解释](https://www.right.com.cn/FORUM/forum.php?mod=viewthread&tid=8384897)。
5.  **高级设置**：如需修改默认 IP、添加或删除插件包以及一些其他设置请在 `.sh` 文件内修改。
6.  **开始编译**：添加或修改 `xx.yml` 文件，最后点击 `Actions` 运行要编译的 `workflow` 即可开始编译。
7.  **下载固件**：编译大概需要 1-2 小时，完成后在仓库主页 [Releases](https://github.com/laipeng668/openwrt-ci-roc/releases) 对应 Tag 标签内下载。
