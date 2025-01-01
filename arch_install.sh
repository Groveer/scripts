#!/bin/bash

# Arch Linux Installation Script
# 作者：Groveer
# 创建日期：2024-11-18
# 描述：自动化 Arch Linux 安装脚本
# 脚本权限要求：root

# 错误处理
set -e  # 遇到错误立即退出
set -u  # 使用未定义的变量时报错

# 清理函数
cleanup() {
    local exit_code=$?
    echo "cleanup..."
    # 卸载所有挂载点
    umount -R /mnt 2>/dev/null || true
    exit $exit_code
}

# 设置清理钩子
trap cleanup EXIT

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "error：must be run as root"
    exit 1
fi

# 检查系统环境
check_environment() {
    echo "check environment..."

    # 检查是否在 Arch Linux 安装环境中
    if [ ! -f /etc/arch-release ]; then
        echo "error: this script is only for Arch Linux"
        exit 1
    fi

    # 检查是否以 UEFI 模式启动
    if [ ! -d /sys/firmware/efi/efivars ]; then
        echo "error: this script only supports UEFI boot mode"
        exit 1
    fi

    # 检查网络连接
    if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
        echo "error: no internet connection"
        exit 1
    fi

    # 检查必要工具
    local required_tools=("sgdisk" "mkfs.fat" "mkfs.f2fs" "arch-chroot" "pacstrap" "genfstab")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "errot: not found tool: $tool"
            exit 1
        fi
    done

    echo "environment check passed"
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
    echo "verify installation..."
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
            echo "error: missing file or directory: $path"
            ((errors++))
        fi
    done

    # 检查用户设置
    if ! arch-chroot /mnt id "$username" >/dev/null 2>&1; then
        echo "error: user not created: $username"
        ((errors++))
    fi

    # 检查网络配置
    if [ ! -e "/mnt/etc/systemd/network" ] && [ ! -e "/mnt/etc/NetworkManager" ]; then
        echo "error: network configuration not found"
        ((errors++))
    fi

    # 检查引导配置
    if ! arch-chroot /mnt efibootmgr | grep "Arch Linux" >/dev/null; then
        echo "error: boot entry not found"
        ((errors++))
    fi

    if [ "$errors" -eq 0 ]; then
        echo "installation verified: no errors found"
        return 0
    else
        echo "installation verification failed: $errors errors found"
        return 1
    fi
}

# 更新镜像源
update_mirrors() {
    echo "update mirrors..."
    # 备份原始镜像列表
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

    # 写入新的镜像源
    cat > /etc/pacman.d/mirrorlist << EOF
Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.xjtu.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.jlu.edu.cn/archlinux/\$repo/os/\$arch
EOF

    echo "mirrors updated"
}

# 列出可用磁盘并让用户选择
select_disk() {
    echo "choose disk..."
    echo "----------------"
    lsblk -d -p -n -l -o NAME,SIZE,MODEL
    echo "----------------"

    while true; do
        read -p "please input the disk you want to install (e.g. /dev/sda): " selected_disk
        if [ -b "$selected_disk" ]; then
            echo "you choosed $selected_disk"
            # 再次确认
            read -p "warning: this will erase all data on $selected_disk, are you sure to continue? (y/n) " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                break
            fi
        else
            echo "error: invalid disk device, please choose again"
        fi
    done
    DISK=$selected_disk
}

# 创建分区
create_partitions() {
    local disk=$1
    echo "create partitions..."

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
    echo "format partitions..."

    # 格式化 EFI 分区为 FAT32
    if ! mkfs.fat -F32 "$EFI_PARTITION"; then
        echo "error: format EFI partition failed"
        exit 1
    fi

    # 格式化根分区为 f2fs，带有指定的选项
    if ! mkfs.f2fs -f -l 'Arch Linux' -O extra_attr,inode_checksum,sb_checksum,compression "$ROOT_PARTITION"; then
        echo "error: format root partition failed"
        exit 1
    fi

    echo "partitions formatted"
}

