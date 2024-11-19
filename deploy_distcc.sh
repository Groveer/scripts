#!/bin/bash
###################
# Distcc 部署脚本
###################

# Distcc Deployment Script
# 作者：Groveer
# 创建日期：2024-11-18
# 描述：在 Arch Linux 或 Debian 系统上自动部署 distcc 分布式编译系统
# 脚本权限要求：root

###################
# 错误处理
###################
set -e  # 遇到错误立即退出
set -u  # 使用未定义的变量时报错
set -o pipefail  # 管道中的任何错误都会导致管道失败

###################
# 全局变量
###################
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_NAME=$(basename "$0")
readonly VERSION="1.0.0"

# 系统相关
SYSTEM_TYPE=""
DISTCC_CONFIG_DIR="/etc/distcc"
DISTCC_SERVICE="distcc"

###################
# 通用函数
###################
# 输出错误信息并退出
error() {
    echo "错误：$1" >&2
    exit 1
}

# 输出信息
info() {
    echo "信息：$1"
}

# 输出调试信息
debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo "调试：$1" >&2
    fi
}

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本需要 root 权限运行"
    fi
}

# 显示使用帮助
show_usage() {
    cat << EOF
用法: $SCRIPT_NAME [选项]

选项:
    -h, --help      显示此帮助信息
    -v, --version   显示版本信息
    -d, --debug     启用调试模式
    --no-color      禁用彩色输出

示例:
    $SCRIPT_NAME          # 运行安装
    $SCRIPT_NAME --debug  # 以调试模式运行
EOF
}

# 显示版本信息
show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            *)
                error "未知选项: $1"
                ;;
        esac
    done
}

###################
# 系统检测函数
###################
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            "debian"|"ubuntu"|"linuxmint"|"deepin"|"uos")
                echo "debian"
                ;;
            "arch"|"manjaro")
                echo "arch"
                ;;
            *)
                echo "unknown"
                ;;
        esac
    else
        echo "unknown"
    fi
}

###################
# AUR 相关函数
###################
# 检查是否安装了 AUR 助手
check_aur_helper() {
    local -r helpers=("yay" "paru" "aurman" "pikaur" "yaourt")
    
    for helper in "${helpers[@]}"; do
        if command -v "$helper" >/dev/null 2>&1; then
            echo "$helper"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# 使用 AUR 助手安装包
aur_install() {
    local -r package=$1
    local -r helper=$(check_aur_helper)
    
    case $helper in
        "yay")
            yay -Sy --noconfirm "$package" || error "使用 yay 安装 $package 失败"
            ;;
        "paru")
            paru -Sy --noconfirm "$package" || error "使用 paru 安装 $package 失败"
            ;;
        "aurman")
            aurman -Sy --noconfirm "$package" || error "使用 aurman 安装 $package 失败"
            ;;
        "pikaur")
            pikaur -Sy --noconfirm "$package" || error "使用 pikaur 安装 $package 失败"
            ;;
        "yaourt")
            yaourt -Sy --noconfirm "$package" || error "使用 yaourt 安装 $package 失败"
            ;;
        *)
            # 如果没有安装任何 AUR 助手，安装 yay
            info "未检测到 AUR 助手，准备安装 yay..."
            install_yay
            yay -Sy --noconfirm "$package" || error "使用 yay 安装 $package 失败"
            ;;
    esac
}

# 安装 yay
install_yay() {
    info "正在安装 yay..."
    # 确保安装了基本开发工具
    pacman -Sy --noconfirm --needed base-devel git || error "安装基本开发工具失败"
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    cd "$temp_dir" || error "无法创建临时目录"
    
    # 克隆并编译安装 yay
    git clone https://aur.archlinux.org/yay.git || error "克隆 yay 仓库失败"
    cd yay || error "进入 yay 目录失败"
    makepkg -si --noconfirm || error "编译安装 yay 失败"
    
    cd "$SCRIPT_DIR"
    
    if command -v yay >/dev/null 2>&1; then
        info "yay 安装成功"
    else
        error "yay 安装失败"
    fi
}

###################
# Distcc 相关函数
###################
# 检查 distcc 是否已安装
check_distcc() {
    if command -v distcc >/dev/null 2>&1; then
        return 0  # distcc 已安装
    else
        return 1  # distcc 未安装
    fi
}

# 检查 Debian 系统编译依赖
check_debian_deps() {
    local -r deps=(
        "git"
        "build-essential"
        "autoconf"
        "automake"
        "python3-dev"
        "pkg-config"
        "libtool"
        "libglib2.0-dev"
        "libpopt-dev"
    )
    
    info "检查编译依赖..."
    apt update || error "apt update 失败"
    
    for dep in "${deps[@]}"; do
        if ! dpkg -l | grep -q "^ii  $dep"; then
            info "安装依赖: $dep"
            apt install -y "$dep" || error "安装 $dep 失败"
        fi
    done
}

# 从源码编译安装 distcc
build_distcc_from_source() {
    info "开始从源码编译安装 distcc..."
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    cd "$temp_dir" || error "无法创建临时目录"
    
    # 克隆源码
    info "克隆 distcc 源码..."
    git clone https://github.com/distcc/distcc.git || error "克隆 distcc 仓库失败"
    cd distcc || error "进入 distcc 目录失败"
    
    # 配置和编译
    info "配置项目..."
    ./autogen.sh || error "autogen.sh 执行失败"
    ./configure || error "configure 失败"
    
    info "编译项目..."
    make -j$(nproc) || error "编译失败"
    
    info "安装项目..."
    make install || error "安装失败"
    
    # 返回原目录
    cd "$SCRIPT_DIR"
    
    # 更新动态链接库缓存
    ldconfig || error "更新动态链接库缓存失败"
}

# 安装 distcc
install_distcc() {
    local -r system_type=$1
    
    if check_distcc; then
        read -p "检测到系统中已安装 distcc，是否重新安装？[y/N] " answer
        if [[ $answer != "y" && $answer != "Y" ]]; then
            info "保留现有 distcc 安装"
            return 0
        fi
    fi

    info "开始安装 distcc..."
    case $system_type in
        "debian")
            # 检查并安装编译依赖
            check_debian_deps
            # 从源码编译安装
            build_distcc_from_source
            ;;
        "arch")
            # 使用已安装的 AUR 助手或安装 yay 后安装 distcc-git
            aur_install "distcc-git"
            ;;
        *)
            error "不支持的系统类型"
            ;;
    esac

    if check_distcc; then
        info "distcc 安装成功"
        return 0
    else
        error "distcc 安装失败"
    fi
}

###################
# 清理函数
###################
cleanup() {
    # 清理临时文件和恢复环境
    debug "执行清理操作..."
}

###################
# 主函数
###################
main() {
    # 解析命令行参数
    parse_args "$@"

    # 检查root权限
    check_root

    # 设置清理钩子
    trap cleanup EXIT

    # 检测系统类型
    SYSTEM_TYPE=$(detect_system)
    case $SYSTEM_TYPE in
        "debian")
            info "检测到 Debian 系统"
            ;;
        "arch")
            info "检测到 Arch Linux 系统"
            ;;
        *)
            error "不支持的系统类型"
            ;;
    esac

    # 安装 distcc
    install_distcc "$SYSTEM_TYPE"
}

# 执行主函数
main "$@"
