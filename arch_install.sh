#!/bin/bash

# Arch Linux Installation Script
# 作者：[您的名字]
# 创建日期：$(date '+%Y-%m-%d')
# 描述：自动化 Arch Linux 安装脚本

# 错误处理
set -e  # 遇到错误立即退出
set -u  # 使用未定义的变量时报错

# 清理函数
cleanup() {
    local exit_code=$?
    echo "执行清理操作..."
    # 卸载所有挂载点
    umount -R /mnt 2>/dev/null || true
    exit $exit_code
}

# 设置清理钩子
trap cleanup EXIT

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：此脚本需要 root 权限运行"
    exit 1
fi

# 检查系统环境
check_environment() {
    echo "检查系统环境..."
    
    # 检查是否在 Arch Linux 安装环境中
    if [ ! -f /etc/arch-release ]; then
        echo "错误：此脚本必须在 Arch Linux 安装环境中运行"
        exit 1
    fi
    
    # 检查是否以 UEFI 模式启动
    if [ ! -d /sys/firmware/efi/efivars ]; then
        echo "错误：系统必须以 UEFI 模式启动"
        exit 1
    fi
    
    # 检查网络连接
    if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
        echo "错误：无法连接到网络，请检查网络设置"
        exit 1
    fi
    
    # 检查必要工具
    local required_tools=("sgdisk" "mkfs.fat" "mkfs.f2fs" "arch-chroot" "pacstrap" "genfstab")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "错误：未找到必要工具 $tool"
            exit 1
        fi
    done
    
    echo "系统环境检查通过"
}

# 显示进度
show_progress() {
    local current=$1
    local total=$2
    local message=$3
    local percentage=$((current * 100 / total))
    
    printf "\r[%3d%%] %-50s" "$percentage" "$message"
    if [ "$current" -eq "$total" ]; then
        echo
    fi
}

# 检查安装结果
verify_installation() {
    echo "验证安装结果..."
    local errors=0
    
    # 检查关键文件和目录
    local check_paths=(
        "/mnt/boot/EFI/Linux/arch-linux.efi"
        "/mnt/etc/fstab"
        "/mnt/etc/hostname"
        "/mnt/etc/locale.gen"
        "/mnt/etc/locale.conf"
        "/mnt/etc/hosts"
    )
    
    for path in "${check_paths[@]}"; do
        if [ ! -e "$path" ]; then
            echo "错误：未找到文件 $path"
            ((errors++))
        fi
    done
    
    # 检查用户设置
    if ! arch-chroot /mnt id "$username" >/dev/null 2>&1; then
        echo "错误：用户 $username 创建失败"
        ((errors++))
    fi
    
    # 检查网络配置
    if [ ! -e "/mnt/etc/systemd/network" ] && [ ! -e "/mnt/etc/NetworkManager" ]; then
        echo "错误：网络配置不完整"
        ((errors++))
    fi
    
    # 检查引导配置
    if ! arch-chroot /mnt efibootmgr | grep "Arch Linux" >/dev/null; then
        echo "错误：引导配置不完整"
        ((errors++))
    fi
    
    if [ "$errors" -eq 0 ]; then
        echo "安装验证通过"
        return 0
    else
        echo "安装验证失败：发现 $errors 个错误"
        return 1
    fi
}

# 更新镜像源
update_mirrors() {
    echo "正在更新镜像源..."
    # 备份原始镜像列表
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    
    # 写入新的镜像源
    cat > /etc/pacman.d/mirrorlist << EOF
Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.xjtu.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.jlu.edu.cn/archlinux/\$repo/os/\$arch
EOF

    echo "镜像源更新完成"
}

# 列出可用磁盘并让用户选择
select_disk() {
    echo "可用磁盘列表："
    echo "----------------"
    lsblk -d -p -n -l -o NAME,SIZE,MODEL
    echo "----------------"
    
    while true; do
        read -p "请输入您想要安装的磁盘 (例如 /dev/sda): " selected_disk
        if [ -b "$selected_disk" ]; then
            echo "您选择了: $selected_disk"
            # 再次确认
            read -p "警告：这将抹除 $selected_disk 上的所有数据，确定要继续吗？(y/n) " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                break
            fi
        else
            echo "错误：无效的磁盘设备，请重新选择"
        fi
    done
    DISK=$selected_disk
}

