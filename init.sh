#!/bin/bash

echo -e "\033[33m扫描当前活动的网络连接...\033[0m"

# 获取当前活动的网络连接信息
ACTIVE_CONNECTION=$(nmcli -t -f NAME,TYPE connection show --active | head -n 1)
if [ -z "$ACTIVE_CONNECTION" ]; then
    echo "错误：未找到活动的网络连接"
    exit 1
fi

CONNECTION_NAME=$(echo "$ACTIVE_CONNECTION" | cut -d':' -f1)
CONNECTION_TYPE=$(echo "$ACTIVE_CONNECTION" | cut -d':' -f2)

echo -e "\033[33m找到活动连接：$CONNECTION_NAME ($CONNECTION_TYPE)\033[0m"

if [ -z "$CONNECTION_TYPE" ]; then
    echo "错误：找不到活动的网络连接 '$CONNECTION_NAME'"
    exit 1
fi

echo -e "\033[33m检测到 '$CONNECTION_NAME' 是 $CONNECTION_TYPE 类型连接\033[0m"

read -p "请输入LDAP账户: " USERNAME
read -s -p "请输入LDAP密码: " PASSWORD
echo

if [ "$CONNECTION_TYPE" = "802-3-ethernet" ]; then
    echo -e "\033[33m检测到有线网络已连接，执行有线认证...\033[0m"
    nmcli connection modify "$CONNECTION_NAME" \
        802-1x.eap peap \
        802-1x.phase2-auth gtc \
        802-1x.identity "$USERNAME" \
        802-1x.password "$PASSWORD"
    echo -e "\033[33m重启有线网络连接...\033[0m"
    nmcli connection down "$CONNECTION_NAME"
    nmcli connection up "$CONNECTION_NAME"
elif [ "$CONNECTION_TYPE" = "wifi" ] || [ "$CONNECTION_TYPE" = "802-11-wireless" ]; then
    echo -e "\033[33m检测到无线网络已连接，执行无线认证...\033[0m"
    curl -X POST --url "http://ac.uniontech.com/ac_portal/login.php" \
      --header "content-type: application/x-www-form-urlencoded" \
      --data opr="pwdLogin" \
      --data userName="$USERNAME" \
      --data-urlencode pwd="$PASSWORD" \
      --data rememberPwd="0"
else
    echo "未检测到已连接的有线或无线网络，请检查网络连接。"
    exit 1
fi

echo -e "\033[33m认证完成，正在等待网络连接...\033[0m"
# 等待网络连接稳定
sleep 3

# 激活
uos-activator-cmd -s --kms kms.uniontech.com:8900:nqYvXZXdNPKNn335

# 解锁root
if ! wget -P /tmp http://10.20.33.70:8080/signed_open-root.deb; then
    echo "root 解锁包下载失败，请联系管理员处理。"
    exit 1
fi
# dbus-send --print-reply --type=method_call --session --dest=com.deepin.DebInstaller /com/deepin/DebInstaller com.deepin.DebInstaller.InstallerDebPackge string:/tmp/signed_open-root.deb
deepin-deb-installer /tmp/signed_open-root.deb

echo -e "\033[33m修改账户安全等级...\033[0m"
# 设置密码策略为弱密码
sudo dbus-send --print-reply --type=method_call --system \
  --dest=com.deepin.daemon.PasswdConf \
  /com/deepin/daemon/PasswdConf \
  com.deepin.daemon.PasswdConf.WriteConfig \
  string:"[Password]
STRONG_PASSWORD = true
PASSWORD_MIN_LENGTH = 1
PASSWORD_MAX_LENGTH = 512
VALIDATE_POLICY = '1234567890;abcdefghijklmnopqrstuvwxyz;ABCDEFGHIJKLMNOPQRSTUVWXYZ;~\`!@#\$%^&*()-_+=|\\{}[]:\"'<>.,.?/'
VALIDATE_REQUIRED = 1
PALINDROME_NUM = 0
WORD_CHECK = 0
MONOTONE_CHARACTER_NUM = 0
CONSECUTIVE_SAME_CHARACTER_NUM = 0
DICT_PATH =
FIRST_LETTER_UPPERCASE = false"

if [ $? != 0 ]; then
  echo -e "\033[33m修改密码策略失败\033[0m"
else
    echo -e "\033[33m弱密码策略已生效，是否修改当前账户密码？\033[0m(y/N): "
    read answer
    answer=${answer:-N}
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        passwd $USER
    else
        echo -e "\033[33m跳过密码修改。\033[0m"
    fi
fi

# 关闭应用安全
sudo dbus-send --print-reply --type=method_call --system --dest=com.deepin.daemon.ACL /org/deepin/security/hierarchical/Control org.deepin.security.hierarchical.Control.SetMode boolean:false

echo -e "\033[33m应用安全已关闭，可运行任意应用\033[0m"
# enable ssh
sudo systemctl enable --now ssh

echo -e "\033[33mSSH 服务已启用\033[0m"
