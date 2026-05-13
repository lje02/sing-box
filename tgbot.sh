#!/bin/bash

# --- 路径定义 ---
BOT_DIR="/etc/sing-box"
BOT_SCRIPT="$BOT_DIR/tg_worker.sh"
BOT_CONF="$BOT_DIR/tg_bot.conf"
BOT_USERS="$BOT_DIR/tg_bot_users.conf"
BOT_SERVICE="/etc/systemd/system/tg-bot.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 内部函数：获取监控数据 ---
get_stats() {
    local uptime=$(uptime -p | sed 's/up //')
    local mem_info=$(free -m | awk '/Mem:/ {printf "%d %d %.2f", $3, $2, $3/$2*100}')
    local mem_used=$(echo $mem_info | awk '{print $1}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_per=$(echo $mem_info | awk '{print $3}')
    
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cpu_per=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    local status=$(systemctl is-active sing-box == "active" && echo "✅ 运行中" || echo "❌ 已停止")
    
    # 获取默认网卡流量 (兼容常见命名)
    local dev=$(ip route | grep default | awk '{print $5}' | head -n1)
    local rx=$(cat /proc/net/dev | grep "$dev" | awk '{printf "%.2f GB", $2/1024/1024/1024}')
    local tx=$(cat /proc/net/dev | grep "$dev" | awk '{printf "%.2f GB", $10/1024/1024/1024}')

    echo "📊 *sing-box 系统报告*
--------------------------
🔹 *服务状态*: $status
🔹 *CPU 占用*: ${cpu_per}%
🔹 *内存占用*: ${mem_used}/${mem_total}MB (${mem_per}%)
🔹 *系统负载*: $load
🔹 *网卡流量*: ⬇️$rx | ⬆️$tx
🔹 *系统运行*: $uptime
--------------------------
🕒 $(date '+%Y-%m-%d %H:%M:%S')"
}

# --- 生成菜单 (带内联键盘) ---
get_main_menu() {
    cat <<'EOF'
{
  "text": "👋 欢迎使用 sing-box 监控系统\n\n请选择操作:",
  "reply_markup": {
    "inline_keyboard": [
      [
        {"text": "📊 系统状态", "callback_data": "cmd_status"},
        {"text": "🔄 重启服务", "callback_data": "cmd_restart"}
      ],
      [
        {"text": "⚙️ 查看配置", "callback_data": "cmd_config"},
        {"text": "📝 查看日志", "callback_data": "cmd_logs"}
      ],
      [
        {"text": "🛠️ 管理员菜单", "callback_data": "cmd_admin"},
        {"text": "ℹ️ 帮助", "callback_data": "cmd_help"}
      ]
    ]
  }
}
EOF
}

# --- 管理员菜单 ---
get_admin_menu() {
    cat <<'EOF'
{
  "text": "🛠️ 管理员菜单\n\n请选择操作:",
  "reply_markup": {
    "inline_keyboard": [
      [
        {"text": "🚀 启动服务", "callback_data": "admin_start"},
        {"text": "⏹️ 停止服务", "callback_data": "admin_stop"}
      ],
      [
        {"text": "🔄 重启服务", "callback_data": "admin_restart"},
        {"text": "📊 内存优化", "callback_data": "admin_optimize"}
      ],
      [
        {"text": "👥 用户管理", "callback_data": "admin_users"},
        {"text": "◀️ 返回", "callback_data": "back_main"}
      ]
    ]
  }
}
EOF
}

# --- 用户管理菜单 ---
get_users_menu() {
    cat <<'EOF'
{
  "text": "👥 用户管理\n\n请选择操作:",
  "reply_markup": {
    "inline_keyboard": [
      [
        {"text": "➕ 添加用户", "callback_data": "user_add"},
        {"text": "➖ 删除用户", "callback_data": "user_remove"}
      ],
      [
        {"text": "📋 列表用户", "callback_data": "user_list"},
        {"text": "◀️ 返回", "callback_data": "back_admin"}
      ]
    ]
  }
}
EOF
}

# --- 脚本安装功能 ---
install_bot() {
    echo -e "${YELLOW}--- Telegram 机器人安装 ---${PLAIN}"
    
    # 环境检查
    apt update && apt install -y jq curl bc procps
    
    mkdir -p "$BOT_DIR"
    
    read -p "请输入 Bot Token: " TG_TOKEN
    read -p "请输入主 Chat ID (管理员): " ADMIN_CHATID
    
    if [[ -z "$TG_TOKEN" || -z "$ADMIN_CHATID" ]]; then
        echo -e "${RED}✘ 错误: Token 或 Chat ID 不能为空${PLAIN}"
        return
    fi
    
    # 保存配置
    cat > "$BOT_CONF" <<EOF
TOKEN="$TG_TOKEN"
ADMIN_CHAT_ID="$ADMIN_CHATID"
EOF

    # 初始化用户配置文件
    cat > "$BOT_USERS" <<EOF
# 授权用户列表 (每行一个用户ID)
# 格式: USER_ID|USERNAME|ROLE (role: admin, user)
$ADMIN_CHATID|admin|admin
EOF
    chmod 600 "$BOT_USERS"

    # 生成工作脚本
    cat > "$BOT_SCRIPT" <<'EOWORKER'
#!/bin/bash
source /etc/sing-box/tg_bot.conf
OFFSET_FILE="/tmp/tg_bot_offset"
LAST_ALERT_TIME=0
USER_STATE_FILE="/tmp/tg_user_state"

send_msg() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-Markdown}"
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$chat_id" \
        -d "parse_mode=$parse_mode" \
        -d "text=$text" > /dev/null
}