# 创建分区
create_partitions() {
    local disk=$1
    echo "正在创建分区..."
    
    # 清除现有分区表
    sgdisk -Z "$disk"
    
    # 创建新的 GPT 分区表
    sgdisk -o "$disk"
    
    # 创建 EFI 分区 (500M)
    sgdisk -n 1:0:+500M -t 1:ef00 -c 1:"EFI System" "$disk"
    
    # 创建根分区 (使用剩余空间)
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux Root" "$disk"
    
    # 更新内核分区表
    partprobe "$disk"
    
    # 等待内核更新分区表
    sleep 2
    
    # 获取分区名称
    if [[ $disk == *"nvme"* ]]; then
        EFI_PARTITION="${disk}p1"
        ROOT_PARTITION="${disk}p2"
    else
        EFI_PARTITION="${disk}1"
        ROOT_PARTITION="${disk}2"
    fi
}

# 格式化分区
format_partitions() {
    echo "正在格式化分区..."
    
    # 格式化 EFI 分区为 FAT32
    if ! mkfs.fat -F32 "$EFI_PARTITION"; then
        echo "错误：EFI 分区格式化失败"
        exit 1
    fi
    
    # 格式化根分区为 f2fs，带有指定的选项
    if ! mkfs.f2fs -f -l 'Arch Linux' -O extra_attr,inode_checksum,sb_checksum,compression "$ROOT_PARTITION"; then
        echo "错误：根分区格式化失败"
        exit 1
    fi
    
    echo "分区格式化完成"
}

# 添加数据盘
add_data_disk() {
    while true; do
        read -p "是否需要添加数据盘？(y/n) " need_data_disk
        if [ "$need_data_disk" = "n" ] || [ "$need_data_disk" = "N" ]; then
            echo "跳过数据盘设置"
            return
        elif [ "$need_data_disk" = "y" ] || [ "$need_data_disk" = "Y" ]; then
            break
        fi
        echo "请输入 y 或 n"
    done

    echo "请选择数据盘（注意：不要选择刚才用于系统安装的磁盘 $DISK）"
    echo "可用磁盘列表："
    echo "----------------"
    lsblk -d -p -n -l -o NAME,SIZE,MODEL
    echo "----------------"
    
    while true; do
        read -p "请输入要用作数据盘的设备 (例如 /dev/sdb): " data_disk
        if [ "$data_disk" = "$DISK" ]; then
            echo "错误：不能选择系统盘作为数据盘，请重新选择"
            continue
        fi
        if [ -b "$data_disk" ]; then
            echo "您选择了: $data_disk 作为数据盘"
            read -p "警告：这将格式化整个磁盘 $data_disk 为 XFS 格式，所有数据将丢失。确定要继续吗？(y/n) " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                # 创建新的 GPT 分区表
                sgdisk -Z "$data_disk"
                sgdisk -o "$data_disk"
                
                # 创建单个分区使用整个磁盘
                sgdisk -n 1:0:0 -t 1:8300 -c 1:"Linux Data" "$data_disk"
                
                # 等待内核更新分区表
                sleep 2
                
                # 确定分区名称
                if [[ $data_disk == *"nvme"* ]]; then
                    DATA_PARTITION="${data_disk}p1"
                else
                    DATA_PARTITION="${data_disk}1"
                fi
                
                # 格式化为 XFS
                echo "正在将数据盘格式化为 XFS 文件系统..."
                mkfs.xfs -f -L "Data" "$DATA_PARTITION"
                echo "数据盘格式化完成"
                break
            fi
        else
            echo "错误：无效的磁盘设备，请重新选择"
        fi
    done
}

