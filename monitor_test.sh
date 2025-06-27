#!/bin/bash

# 参数检查：确保输入的是正整数（如果提供了参数）
if [ "$#" -gt 0 ] && ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "错误：参数必须是正整数"
    exit 1
fi

# 获取显示器对象路径
monitor_path=$(qdbus --literal com.deepin.daemon.Display /com/deepin/daemon/Display com.deepin.daemon.Display.Monitors 2>/dev/null |
               grep -oP 'ObjectPath: \K[^],]+' |  # 匹配到逗号或]时停止
               head -n1)  # 取第一个显示器

# 检查是否成功获取显示器路径
if [ -z "$monitor_path" ]; then
    echo "错误：无法获取显示器路径，请检查Deepin显示服务是否运行"
    exit 1
fi

# 定义旋转参数和循环控制
rotations=(1 2 4 8)
current_idx=0
max_loops=${1:-0}  # 默认0表示无限循环
loop_count=0

echo "开始屏幕旋转循环 (Ctrl+C 终止)"
echo "当前显示器路径: $monitor_path"

while :
do
    # 有限循环模式检查
    if [ "$max_loops" -gt 0 ] && [ "$loop_count" -ge "$max_loops" ]; then
        echo "完成指定循环次数：$max_loops"
        exit 0
    fi

    # 获取当前旋转参数
    current_rotation=${rotations[current_idx]}

    # 执行旋转命令
    echo -n "第 $((loop_count + 1)) 次设置：方向 $current_rotation ... "
    if qdbus --literal com.deepin.daemon.Display "$monitor_path" com.deepin.daemon.Display.Monitor.SetRotation "$current_rotation" &>/dev/null \
        && qdbus --literal com.deepin.daemon.Display /com/deepin/daemon/Display com.deepin.daemon.Display.ApplyChanges &>/dev/null
    then
        echo "成功"
    else
        echo "失败"
        exit 2
    fi

    # 更新索引和计数器
    current_idx=$(( (current_idx + 1) % 4 ))
    loop_count=$((loop_count + 1))

    # 设置间隔时间（可根据需要调整）
    sleep 10
done