# 发送菜单消息 (使用 editMessageText 编辑消息或发送新消息)
send_menu() {
    local chat_id="$1"
    local menu_json="$2"
    
    local text=$(echo "$menu_json" | jq -r '.text')
    local keyboard=$(echo "$menu_json" | jq -c '.reply_markup')
    
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": $chat_id,
            \"text\": \"$text\",
            \"parse_mode\": \"Markdown\",
            \"reply_markup\": $keyboard
        }" > /dev/null
}

# 编辑菜单消息
edit_menu() {
    local chat_id="$1"
    local message_id="$2"
    local menu_json="$3"
    
    local text=$(echo "$menu_json" | jq -r '.text')
    local keyboard=$(echo "$menu_json" | jq -c '.reply_markup')
    
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/editMessageText" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": $chat_id,
            \"message_id\": $message_id,
            \"text\": \"$text\",
            \"parse_mode\": \"Markdown\",
            \"reply_markup\": $keyboard
        }" > /dev/null
}

# 回复回调查询 (callback)
answer_callback_query() {
    local callback_query_id="$1"
    local text="${2:-已处理}"
    local alert="${3:-false}"
    
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/answerCallbackQuery" \
        -d "callback_query_id=$callback_query_id" \
        -d "text=$text" \
        -d "show_alert=$alert" > /dev/null
}

# 检查用户是否授权
is_user_authorized() {
    local user_id="$1"
    grep -q "^$user_id|" /etc/sing-box/tg_bot_users.conf 2>/dev/null
    return $?
}

# 获取用户角色
get_user_role() {
    local user_id="$1"
    grep "^$user_id|" /etc/sing-box/tg_bot_users.conf 2>/dev/null | cut -d'|' -f3
}

# 获取系统状态
get_stats() {
    local uptime=$(uptime -p | sed 's/up //')
    local mem_info=$(free -m | awk '/Mem:/ {printf "%d %d %.2f", $3, $2, $3/$2*100}')
    local mem_used=$(echo $mem_info | awk '{print $1}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_per=$(echo $mem_info | awk '{print $3}')
    
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cpu_per=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    local status=$(systemctl is-active sing-box == "active" && echo "✅ 运行中" || echo "❌ 已停止")
    
    local dev=$(ip route | grep default | awk '{print $5}' | head -n1)
    local rx=$(cat /proc/net/dev | grep "$dev" | awk '{printf "%.2f GB", $2/1024/1024/1024}')
    local tx=$(cat /proc/net/dev | grep "$dev" | awk '{printf "%.2f GB", $10/1024/1024/1024}')

    echo "📊 *sing-box 系统报告*
--------------------------
🔹 *服务状态*: $status
🔹 *CPU 占用*: ${cpu_per}%
🔹 *内存占用*: ${mem_used}/${mem_total}MB (${mem_per}%)
🔹 *系统负载*: $load
🔹 *网卡流量*: ⬇️$rx | ⬆️$tx
🔹 *系统运行*: $uptime
--------------------------
🕒 $(date '+%Y-%m-%d %H:%M:%S')"
}

# 负载警报逻辑 (80%)
check_alert() {
    local now=$(date +%s)
    if (( now - LAST_ALERT_TIME < 300 )); then return; fi

    local mem_per=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    local cpu_per=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    if (( $(echo "$mem_per > 80" | bc -l) )) || (( $(echo "$cpu_per > 80" | bc -l) )); then
        send_msg "$ADMIN_CHAT_ID" "⚠️ *负载预警 (超过80%)*
--------------------------
🔹 CPU占用: ${cpu_per}%
🔹 内存占用: ${mem_per}%
🚨 请检查系统状态！"
        LAST_ALERT_TIME=$now
    fi
}

# 处理命令
handle_command() {
    local chat_id="$1"
    local user_id="$2"
    local username="$3"
    local command="$4"
    local message_id="$5"
    
    if ! is_user_authorized "$user_id"; then
        send_msg "$chat_id" "❌ 你没有权限使用此命令。\n\n你的 ID: \`$user_id\`\n用户名: @$username"
        return
    fi
    
    case "$command" in
        /start)
            source /etc/sing-box/tg_bot_functions.sh
            send_menu "$chat_id" "$(get_main_menu)"
            ;;
        /status)
            send_msg "$chat_id" "$(get_stats)"
            ;;
        /help)
            send_msg "$chat_id" "ℹ️ *帮助菜单*