# 处理挂载点
setup_mountpoints() {
    echo "开始设置挂载点..."
    
    # 挂载根分区
    mount -o compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime "${ROOT_PARTITION}" /mnt || die "无法挂载根分区"
    
    # 创建并挂载 EFI 分区
    mkdir -p /mnt/boot || die "无法创建 /mnt/boot 目录"
    mount "${EFI_PARTITION}" /mnt/boot || die "无法挂载 EFI 分区"
    
    # 创建必要的目录
    mkdir -p /mnt/boot/EFI/Linux || die "无法创建 EFI 目录"
    mkdir -p /mnt/var || die "无法创建 var 目录"
    
    # 如果设置了数据盘，进行额外的挂载
    if [ -n "${DATA_PARTITION:-}" ]; then
        echo "检测到数据盘，进行额外挂载..."
        
        # 创建数据盘挂载点
        mkdir -p /mnt/mnt || die "无法创建数据盘挂载点"
        
        # 挂载数据盘
        mount "${DATA_PARTITION}" /mnt/mnt || die "无法挂载数据盘"
        
        # 创建数据盘上的 var 目录
        mkdir -p /mnt/mnt/var || die "无法在数据盘上创建 var 目录"
        
        # 绑定挂载 var 目录
        mount --bind /mnt/mnt/var /mnt/var || die "无法绑定挂载 var 目录"
        
        echo "数据盘挂载和目录绑定完成"
    fi
    
    echo "挂载点设置完成"
    
    # 显示当前挂载情况
    echo "当前挂载情况："
    echo "----------------"
    mount | grep "/mnt"
    echo "----------------"
}

# 安装基本系统
install_base_system() {
    echo "开始安装基本系统..."
    echo "这可能需要一些时间，取决于您的网络速度..."
    
    # 安装基本包
    if ! pacstrap /mnt base base-devel linux linux-firmware neovim f2fs-tools; then
        echo "错误：基本系统安装失败"
        exit 1
    fi
    
    # 配置 mkinitcpio
    echo "配置 mkinitcpio..."
    sed -i 's/MODULES=()/MODULES=(f2fs)/' /mnt/etc/mkinitcpio.conf
    arch-chroot /mnt mkinitcpio -P
    
    echo "基本系统安装完成"
}

# 配置网络
setup_network() {
    echo "配置网络..."
    
    # 让用户选择网络管理工具
    while true; do
        echo "请选择网络管理工具："
        echo "1) NetworkManager (需要内网认证选这个)"
        echo "2) systemd-networkd (这个性能好)"
        read -p "请输入选择 (1 或 2): " network_choice
        
        case $network_choice in
            1)
                echo "安装 NetworkManager..."
                if ! arch-chroot /mnt pacman -S --noconfirm networkmanager; then
                    echo "错误：NetworkManager 安装失败"
                    exit 1
                fi
                arch-chroot /mnt systemctl enable NetworkManager
                
                # 配置 DNS
                arch-chroot /mnt ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                echo "NetworkManager 已安装并启用"
                break
                ;;
            2)
                echo "启用 systemd-networkd 和 systemd-resolved..."
                arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved
                
                # 配置 DNS
                arch-chroot /mnt ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                
                # 询问是否需要无线网络支持
                read -p "是否需要无线网络支持？(y/n) " wireless_support
                if [ "$wireless_support" = "y" ] || [ "$wireless_support" = "Y" ]; then
                    echo "安装 iwd..."
                    if ! arch-chroot /mnt pacman -S --noconfirm iwd; then
                        echo "错误：iwd 安装失败"
                        exit 1
                    fi
                    arch-chroot /mnt systemctl enable iwd
                fi
                
                # 列出可用网卡
                echo "可用网卡列表："
                echo "----------------"
                ip link | grep -E '^[0-9]+: ' | cut -d: -f2 | sed 's/ //g'
                echo "----------------"
                
                # 让用户选择网卡
                while true; do
                    read -p "请输入要使用的网卡名称: " interface_name
                    if ip link show "$interface_name" >/dev/null 2>&1; then
                        break
                    else
                        echo "错误：无效的网卡名称，请重新输入"
                    fi
                done
                
                # 判断是否为无线网卡
                if [[ "$interface_name" == wl* ]]; then
                    config_file="/mnt/etc/systemd/network/10-wireless.network"
                else
                    config_file="/mnt/etc/systemd/network/10-wired.network"
                fi
                
                # 创建网络配置文件
                mkdir -p /mnt/etc/systemd/network
                cat > "$config_file" << EOF
[Match]
Name=$interface_name

[Network]
DHCP=yes
DNS=223.5.5.5
DNS=119.29.29.29
EOF
                echo "网络配置文件已创建：$config_file"
                break
                ;;
            *)
                echo "无效的选择，请输入 1 或 2"
                ;;
        esac
    done
    
    echo "网络配置完成"
}