# 添加数据盘
add_data_disk() {
    while true; do
        read -p "do you want to add a data disk? (y/n) " need_data_disk
        if [ "$need_data_disk" = "n" ] || [ "$need_data_disk" = "N" ]; then
            echo "skip adding data disk"
            return
        elif [ "$need_data_disk" = "y" ] || [ "$need_data_disk" = "Y" ]; then
            break
        fi
        echo "error: invalid input, please input y/n"
    done

    echo "please choose a disk for data (don't choose the disk $DISK used for system installation)"
    echo "available disks:"
    echo "----------------"
    lsblk -d -p -n -l -o NAME,SIZE,MODEL
    echo "----------------"

    while true; do
        read -p "please input the disk you want to use as data disk (e.g. /dev/sdb): " data_disk
        if [ "$data_disk" = "$DISK" ]; then
            echo "error: invalid disk, please choose another disk"
            continue
        fi
        if [ -b "$data_disk" ]; then
            echo "you choosed $data_disk"
            read -p "warning: this will erase all data on $data_disk, are you sure to continue? (y/n) " confirm
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
                echo "format data disk..."
                mkfs.xfs -f -L "Data" "$DATA_PARTITION"
                echo "data disk formatted"
                break
            fi
        else
            echo "error: invalid disk device, please choose again"
        fi
    done
}

# 处理挂载点
setup_mountpoints() {
    echo "setup mountpoints..."

    # 挂载根分区
    mount -o compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime "${ROOT_PARTITION}" /mnt || die "cannot mount root partition"

    # 创建并挂载 EFI 分区
    mkdir -p /mnt/boot || die "cannot create boot directory"
    mount "${EFI_PARTITION}" /mnt/boot || die "cannot mount EFI partition"

    # 创建必要的目录
    mkdir -p /mnt/boot/EFI/Linux || die "cannot create Linux directory"
    mkdir -p /mnt/var || die "cannot create var directory"

    # 如果设置了数据盘，进行额外的挂载
    if [ -n "${DATA_PARTITION:-}" ]; then
        echo "add data disk..."

        # 创建数据盘挂载点
        mkdir -p /mnt/mnt || die "cannot create data disk mountpoint"

        # 挂载数据盘
        mount "${DATA_PARTITION}" /mnt/mnt || die "cannot mount data disk"

        # 创建数据盘上的 var 目录
        mkdir -p /mnt/mnt/var || die "cannot create var directory on data disk"

        # 绑定挂载 var 目录
        mount --bind /mnt/mnt/var /mnt/var || die "cannot bind mount var directory"

        echo "data disk mounted"
    fi

    echo "mountpoints setup completed"

    # 显示当前挂载情况
    echo "current mountpoints:"
    echo "----------------"
    mount | grep "/mnt"
    echo "----------------"
}

# 安装基本系统
install_base_system() {
    echo "install base system..."

    # 安装基本包
    if ! pacstrap /mnt base base-devel linux linux-firmware neovim f2fs-tools; then
        echo "error: base system installation failed"
        exit 1
    fi

    # 配置 mkinitcpio
    echo "config mkinitcpio..."
    sed -i 's/MODULES=()/MODULES=(f2fs)/' /mnt/etc/mkinitcpio.conf
    arch-chroot /mnt mkinitcpio -P

    echo "base system installed"
}

# 配置网络
setup_network() {
    echo "setup network..."

    # 让用户选择网络管理工具
    while true; do
        echo "choose network manager:"
        echo "1) NetworkManager (recommended)"
        echo "2) systemd-networkd and systemd-resolved"
        read -p "please choose network manager (1 or 2): " network_choice

        case $network_choice in
            1)
                echo "install NetworkManager..."
                if ! arch-chroot /mnt pacman -S --noconfirm networkmanager; then
                    echo "error: NetworkManager installation failed"
                    exit 1
                fi
                arch-chroot /mnt systemctl enable NetworkManager

                echo "NetworkManager installed"
                break
                ;;
            2)
                echo "enable systemd-networkd and systemd-resolved..."
                arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved

                # 配置 DNS
                rm -f /mnt/etc/resolv.conf
                arch-chroot /mnt ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

                # 询问是否需要无线网络支持
                read -p "need wireless support? (y/n) " wireless_support
                if [ "$wireless_support" = "y" ] || [ "$wireless_support" = "Y" ]; then
                    echo "install iwd..."
                    if ! arch-chroot /mnt pacman -S --noconfirm iwd; then
                        echo "error: iwd installation failed"
                        exit 1
                    fi
                    arch-chroot /mnt systemctl enable iwd
                fi

                # 列出可用网卡
                echo "available network interfaces:"
                echo "----------------"
                ip link | grep -E '^[0-9]+: ' | cut -d: -f2 | sed 's/ //g'
                echo "----------------"

                # 让用户选择网卡
                while true; do
                    read -p "please input the network interface name: " interface_name
                    if ip link show "$interface_name" >/dev/null 2>&1; then
                        break
                    else
                        echo "error: invalid network interface, please choose again"
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
                echo "create network configuration file: $config_file"
                break
                ;;
            *)
                echo "error: invalid choice, please choose again"
                ;;
        esac
    done

    echo "network setup completed"
}