--------------------------
*/start* - 显示主菜单
*/status* - 查看系统状态
*/help* - 显示此帮助
*/myid* - 显示你的用户ID
--------------------------
点击菜单按钮进行操作"
            ;;
        /myid)
            send_msg "$chat_id" "👤 *你的用户信息*
--------------------------
🔹 User ID: \`$user_id\`
🔹 用户名: @$username
🔹 权限级别: $(get_user_role $user_id)
--------------------------
将此 ID 提供给管理员进行授权"
            ;;
        *)
            send_msg "$chat_id" "❓ 未知命令: $command\n发送 /help 查看帮助"
            ;;
    esac
}

# 处理回调查询 (按钮点击)
handle_callback_query() {
    local callback_query_id="$1"
    local chat_id="$2"
    local user_id="$3"
    local username="$4"
    local message_id="$5"
    local callback_data="$6"
    
    if ! is_user_authorized "$user_id"; then
        answer_callback_query "$callback_query_id" "❌ 无权限" true
        return
    fi
    
    local user_role=$(get_user_role "$user_id")
    
    case "$callback_data" in
        cmd_status)
            send_msg "$chat_id" "$(get_stats)"
            answer_callback_query "$callback_query_id" "✅ 已发送状态报告"
            ;;
        cmd_restart)
            if [[ "$user_role" == "admin" ]]; then
                systemctl restart sing-box 2>/dev/null
                send_msg "$chat_id" "✅ 服务已重启"
                answer_callback_query "$callback_query_id" "✅ 重启成功"
            else
                answer_callback_query "$callback_query_id" "❌ 仅管理员可操作" true
            fi
            ;;
        cmd_config)
            send_msg "$chat_id" "⚙️ *sing-box 配置*\n(配置文件内容)"
            answer_callback_query "$callback_query_id" "已发送配置"
            ;;
        cmd_logs)
            send_msg "$chat_id" "📝 *最近日志*\n(日志内容)"
            answer_callback_query "$callback_query_id" "已发送日志"
            ;;
        cmd_admin)
            if [[ "$user_role" == "admin" ]]; then
                source /etc/sing-box/tg_bot_functions.sh
                edit_menu "$chat_id" "$message_id" "$(get_admin_menu)"
                answer_callback_query "$callback_query_id" "进入管理员菜单"
            else
                answer_callback_query "$callback_query_id" "❌ 仅管理员可访问" true
            fi
            ;;
        cmd_help)
            send_msg "$chat_id" "ℹ️ *帮助菜单*
--------------------------
*/start* - 显示主菜单
*/status* - 查看系统状态
*/help* - 显示此帮助
*/myid* - 显示你的用户ID
--------------------------
点击菜单按钮进行操作"
            answer_callback_query "$callback_query_id" "已发送帮助"
            ;;
        admin_start)
            systemctl start sing-box 2>/dev/null
            send_msg "$chat_id" "✅ 服务已启动"
            answer_callback_query "$callback_query_id" "✅ 启动成功"
            ;;
        admin_stop)
            systemctl stop sing-box 2>/dev/null
            send_msg "$chat_id" "⏹️ 服务已停止"
            answer_callback_query "$callback_query_id" "⏹️ 已停止"
            ;;
        admin_restart)
            systemctl restart sing-box 2>/dev/null
            send_msg "$chat_id" "🔄 服务已重启"
            answer_callback_query "$callback_query_id" "🔄 已重启"
            ;;
        admin_optimize)
            sync && echo 3 > /proc/sys/vm/drop_caches
            send_msg "$chat_id" "✅ 内存已优化"
            answer_callback_query "$callback_query_id" "✅ 优化完成"
            ;;
        admin_users)
            source /etc/sing-box/tg_bot_functions.sh
            edit_menu "$chat_id" "$message_id" "$(get_users_menu)"
            answer_callback_query "$callback_query_id" "进入用户管理"
            ;;
        user_list)
            local user_list=$(cat /etc/sing-box/tg_bot_users.conf | grep -v "^#" | awk -F'|' '{printf "🔹 ID: %s | 角色: %s\n", $1, $3}')
            send_msg "$chat_id" "👥 *授权用户列表*\n--------------------------\n$user_list"
            answer_callback_query "$callback_query_id" "已发送用户列表"
            ;;
        back_main)
            source /etc/sing-box/tg_bot_functions.sh
            edit_menu "$chat_id" "$message_id" "$(get_main_menu)"
            answer_callback_query "$callback_query_id" "返回主菜单"
            ;;
        back_admin)
            source /etc/sing-box/tg_bot_functions.sh
            edit_menu "$chat_id" "$message_id" "$(get_admin_menu)"
            answer_callback_query "$callback_query_id" "返回管理菜单"
            ;;
        *)
            answer_callback_query "$callback_query_id" "❓ 未知操作"
            ;;
    esac
}

# 主循环
while true; do
    check_alert

    OFFSET=$(cat $OFFSET_FILE 2>/dev/null || echo 0)
    UPDATES=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=30")
    
    echo "$UPDATES" | jq -c '.result[]' 2>/dev/null | while read -r update; do
        UPDATE_ID=$(echo "$update" | jq -r '.update_id')
        
        # 处理普通消息
        if echo "$update" | jq -e '.message' > /dev/null 2>&1; then
            MSG_TEXT=$(echo "$update" | jq -r '.message.text // empty')
            USER_ID=$(echo "$update" | jq -r '.message.from.id')
            USERNAME=$(echo "$update" | jq -r '.message.from.username // "unknown"')
            CHAT_ID=$(echo "$update" | jq -r '.message.chat.id')
            MESSAGE_ID=$(echo "$update" | jq -r '.message.message_id')
            
            if [[ -n "$MSG_TEXT" ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 消息 from $USER_ID (@$USERNAME): $MSG_TEXT" >> /tmp/tg_bot.log
                handle_command "$CHAT_ID" "$USER_ID" "$USERNAME" "$MSG_TEXT" "$MESSAGE_ID"
            fi
        fi
        
        # 处理回调查询 (按钮点击)
        if echo "$update" | jq -e '.callback_query' > /dev/null 2>&1; then
            CALLBACK_QUERY_ID=$(echo "$update" | jq -r '.callback_query.id')
            CALLBACK_CHAT_ID=$(echo "$update" | jq -r '.callback_query.message.chat.id')
            CALLBACK_USER_ID=$(echo "$update" | jq -r '.callback_query.from.id')
            CALLBACK_USERNAME=$(echo "$update" | jq -r '.callback_query.from.username // "unknown"')
            CALLBACK_MESSAGE_ID=$(echo "$update" | jq -r '.callback_query.message.message_id')
            CALLBACK_DATA=$(echo "$update" | jq -r '.callback_query.data')
            
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 回调 from $CALLBACK_USER_ID (@$CALLBACK_USERNAME): $CALLBACK_DATA" >> /tmp/tg_bot.log
            handle_callback_query "$CALLBACK_QUERY_ID" "$CALLBACK_CHAT_ID" "$CALLBACK_USER_ID" "$CALLBACK_USERNAME" "$CALLBACK_MESSAGE_ID" "$CALLBACK_DATA"
        fi
        
        echo $((UPDATE_ID + 1)) > $OFFSET_FILE
    done
    sleep 2
done
EOWORKER

    # 提取菜单函数到独立文件供 worker 调用
    cat > "$BOT_DIR/tg_bot_functions.sh" <<'EOFUNC'
get_main_menu() {
    cat <<'EOF'
{
  "text": "👋 欢迎使用 sing-box 监控系统\n\n请选择操作:",
  "reply_markup": {
    "inline_keyboard": [
      [
        {"text": "📊 系统状态", "callback_data": "cmd_status"},
        {"text": "🔄 重启服务", "callback_data": "cmd_restart"}
      ],
      [
        {"text": "⚙️ 查看配置", "callback_data": "cmd_config"},
        {"text": "📝 查看日志", "callback_data": "cmd_logs"}
      ],
      [
        {"text": "🛠️ 管理员菜单", "callback_data": "cmd_admin"},
        {"text": "ℹ️ 帮助", "callback_data": "cmd_help"}
      ]
    ]
  }
}
EOF
}

get_admin_menu() {
    cat <<'EOF'
{
  "text": "🛠️ 管理员菜单\n\n请选择操作:",
  "reply_markup": {
    "inline_keyboard": [
      [
        {"text": "🚀 启动服务", "callback_data": "admin_start"},
        {"text": "⏹️ 停止服务", "callback_data": "admin_stop"}
      ],
      [
        {"text": "🔄 重启服务", "callback_data": "admin_restart"},
        {"text": "📊 内存优化", "callback_data": "admin_optimize"}
      ],
      [
        {"text": "👥 用户管理", "callback_data": "admin_users"},
        {"text": "◀️ 返回", "callback_data": "back_main"}
      ]
    ]
  }
}
EOF
}

get_users_menu() {
    cat <<'EOF'
{
  "text": "👥 用户管理\n\n请选择操作:",
  "reply_markup": {
    "inline_keyboard": [
      [
        {"text": "➕ 添加用户", "callback_data": "user_add"},
        {"text": "➖ 删除用户", "callback_data": "user_remove"}
      ],
      [
        {"text": "📋 列表用户", "callback_data": "user_list"},
        {"text": "◀️ 返回", "callback_data": "back_admin"}
      ]
    ]
  }
}
EOF
}
EOFUNC

    chmod +x "$BOT_SCRIPT"

    # 生成 Service
    cat > "$BOT_SERVICE" <<EOF
[Unit]
Description=Sing-box Telegram Bot
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $BOT_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tg-bot
    echo -e "${GREEN}✔ 机器人已启动并设置为开机自启${PLAIN}"
    echo -e "${CYAN}配置文件位置: $BOT_CONF${PLAIN}"
    echo -e "${CYAN}用户配置文件: $BOT_USERS${PLAIN}"
}

# --- 卸载功能 ---
uninstall_bot() {
    echo -e "${YELLOW}正在卸载 Telegram 机器人...${PLAIN}"
    systemctl stop tg-bot 2>/dev/null
    systemctl disable tg-bot 2>/dev/null
    rm -f "$BOT_SERVICE"
    rm -f "$BOT_SCRIPT"
    rm -f "$BOT_CONF"
    rm -f "$BOT_USERS"
    rm -f "$BOT_DIR/tg_bot_functions.sh"
    systemctl daemon-reload
    echo -e "${GREEN}✔ 卸载完成${PLAIN}"
}

# --- 用户管理 ---
manage_users() {
    while true; do
        echo -e "${CYAN}--- 用户管理菜单 ---${PLAIN}"
        echo -e "1. 添加用户"
        echo -e "2. 删除用户"
        echo -e "3. 列表用户"
        echo -e "0. 返回"
        read -p "请选择: " choice
        
        case $choice in
            1)
                read -p "请输入用户 ID: " uid
                read -p "请输入用户名 (可选): " uname
                read -p "请输入角色 (admin/user): " role
                if ! grep -q "^$uid|" "$BOT_USERS"; then
                    echo "$uid|${uname:-unknown}|$role" >> "$BOT_USERS"
                    echo -e "${GREEN}✔ 用户已添加${PLAIN}"
                else
                    echo -e "${RED}✘ 用户已存在${PLAIN}"
                fi
                ;;
            2)
                read -p "请输入要删除的用户 ID: " uid
                sed -i "/^$uid|/d" "$BOT_USERS"
                echo -e "${GREEN}✔ 用户已删除${PLAIN}"
                ;;
            3)
                echo -e "${CYAN}--- 授权用户列表 ---${PLAIN}"
                grep -v "^#" "$BOT_USERS" | awk -F'|' '{printf "ID: %-15s | 用户名: %-10s | 角色: %s\n", $1, $2, $3}'
                ;;
            0)
                break
                ;;
        esac
    done
}

# --- 主菜单 ---
clear
echo -e "${CYAN}sing-box Telegram 监控管理脚本 [增强版]${PLAIN}"
echo -e "================================"
echo -e "1. 安装/重新安装 机器人"
echo -e "2. 卸载 机器人"
echo -e "3. 用户管理"
echo -e "0. 退出"
read -p "请选择: " choice

case $choice in
    1) install_bot ;;
    2) uninstall_bot ;;
    3) manage_users ;;
    *) exit 0 ;;
esac