# 配置本地化设置
setup_localization() {
    echo "配置系统本地化..."
    
    # 设置时区
    echo "设置时区..."
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    arch-chroot /mnt hwclock --systohc
    
    # 修改 locale.gen
    echo "配置 locale.gen..."
    if ! sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen || \
       ! sed -i 's/#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /mnt/etc/locale.gen; then
        echo "错误：locale.gen 配置失败"
        exit 1
    fi
    
    # 生成 locale 信息
    echo "生成 locale 信息..."
    if ! arch-chroot /mnt locale-gen; then
        echo "错误：locale 生成失败"
        exit 1
    fi
    
    # 创建 locale.conf
    echo "创建 locale.conf..."
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
    
    # 配置控制台字体
    echo "配置控制台字体..."
    if ! arch-chroot /mnt pacman -S --noconfirm terminus-font; then
        echo "错误：terminus-font 安装失败"
        exit 1
    fi
    
    # 创建 vconsole.conf
    echo "创建 vconsole.conf..."
    cat > /mnt/etc/vconsole.conf << EOF
FONT=ter-u16n
FONT_MAP=8859-2
EOF
    
    echo "本地化配置完成"
}

# 配置主机名和hosts
setup_hostname() {
    echo "配置主机名..."
    
    # 让用户输入主机名
    read -p "请输入主机名（默认为 'Arch'）: " hostname
    hostname=${hostname:-Arch}
    
    # 创建 hostname 文件
    echo "设置主机名为: $hostname"
    echo "$hostname" > /mnt/etc/hostname
    
    # 配置 hosts 文件
    echo "配置 hosts 文件..."
    cat > /mnt/etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain
EOF
    
    echo "主机名配置完成"
}

# 安装和配置 UKI (Unified Kernel Image)
setup_uki() {
    echo "配置 UKI..."
    
    # 确保目录存在
    arch-chroot /mnt mkdir -p /boot/EFI/Linux || die "无法创建 UKI 目录"
    
    # 创建 kernel cmdline
    echo "root=PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_PARTITION}) rw rootflags=compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime loglevel=3 quiet" > /mnt/etc/kernel/cmdline || die "无法创建 kernel cmdline"
    
    # 创建 mkinitcpio preset
    cat > /mnt/etc/mkinitcpio.d/linux.preset << EOF || die "无法创建 mkinitcpio preset"
# mkinitcpio preset file for the 'linux' package

#ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default')

#default_config="/etc/mkinitcpio.conf"
#default_image="/boot/initramfs-linux.img"
default_uki="/boot/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
EOF
    
    # 生成 UKI
    arch-chroot /mnt mkinitcpio -P || die "无法生成 UKI"
    
    # 添加 EFI 启动项
    arch-chroot /mnt efibootmgr --create --disk "${DISK}" --part "${EFI_PART_NUM}" \
        --label "Arch Linux" --loader "\\EFI\\Linux\\arch-linux.efi" \
        --unicode || die "无法创建 EFI 启动项"
    
    echo "UKI 配置完成"
}

# 配置 systemd-boot
setup_systemd_boot() {
    echo "配置 systemd-boot..."
    
    # 安装 systemd-boot
    arch-chroot /mnt bootctl install || die "无法安装 systemd-boot"
    
    # 创建启动项配置
    mkdir -p /mnt/boot/loader/entries
    
    # 创建 loader.conf
    cat > /mnt/boot/loader/loader.conf << EOF
default  arch.conf
timeout  4
console-mode max
editor   no
EOF
    
    # 创建 arch.conf
    cat > /mnt/boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_PARTITION}) rw rootflags=compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime loglevel=3 quiet
EOF
    
    echo "systemd-boot 配置完成"
}

# 配置 GRUB
setup_grub() {
    echo "配置 GRUB..."
    
    # 安装必要的包
    arch-chroot /mnt pacman -S --noconfirm grub efibootmgr || die "无法安装 GRUB"
    
    # 安装 GRUB
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || die "无法安装 GRUB"
    
    # 配置 GRUB 默认设置
    sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=2/' /mnt/etc/default/grub
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"/' /mnt/etc/default/grub
    
    # 添加 root 分区参数和 f2fs 参数
    local root_options="root=PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_PARTITION}) rw rootflags=compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime"
    
    sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"$root_options\"|" /mnt/etc/default/grub
    
    # 生成 GRUB 配置
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || die "无法生成 GRUB 配置"
    
    echo "GRUB 配置完成"
}