# 配置本地化设置
setup_localization() {
    echo "setup localization..."

    # 设置时区
    echo "configure timezone..."
    rm -f /mnt/etc/localtime
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    arch-chroot /mnt hwclock --systohc

    # 修改 locale.gen
    echo "configure locale.gen..."
    if ! sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen || \
       ! sed -i 's/#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /mnt/etc/locale.gen; then
        echo "error: configure locale.gen failed"
        exit 1
    fi

    # 生成 locale 信息
    echo "generate locale..."
    if ! arch-chroot /mnt locale-gen; then
        echo "error: generate locale failed"
        exit 1
    fi

    # 创建 locale.conf
    echo "create locale.conf..."
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

    # 配置控制台字体
    echo "configure console font..."
    if ! arch-chroot /mnt pacman -S --noconfirm terminus-font; then
        echo "error: install terminus-font failed"
        exit 1
    fi

    # 创建 vconsole.conf
    echo "创建 vconsole.conf..."
    cat > /mnt/etc/vconsole.conf << EOF
FONT=ter-u16n
FONT_MAP=8859-2
EOF

    echo "localization setup completed"
}

# 配置主机名和hosts
setup_hostname() {
    echo "setup hostname and hosts..."

    # 让用户输入主机名
    read -p "please input hostname (default is 'Arch'): " hostname
    hostname=${hostname:-Arch}

    # 创建 hostname 文件
    echo "set hostname to: $hostname"
    echo "$hostname" > /mnt/etc/hostname

    # 配置 hosts 文件
    echo "configure hosts file..."
    cat > /mnt/etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain
EOF

    echo "hostname and hosts setup completed"
}