# 配置引导程序
setup_bootloader() {
    echo "配置引导程序..."
    
    while true; do
        echo "请选择引导程序："
        echo "1) UKI (Unified Kernel Image) [默认]"
        echo "2) systemd-boot"
        echo "3) GRUB"
        read -p "请输入选择 (默认为 1): " bootloader_choice
        
        case ${bootloader_choice:-1} in
            1)
                setup_uki
                break
                ;;
            2)
                setup_systemd_boot
                break
                ;;
            3)
                setup_grub "$DISK"
                break
                ;;
            *)
                echo "无效的选择，请重新输入"
                ;;
        esac
    done
}

# 安装CPU微码
install_microcode() {
    echo "安装CPU微码..."
    
    while true; do
        echo "请选择您的CPU类型："
        echo "1) Intel"
        echo "2) AMD"
        read -p "请输入选择 (1 或 2): " cpu_choice
        
        case $cpu_choice in
            1)
                echo "安装 Intel CPU 微码..."
                arch-chroot /mnt pacman -S --noconfirm intel-ucode
                break
                ;;
            2)
                echo "安装 AMD CPU 微码..."
                arch-chroot /mnt pacman -S --noconfirm amd-ucode
                break
                ;;
            *)
                echo "无效的选择，请输入 1 或 2"
                ;;
        esac
    done
    
    echo "CPU微码安装完成"
}

# 安装和配置NVIDIA驱动
setup_nvidia() {
    echo "是否安装NVIDIA驱动？"
    echo "1) 不安装（默认）"
    echo "2) nvidia-open (开源驱动)"
    echo "3) nvidia (闭源驱动)"
    read -p "请选择 [1-3] (默认: 1): " nvidia_choice
    
    case "${nvidia_choice:-1}" in
        2)
            echo "安装 nvidia-open 驱动..."
            arch-chroot /mnt pacman -S --noconfirm nvidia-open nvidia-utils nvidia-settings
            ;;
        3)
            echo "安装 nvidia 驱动..."
            arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
            ;;
        *)
            echo "跳过NVIDIA驱动安装"
            return
            ;;
    esac
    
    # 配置 mkinitcpio.conf
    echo "配置 mkinitcpio.conf..."
    sed -i 's/^MODULES=.*/MODULES=(f2fs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /mnt/etc/mkinitcpio.conf
    
    # 更新内核启动参数
    local kernel_params="ibt=off nvidia_drm.modeset=1"
    
    case "$BOOTLOADER" in
        "systemd-boot")
            # 更新 systemd-boot 配置
            sed -i "/^options/ s|$| ${kernel_params}|" /mnt/boot/loader/entries/arch.conf
            ;;
        "grub")
            # 更新 GRUB 配置
            sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${kernel_params} |" /mnt/etc/default/grub
            arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
            ;;
        "uki")
            # 更新 UKI 配置
            mkdir -p /mnt/etc/cmdline.d
            echo "${kernel_params}" > /mnt/etc/cmdline.d/nvidia.conf
            ;;
    esac
    
    # 重新生成 initramfs
    arch-chroot /mnt mkinitcpio -P
    
    echo "NVIDIA驱动安装和配置完成"
}

# 配置archlinuxcn源
setup_archlinuxcn() {
    echo "配置archlinuxcn源..."
    
    # 添加archlinuxcn源
    cat >> /mnt/etc/pacman.conf << EOF

[archlinuxcn]
SigLevel = Optional TrustAll
Server = https://mirrors.bfsu.edu.cn/archlinuxcn/\$arch
EOF
    
    # 安装archlinuxcn-keyring和yay
    arch-chroot /mnt pacman -Sy --noconfirm archlinuxcn-keyring
    arch-chroot /mnt pacman -S --noconfirm yay
    
    echo "archlinuxcn源配置完成"
}

# 设置用户和密码
setup_users() {
    echo "设置用户和密码..."
    
    # 安装必要的包
    echo "安装用户管理相关包..."
    if ! arch-chroot /mnt pacman -S --noconfirm sudo zsh; then
        echo "错误：用户管理包安装失败"
        exit 1
    fi
    
    # 提示用户输入新用户名
    while true; do
        read -p "请输入新用户名: " username
        if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            # 检查用户名是否已存在
            if ! arch-chroot /mnt id "$username" >/dev/null 2>&1; then
                break
            else
                echo "错误：用户名已存在"
            fi
        else
            echo "错误：用户名只能包含小写字母、数字、下划线和连字符，且必须以字母或下划线开头"
        fi
    done
    
    # 创建新用户
    echo "创建用户 $username..."
    if ! arch-chroot /mnt useradd -m -G wheel,audio,video,storage,optical,network -s /bin/zsh "$username"; then
        echo "错误：用户创建失败"
        exit 1
    fi
    
    # 配置 sudo
    echo "配置 sudo 权限..."
    if ! arch-chroot /mnt sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers; then
        echo "错误：sudo 配置失败"
        exit 1
    fi
    
    # 设置 root 密码
    echo "设置 root 密码..."
    while true; do
        echo "请输入 root 密码（至少8个字符，包含大小写字母和数字）："
        if arch-chroot /mnt passwd; then
            break
        fi
        echo "密码设置失败，请重试"
    done
    
    # 设置新用户密码
    echo "设置 $username 的密码..."
    while true; do
        echo "请输入 $username 的密码（至少8个字符，包含大小写字母和数字）："
        if arch-chroot /mnt passwd "$username"; then
            break
        fi
        echo "密码设置失败，请重试"
    done
    
    # 安装和配置 Oh My Zsh
    echo "配置 Oh My Zsh..."
    arch-chroot /mnt sudo -u "$username" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    
    # 设置用户目录绑定挂载
    setup_user_dirs "$username"
    
    echo "用户设置完成"
}

# 设置用户目录绑定挂载
setup_user_dirs() {
    # 检查是否设置了数据盘
    if [ -z "$DATA_PARTITION" ]; then
        return
    fi
    
    local username="$1"
    echo "设置用户目录绑定挂载..."
    
    # 默认要绑定的目录
    local default_dirs=(".cache" "Downloads" "Documents" "Pictures")
    
    # 在数据盘上创建用户目录
    if ! mkdir -p "/mnt/mnt/$username"; then
        echo "错误：创建数据盘用户目录失败"
        exit 1
    fi
    
    # 询问用户是否需要添加其他目录
    read -p "是否需要添加其他要绑定的目录？默认目录已包含 ${default_dirs[*]}（用空格分隔多个目录，直接回车跳过）: " additional_dirs
    
    # 将用户输入的目录添加到数组中
    if [ -n "$additional_dirs" ]; then
        for dir in $additional_dirs; do
            default_dirs+=("$dir")
        done
    fi
    
    # 创建目录并设置绑定挂载
    for dir in "${default_dirs[@]}"; do
        echo "处理目录: $dir"
        
        # 在数据盘上创建目录
        if ! mkdir -p "/mnt/mnt/$username/$dir"; then
            echo "错误：创建数据盘目录 $dir 失败"
            continue
        fi
        
        # 在用户主目录创建目录
        if ! mkdir -p "/mnt/home/$username/$dir"; then
            echo "错误：创建主目录 $dir 失败"
            continue
        fi
        
        # 设置目录权限
        chown -R "$username:$username" "/mnt/mnt/$username/$dir"
        chown -R "$username:$username" "/mnt/home/$username/$dir"
        chmod 700 "/mnt/mnt/$username/$dir"
        chmod 700 "/mnt/home/$username/$dir"
        
        # 添加到 fstab
        echo "/mnt/$username/$dir /home/$username/$dir none bind 0 0" >> /mnt/etc/fstab
    done
    
    # 设置数据盘用户目录的权限
    chown -R "$username:$username" "/mnt/mnt/$username"
    chmod 700 "/mnt/mnt/$username"
    
    echo "用户目录绑定挂载设置完成"
}

# 生成 fstab
generate_fstab() {
    echo "生成 fstab..."
    if ! genfstab -U /mnt >> /mnt/etc/fstab; then
        echo "错误：fstab 生成失败"
        exit 1
    fi
    echo "fstab 生成完成"
}