# 安装和配置 UKI (Unified Kernel Image)
setup_uki() {
    echo "setup UKI..."

    # 确保目录存在
    arch-chroot /mnt mkdir -p /boot/EFI/Linux || die "cannot create UKI directory"

    # 创建 kernel cmdline
    echo "root=PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_PARTITION}) rw rootflags=compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime loglevel=3 quiet" > /mnt/etc/kernel/cmdline || die "cannot create kernel cmdline"

    # 创建 mkinitcpio preset
    cat > /mnt/etc/mkinitcpio.d/linux.preset << EOF || die "cannot create mkinitcpio preset"
# mkinitcpio preset file for the 'linux' package

#ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default')

#default_config="/etc/mkinitcpio.conf"
#default_image="/boot/initramfs-linux.img"
default_uki="/boot/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
EOF

    # 生成 UKI
    arch-chroot /mnt mkinitcpio -P || die "cannot generate UKI"

    # 添加 EFI 启动项
    efibootmgr --create --disk "${DISK}" --part 1 \
        --label "Arch Linux" --loader "\\EFI\\Linux\\arch-linux.efi" \
        --unicode || die "cannot create UKI boot entry"

    rm /mnt/boot/*.img

    echo "UKI setup completed"
}

# 配置 systemd-boot
setup_systemd_boot() {
    echo "setup systemd-boot..."

    # 安装 systemd-boot
    arch-chroot /mnt bootctl install || die "cannot install systemd-boot"

    # 创建启动项配置
    mkdir -p /mnt/boot/loader/entries

    # 创建 loader.conf
    cat > /mnt/boot/loader/loader.conf << EOF
default  arch.conf
timeout  3
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

    echo "systemd-boot setup completed"
}

# 配置 GRUB
setup_grub() {
    echo "setup GRUB..."

    # 安装必要的包
    arch-chroot /mnt pacman -S --noconfirm grub efibootmgr || die "cannot install GRUB"

    # 安装 GRUB
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || die "cannot grub-install"

    # 配置 GRUB 默认设置
    sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=2/' /mnt/etc/default/grub
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"/' /mnt/etc/default/grub

    # 添加 root 分区参数和 f2fs 参数
    local root_options="root=PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_PARTITION}) rw rootflags=compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime"

    sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"$root_options\"|" /mnt/etc/default/grub

    # 生成 GRUB 配置
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || die "cannot generate GRUB config"

    echo "GRUB setup completed"
}

# 配置引导程序
setup_bootloader() {
    echo "setup bootloader..."

    while true; do
        echo "please choose a bootloader:"
        echo "1) UKI (Unified Kernel Image) (default)"
        echo "2) systemd-boot"
        echo "3) GRUB"
        read -p "please choose a bootloader (1-3): " bootloader_choice

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
                echo "error: invalid choice, please choose again"
                ;;
        esac
    done
}

# 安装CPU微码
install_microcode() {
    echo "install microcode..."

    while true; do
        echo "please choose your CPU manufacturer:"
        echo "1) Intel"
        echo "2) AMD"
        read -p "please choose your CPU manufacturer (1 or 2): " cpu_choice

        case $cpu_choice in
            1)
                echo "install Intel CPU microcode..."
                arch-chroot /mnt pacman -S --noconfirm intel-ucode
                break
                ;;
            2)
                echo "install AMD CPU microcode..."
                arch-chroot /mnt pacman -S --noconfirm amd-ucode
                break
                ;;
            *)
                echo "error: invalid choice, please choose again"
                ;;
        esac
    done

    echo "CPU microcode installed"
}

# 安装和配置NVIDIA驱动
setup_nvidia() {
    echo "do you want to install NVIDIA driver?"
    echo "1) skip NVIDIA driver installation (default)"
    echo "2) nvidia-open (open-source driver)"
    echo "3) nvidia (proprietary driver)"
    read -p "please choose NVIDIA driver (1-3): " nvidia_choice

    case "${nvidia_choice:-1}" in
        2)
            echo "install nvidia-open driver..."
            arch-chroot /mnt pacman -S --noconfirm nvidia-open nvidia-utils nvidia-settings
            ;;
        3)
            echo "install nvidia driver..."
            arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
            ;;
        *)
            echo "skip NVIDIA driver installation"
            return
            ;;
    esac

    # 配置 mkinitcpio.conf
    echo "configure mkinitcpio.conf..."
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

    echo "NVIDIA driver setup completed"
}

# 配置archlinuxcn源
setup_archlinuxcn() {
    echo "setup archlinuxcn..."

    # 添加archlinuxcn源
    cat >> /mnt/etc/pacman.conf << EOF

[archlinuxcn]
SigLevel = Optional TrustAll
Server = https://mirrors.bfsu.edu.cn/archlinuxcn/\$arch
EOF

    # 安装archlinuxcn-keyring和yay
    arch-chroot /mnt pacman -Sy --noconfirm archlinuxcn-keyring
    arch-chroot /mnt pacman -S --noconfirm yay

    echo "archlinuxcn setup completed"
}

# 设置用户和密码
setup_users() {
    echo "setup users..."

    # 安装必要的包
    echo "install sudo ..."
    if ! arch-chroot /mnt pacman -S --noconfirm sudo; then
        echo "error: install sudo failed"
        exit 1
    fi

    # 提示用户输入新用户名
    while true; do
        read -p "please input username: " username
        if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            # 检查用户名是否已存在
            if ! arch-chroot /mnt id "$username" >/dev/null 2>&1; then
                break
            else
                echo "error: username already exists"
            fi
        else
            echo "error: invalid username"
        fi
    done

    # 创建新用户
    echo "create user: $username..."
    if ! arch-chroot /mnt useradd -m -G wheel,audio,video,storage,optical,network -s /bin/zsh "$username"; then
        echo "error: create user failed"
        exit 1
    fi

    # 配置 sudo
    echo "configure sudo..."
    if ! arch-chroot /mnt sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers; then
        echo "error: configure sudo failed"
        exit 1
    fi

    # 设置 root 密码
    echo "set root password..."
    while true; do
        echo "please input root password:"
        if arch-chroot /mnt passwd; then
            break
        fi
        echo "error: set root password failed"
    done

    # 设置新用户密码
    echo "set password for user: $username..."
    while true; do
        echo "please input password for user: $username"
        if arch-chroot /mnt passwd "$username"; then
            break
        fi
        echo "error: set password for user failed"
    done

    # 设置用户目录绑定挂载
    setup_user_dirs "$username"

    echo "users setup completed"
}

# 设置用户目录绑定挂载
setup_user_dirs() {
    # 检查是否设置了数据盘
    if [ -z "$DATA_PARTITION" ]; then
        return
    fi

    local username="$1"
    echo "setup user directories..."

    # 默认要绑定的目录
    local default_dirs=(".cache" "Downloads" "Documents" "Pictures")

    # 在数据盘上创建用户目录
    if ! mkdir -p "/mnt/mnt/$username"; then
        echo "error: create data disk directory failed"
        exit 1
    fi

    # 询问用户是否需要添加其他目录
    read -p "do you want to add additional directories to bind mount? (separate multiple directories with space, press Enter to skip): " additional_dirs

    # 将用户输入的目录添加到数组中
    if [ -n "$additional_dirs" ]; then
        for dir in $additional_dirs; do
            default_dirs+=("$dir")
        done
    fi

    # 创建目录并设置绑定挂载
    for dir in "${default_dirs[@]}"; do
        echo "create directory: $dir"

        # 在数据盘上创建目录
        if ! mkdir -p "/mnt/mnt/$username/$dir"; then
            echo "error: create data disk directory $dir failed"
            continue
        fi

        # 在用户主目录创建目录
        if ! mkdir -p "/mnt/home/$username/$dir"; then
            echo "error: create home directory $dir failed"
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

    echo "user directories setup completed"
}

# 生成 fstab
generate_fstab() {
    echo "generate fstab..."
    if ! genfstab -U /mnt >> /mnt/etc/fstab; then
        echo "error: generate fstab failed"
        exit 1
    fi
    echo "fstab generated"
}

# 开始安装过程
main() {
    local total_steps=14
    local current_step=0

    echo "begin installation..."

    # 检查系统环境
    show_progress $((++current_step)) "$total_steps" "check environment"
    check_environment

    # 更新镜像源
    show_progress $((++current_step)) "$total_steps" "update mirrors"
    update_mirrors

    # 执行磁盘操作
    show_progress $((++current_step)) "$total_steps" "select disk"
    select_disk
    create_partitions "$DISK"
    format_partitions

    # 处理数据盘
    show_progress $((++current_step)) "$total_steps" "add data disk"
    add_data_disk

    # 设置挂载点
    show_progress $((++current_step)) "$total_steps" "setup mountpoints"
    setup_mountpoints

    # 安装基本系统
    show_progress $((++current_step)) "$total_steps" "install base system"
    install_base_system

    # 配置网络
    show_progress $((++current_step)) "$total_steps" "setup network"
    setup_network

    # 配置本地化
    show_progress $((++current_step)) "$total_steps" "setup localization"
    setup_localization

    # 配置主机名
    show_progress $((++current_step)) "$total_steps" "setup hostname"
    setup_hostname

    # 安装微码和配置引导
    show_progress $((++current_step)) "$total_steps" "install microcode and setup bootloader"
    install_microcode
    setup_bootloader

    # 安装NVIDIA驱动
    show_progress $((++current_step)) "$total_steps" "setup NVIDIA driver"
    setup_nvidia

    # 配置archlinuxcn源
    show_progress $((++current_step)) "$total_steps" "setup archlinuxcn"
    setup_archlinuxcn

    # 设置用户
    show_progress $((++current_step)) "$total_steps" "setup users"
    setup_users

    # 生成 fstab 和最终检查
    show_progress $((++current_step)) "$total_steps" "generate fstab"
    generate_fstab

    # 验证安装
    if ! verify_installation; then
        echo "warning: installation verification failed"
        echo "please check the error messages and try again"
        read -p "do you want to continue? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 运行主函数
main