# 显示最终提示信息
show_final_message() {
    echo
    echo "=================================================="
    echo "            Arch Linux 安装完成！"
    echo "=================================================="
    echo
    echo "系统配置信息："
    echo "1. 用户名：$username"
    echo "2. Shell：zsh (已安装 Oh My Zsh)"
    echo "3. 文件系统：f2fs (已启用压缩和优化)"
    echo "4. 引导：UKI (已配置主引导)"
    echo
    echo "首次启动后的建议操作："
    echo "1. 更新系统："
    echo "   sudo pacman -Syu"
    echo
    echo "2. 安装常用软件包："
    echo "   sudo pacman -S git firefox"
    echo
    echo "3. 配置 AUR 助手："
    echo "   git clone https://aur.archlinux.org/yay.git"
    echo "   cd yay && makepkg -si"
    echo
    echo "4. 安装中文输入法："
    echo "   sudo pacman -S fcitx5 fcitx5-chinese-addons fcitx5-gtk fcitx5-qt"
    echo
    echo "5. 启用 SSD TRIM："
    echo "   sudo systemctl enable fstrim.timer"
    echo
    echo "常见问题解决方案："
    echo "1. 如果无法联网，请检查："
    echo "   - NetworkManager 状态：systemctl status NetworkManager"
    echo "   - 网络接口状态：ip link"
    echo
    echo "2. 如果显示中文方块，请安装字体："
    echo "   sudo pacman -S noto-fonts noto-fonts-cjk"
    echo
    echo "3. 如果系统时间不准，请同步时间："
    echo "   sudo timedatectl set-ntp true"
    echo
    echo "4. NVIDIA显卡相关："
    echo "   - 检查驱动状态：nvidia-smi"
    echo "   - 配置显示设置：nvidia-settings"
    echo "   - 如果遇到问题，检查：dmesg | grep -i nvidia"
    echo
    echo "系统优化建议："
    echo "1. 开启 ZRAM："
    echo "   yay -S zramd && sudo systemctl enable --now zramd"
    echo
    echo "2. 优化 I/O 调度器："
    echo "   echo 'none' | sudo tee /sys/block/nvme0n1/queue/scheduler"
    echo
    echo "3. 减少系统日志大小："
    echo "   sudo journalctl --vacuum-size=100M"
    echo
    echo "现在您可以重启系统了："
    echo "1. 退出 chroot 环境（如果在其中）：exit"
    echo "2. 卸载所有分区：umount -R /mnt"
    echo "3. 重启系统：reboot"
    echo
    echo "祝您使用愉快！"
    echo "=================================================="
}

# 开始安装过程
main() {
    local total_steps=14
    local current_step=0
    
    echo "开始 Arch Linux 安装..."
    
    # 检查系统环境
    show_progress $((++current_step)) "$total_steps" "检查系统环境"
    check_environment
    
    # 更新镜像源
    show_progress $((++current_step)) "$total_steps" "更新镜像源"
    update_mirrors
    
    # 执行磁盘操作
    show_progress $((++current_step)) "$total_steps" "准备磁盘"
    select_disk
    create_partitions "$DISK"
    format_partitions
    
    # 处理数据盘
    show_progress $((++current_step)) "$total_steps" "配置数据盘"
    add_data_disk
    
    # 设置挂载点
    show_progress $((++current_step)) "$total_steps" "设置挂载点"
    setup_mountpoints
    
    # 安装基本系统
    show_progress $((++current_step)) "$total_steps" "安装基本系统"
    install_base_system
    
    # 配置网络
    show_progress $((++current_step)) "$total_steps" "配置网络"
    setup_network
    
    # 配置本地化
    show_progress $((++current_step)) "$total_steps" "配置本地化"
    setup_localization
    
    # 配置主机名
    show_progress $((++current_step)) "$total_steps" "配置主机名"
    setup_hostname
    
    # 安装微码和配置引导
    show_progress $((++current_step)) "$total_steps" "配置引导程序"
    install_microcode
    setup_bootloader
    
    # 安装NVIDIA驱动
    show_progress $((++current_step)) "$total_steps" "安装NVIDIA驱动"
    setup_nvidia
    
    # 配置archlinuxcn源
    show_progress $((++current_step)) "$total_steps" "配置archlinuxcn源"
    setup_archlinuxcn
    
    # 设置用户
    show_progress $((++current_step)) "$total_steps" "设置用户"
    setup_users
    
    # 生成 fstab 和最终检查
    show_progress $((++current_step)) "$total_steps" "完成安装"
    generate_fstab
    
    # 验证安装
    if ! verify_installation; then
        echo "警告：安装验证失败，但可能仍然可用"
        echo "建议在重启前仔细检查系统配置"
        read -p "是否继续？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # 显示最终信息
    show_final_message
}

# 运行主函数
main
