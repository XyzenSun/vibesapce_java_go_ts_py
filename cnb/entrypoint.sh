#!/bin/bash
set -e

# ============================================
# 对象存储持久化配置 (环境变量)
# ============================================
# OSS_ENABLED: 是否启用持久化 (默认 true)
# OSS_ENDPOINT: S3 endpoint (如 https://oss-cn-beijing.aliyuncs.com)
# OSS_ACCESS_KEY: Access Key ID
# OSS_SECRET_KEY: Secret Access Key
# OSS_BUCKET: 桶名
# OSS_REGION: 区域 (默认 auto)
# OSS_PROJECT: 项目名，用于快照文件命名前缀 (默认 devbox)
# OSS_PATHS: 要持久化的目录列表 (逗号分隔)
# OSS_KEEP_COUNT: 保留快照数量 (默认 3)
# OSS_SYNC_INTERVAL: 同步间隔分钟 (默认 30)

OSS_ENABLED="true"
OSS_ENDPOINT="${OSS_ENDPOINT:-}"
OSS_ACCESS_KEY="${OSS_ACCESS_KEY:-}"
OSS_SECRET_KEY="${OSS_SECRET_KEY:-}"
OSS_BUCKET="${OSS_BUCKET:-}"
OSS_REGION="${OSS_REGION:-auto}"
OSS_PROJECT="${OSS_PROJECT:-devbox}"
OSS_PATHS="${OSS_PATHS:-/root/.claude,/root/.ssh,/root/.cc-switch,/root/.local/share/code-server/User/globalStorage,/root/.vscode-server/data/User/globalStorage}"
OSS_KEEP_COUNT="${OSS_KEEP_COUNT:-5}"
OSS_SYNC_INTERVAL="${OSS_SYNC_INTERVAL:-5}"

# rclone 内联配置字符串
RCLONE_REMOTE=":s3,provider=Other,access_key_id='${OSS_ACCESS_KEY}',secret_access_key='${OSS_SECRET_KEY}',region='${OSS_REGION}',endpoint='${OSS_ENDPOINT}'"

# 快照命名格式: 项目名-cnb-YYYYMMDD-HHMMSS.tar.zst
SNAPSHOT_NAME="${OSS_PROJECT}-cnb-$(date +%Y%m%d-%H%M%S).tar.zst"

# ============================================
# 函数: 上传快照到对象存储
# ============================================
upload_snapshot() {
    if [ "$OSS_ENABLED" != "true" ] || [ -z "$OSS_ENDPOINT" ] || [ -z "$OSS_ACCESS_KEY" ]; then
        echo "[OSS] 持久化未配置，跳过上传"
        return 0
    fi
    if [ ! -f /root/syncflag.txt ]; then
        echo "[OSS] 警告：未检测到 /root/syncflag.txt 标记！"
        echo "[OSS] 原因：本次容器启动时未能成功恢复云端数据。"
        echo "[OSS] 动作：已拦截本次上传，以保护云端数据不被覆盖。"
        return 1
    fi

    echo "[OSS] 开始上传快照..."
    local staging_dir="/tmp/oss-staging-$(date +%s)"
    local snapshot_file="/tmp/${SNAPSHOT_NAME}"
    local copy_failed=0

    # 1. 复制目标目录到 staging
    mkdir -p "$staging_dir"
    IFS=, read -ra PATHS <<< "$OSS_PATHS"
    for path in "${PATHS[@]}"; do
        if [ -d "$path" ]; then
            # 保持相对路径结构
            local rel_path="${path#/}"
            local target_dir="$staging_dir/$rel_path"
            mkdir -p "$target_dir"
            if ! cp -a "$path/." "$target_dir/"; then
                echo "[OSS] 复制失败: $path"
                copy_failed=1
            else
                echo "[OSS] 已复制: $path"
            fi
        fi
    done

    # 复制失败则中止，不上传，不清理旧快照
    if [ $copy_failed -eq 1 ]; then
        echo "[OSS] 复制阶段失败，中止上传"
        rm -rf "$staging_dir"
        return 1
    fi

    # 2. 打包为 tar.zst
    echo "[OSS] 打包压缩..."
    if ! tar -I zstd -cf "$snapshot_file" -C "$staging_dir" .; then
        echo "[OSS] 打包失败，中止上传"
        rm -rf "$staging_dir" "$snapshot_file"
        return 1
    fi

    # 3. 上传到对象存储
    local remote_path="${OSS_BUCKET}/${SNAPSHOT_NAME}"
    echo "[OSS] 上传到: $remote_path"
    if ! rclone copyto "$snapshot_file" "${RCLONE_REMOTE}:${remote_path}" -P --quiet >> /var/log/vibespace-rclone.log 2>&1; then
        echo "[OSS] 上传失败"
        rm -rf "$staging_dir" "$snapshot_file"
        return 1
    fi

    # 4. 清理本地临时文件
    rm -rf "$staging_dir" "$snapshot_file"

    # 5. 清理旧快照，保留最近 N 份
    echo "[OSS] 清理旧快照，保留 ${OSS_KEEP_COUNT} 份..."
    rclone lsf "${RCLONE_REMOTE}:${OSS_BUCKET}/" --files-only 2>> /var/log/vibespace-rclone.log | \
        grep "^${OSS_PROJECT}-cnb-" | sort -r | \
        tail -n +$((OSS_KEEP_COUNT + 1)) | \
        while IFS= read -r snap; do
            if [ -n "$snap" ]; then
                echo "[OSS] 删除旧快照: $snap"
                rclone delete "${RCLONE_REMOTE}:${OSS_BUCKET}/$snap" --quiet >> /var/log/vibespace-rclone.log 2>&1 || true
            fi
        done

    echo "[OSS] 上传完成"
}

# ============================================
# 函数: 从对象存储恢复快照
# ============================================
restore_snapshot() {
    if [ "$OSS_ENABLED" != "true" ] || [ -z "$OSS_ENDPOINT" ] || [ -z "$OSS_ACCESS_KEY" ]; then
        echo "[OSS] 持久化未配置，跳过恢复"
        return 0
    fi

    echo "[OSS] 开始恢复快照..."

    # 1. 查找最新快照
    local latest_snapshot
    latest_snapshot=$(rclone lsf "${RCLONE_REMOTE}:${OSS_BUCKET}/" --files-only 2>> /var/log/vibespace-rclone.log | grep "^${OSS_PROJECT}-cnb-" | sort -r | head -1)

    if [ -z "$latest_snapshot" ]; then
        echo "[OSS] 未找到快照，视为首次运行，允许同步"
        touch /root/syncflag.txt
        return 0
    fi

    echo "[OSS] 最新快照: $latest_snapshot"

    # 2. 下载快照
    local snapshot_file="/tmp/${latest_snapshot}"
    local remote_path="${OSS_BUCKET}/${latest_snapshot}"
    echo "[OSS] 下载快照..."
    if ! rclone copyto "${RCLONE_REMOTE}:${remote_path}" "$snapshot_file" --quiet >> /var/log/vibespace-rclone.log 2>&1; then
        echo "[OSS] 下载失败，跳过恢复"
        return 1
    fi

    # 3. 备份当前目录 (防止恢复失败导致数据丢失)
    echo "[OSS] 备份当前目录..."
    local backup_dir="/tmp/pre-restore-backup-$(date +%s)"
    mkdir -p "$backup_dir"
    IFS=, read -ra PATHS <<< "$OSS_PATHS"
    for path in "${PATHS[@]}"; do
        if [ -d "$path" ]; then
            local rel_path="${path#/}"
            mkdir -p "$backup_dir/$rel_path"
            cp -a "$path/." "$backup_dir/$rel_path/" 2>/dev/null || true
        fi
    done

    # 4. 清空目标目录
    echo "[OSS] 清空目标目录..."
    for path in "${PATHS[@]}"; do
        if [ -d "$path" ]; then
            rm -rf "$path"/* 2>/dev/null || true
            rm -rf "$path"/.[!.]* 2>/dev/null || true
            rm -rf "$path"/..?* 2>/dev/null || true
        fi
    done

    # 5. 解包恢复
    echo "[OSS] 解包恢复..."
    local staging_dir="/tmp/oss-restore-$(date +%s)"
    mkdir -p "$staging_dir"
    if ! tar -I zstd -xf "$snapshot_file" -C "$staging_dir"; then
        echo "[OSS] 解包失败，恢复备份..."
        for path in "${PATHS[@]}"; do
            local rel_path="${path#/}"
            if [ -d "$backup_dir/$rel_path" ]; then
                cp -a "$backup_dir/$rel_path/." "$path/" 2>/dev/null || true
            fi
        done
        rm -rf "$snapshot_file" "$staging_dir" "$backup_dir"
        return 1
    fi

    # 6. 复制恢复的文件到目标位置
    for path in "${PATHS[@]}"; do
        local rel_path="${path#/}"
        if [ -d "$staging_dir/$rel_path" ]; then
            mkdir -p "$path"
            cp -a "$staging_dir/$rel_path/." "$path/" 2>/dev/null || true
            echo "[OSS] 已恢复: $path"
        fi
    done

    # 7. 清理临时文件
    rm -rf "$snapshot_file" "$staging_dir" "$backup_dir"
    touch /root/syncflag.txt
    echo "[OSS] 恢复完成"
}

# ============================================
# 函数: 定时同步 (cron)
# ============================================
setup_periodic_sync() {
    if [ "$OSS_ENABLED" != "true" ]; then
        return 0
    fi

    # 使用 /etc/cron.d/ 目录，避免覆盖其他 cron 任务
    cat > /etc/cron.d/oss-sync << 'CRON_EOF'
# OSS 定时同步任务
*/OSS_SYNC_INTERVAL * * * * root /usr/local/bin/entrypoint.sh --sync >> /var/log/oss-sync.log 2>&1

CRON_EOF

    # 替换间隔变量
    sed -i "s/OSS_SYNC_INTERVAL/${OSS_SYNC_INTERVAL}/g" /etc/cron.d/oss-sync

    # 设置正确权限
    chmod 644 /etc/cron.d/oss-sync

    # 启动 cron 服务
    service cron start 2>/dev/null || cron 2>/dev/null || true

    echo "[OSS] 定时同步已启用，间隔 ${OSS_SYNC_INTERVAL} 分钟"
}

# ============================================
# 主流程
# ============================================

# 支持 --sync 参数，仅执行上传（用于 cron 定时任务）
if [ "$1" = "--sync" ]; then
    # cron 无法继承容器环境变量，从 PID 1 (容器主进程) 读取
    eval $(cat /proc/1/environ | tr '\0' '\n' | grep -E '^OSS_' | sed 's/^/export /')
    upload_snapshot
    exit $?
fi

rm -f /root/syncflag.txt

# ============================================
# FRPC 内网穿透
# ============================================
FRPC_CONFIG_URL="${FRPC_CONFIG_URL:-}"
FRPC_PID_FILE="/var/run/frpc.pid"
FRPC_LOG_FILE="/var/log/frpc.log"
FRPC_CONFIG_FILE="/etc/frpc.toml"

# 函数: 启动 frpc
start_frpc() {
    if [ -z "$FRPC_CONFIG_URL" ]; then
        echo "[FRPC] 未配置 FRPC_CONFIG_URL，跳过启动"
        return 1
    fi

    # 检查是否已运行
    if [ -f "$FRPC_PID_FILE" ] && kill -0 $(cat "$FRPC_PID_FILE") 2>/dev/null; then
        echo "[FRPC] frpc 已在运行 (PID: $(cat $FRPC_PID_FILE))"
        return 0
    fi

    # 备份旧配置文件
    if [ -f "$FRPC_CONFIG_FILE" ]; then
        mv "$FRPC_CONFIG_FILE" "$FRPC_CONFIG_FILE.bak.$(date +%s)"
        echo "[FRPC] 已备份旧配置文件"
    fi

    echo "[FRPC] 下载配置文件..."
    if ! wget -q -O "$FRPC_CONFIG_FILE" "$FRPC_CONFIG_URL" ; then
        echo "[FRPC] 配置文件下载失败"
        return 1
    fi

    echo "[FRPC] 启动 frpc..."
    nohup /usr/local/bin/frpc -c "$FRPC_CONFIG_FILE" > "$FRPC_LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$FRPC_PID_FILE"
    echo "[FRPC] frpc 已启动 (PID: $pid)，日志: $FRPC_LOG_FILE"
}

# 函数: 停止 frpc
stop_frpc() {
    if [ -f "$FRPC_PID_FILE" ]; then
        local pid=$(cat "$FRPC_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            rm -f "$FRPC_PID_FILE"
            echo "[FRPC] frpc 已停止"
        else
            rm -f "$FRPC_PID_FILE"
            echo "[FRPC] frpc 未运行，清理 PID 文件"
        fi
    else
        echo "[FRPC] frpc 未运行"
    fi
}

# 函数: 重启 frpc
restart_frpc() {
    stop_frpc
    sleep 1
    start_frpc
}

# 支持 --frp 参数
if [ "$1" = "--frp" ]; then
    case "$2" in
        start)   start_frpc; exit $? ;;
        stop)    stop_frpc; exit $? ;;
        restart) restart_frpc; exit $? ;;
        *)       echo "用法: $0 --frp [start|stop|restart]"; exit 1 ;;
    esac
fi

# ============================================
# Vibespace 管理菜单
# ============================================
# 支持 --commands 参数（交互式菜单）
if [ "$1" = "--commands" ]; then
    echo "============================================"
    echo "  Vibespace 管理菜单"
    echo "============================================"
    echo "  1. 上传到对象存储"
    echo "  2. 从对象存储下载并覆盖本地"
    echo "  3. 启动 frpc"
    echo "  4. 停止 frpc"
    echo "  5. 重启 frpc"
    echo "  6. 查看 frpc 状态"
    echo "  7. 查看 frpc 日志"
    echo "  8. 手动同步 (上传快照)"
    echo "  0. 退出"
    echo "============================================"
    read -p "请选择操作 [0-8]: " choice

    case "$choice" in
        1)
            echo "[操作] 上传到对象存储..."
            upload_snapshot
            ;;
        2)
            echo "[操作] 从对象存储下载并覆盖本地..."
            # 先清空 syncflag 以允许强制覆盖
            rm -f /root/syncflag.txt
            restore_snapshot
            ;;
        3)
            echo "[操作] 启动 frpc..."
            start_frpc
            ;;
        4)
            echo "[操作] 停止 frpc..."
            stop_frpc
            ;;
        5)
            echo "[操作] 重启 frpc..."
            restart_frpc
            ;;
        6)
            echo "[操作] 查看 frpc 状态..."
            if [ -f "$FRPC_PID_FILE" ] && kill -0 $(cat "$FRPC_PID_FILE") 2>/dev/null; then
                echo "[FRPC] frpc 正在运行 (PID: $(cat $FRPC_PID_FILE))"
            else
                echo "[FRPC] frpc 未运行"
            fi
            ;;
        7)
            echo "[操作] 查看 frpc 日志..."
            if [ -f "$FRPC_LOG_FILE" ]; then
                echo "--- 最近 50 行日志 ---"
                tail -50 "$FRPC_LOG_FILE"
            else
                echo "[FRPC] 日志文件不存在: $FRPC_LOG_FILE"
            fi
            ;;
        8)
            echo "[操作] 手动同步 (上传快照)..."
            upload_snapshot
            ;;
        0)
            echo "退出"
            exit 0
            ;;
        *)
            echo "无效选择: $choice"
            exit 1
            ;;
    esac
    exit 0
fi

# --- 从对象存储恢复 ---
restore_snapshot

# --- 恢复 /root 默认文件 ---
cp -an /root-defaults/root/. /root/ 2>/dev/null || true

# --- Git ---
if [ -n "$GIT_USER_NAME" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# --- SSH authorized_keys ---
if [ -n "$SSH_PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    echo "$SSH_PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

# --- SSH 密码 ---
echo "root:${ROOT_PASSWORD:-root123}" | chpasswd

# --- code-server 认证 ---
AUTH_ARGS="--auth none"
if [ -n "$CS_PASSWORD" ]; then
    export PASSWORD="$CS_PASSWORD"
    AUTH_ARGS="--auth password"
fi

# --- FRPC 内网穿透 ---
# 下载 frpc 二进制并启动
if [ -n "$FRPC_CONFIG_URL" ]; then
    wget -q -O /usr/local/bin/frpc "https://raw.githubusercontent.com/XyzenSun/vibespace/refs/heads/main/assets/app/frpc_latest"
    chmod +x /usr/local/bin/frpc
    start_frpc
fi

# --- 设置定时同步 ---
setup_periodic_sync

# --- README ---
cat > /workspace/README.md << 'READMEEOF'
# Development Environment

## 已安装的工具

### 编程语言
- Node.js / Ts / npm
- Go
- Python
- Java

### AI 工具
- CC-Switch: ClaudeCode/Codex 提供商 MCP Skils管理工具
- Claude Code: Anthropic CLI 开发工具
- CCLine: Claude Code 状态行工具
- Claude Code Router: 将Gemini/Openai格式转换为anthropic格式

### Claude Code 输出样式
- **默认**: Claude Code 默认输出样式

### 快捷命令
输入 `vibe` 即可执行: `IS_SANDBOX=1 claude --dangerously-skip-permissions`

## 环境变量
- `ROOT_PASSWORD`: SSH root 密码 (默认: root123)
- `GIT_USER_NAME`: Git 用户名
- `GIT_USER_EMAIL`: Git 邮箱
- `SSH_PUBLIC_KEY`: SSH 公钥 (用于连接容器)
- `CS_PASSWORD`: Code-Server 密码 (不设置则免密)
- `FRPC_CONFIG_URL`: frpc 配置文件下载地址

### 对象存储持久化
- `OSS_ENABLED`: 启用持久化 (true/false)
- `OSS_ENDPOINT`: S3 endpoint
- `OSS_ACCESS_KEY`: Access Key ID
- `OSS_SECRET_KEY`: Secret Access Key
- `OSS_BUCKET`: 桶名
- `OSS_REGION`: 区域 (默认 auto)
- `OSS_PROJECT`: 项目名，用于快照文件命名前缀 (默认 devbox)
- `OSS_PATHS`: 持久化目录列表 (逗号分隔)
- `OSS_KEEP_COUNT`: 保留快照数 (默认 5)
- `OSS_SYNC_INTERVAL`: 同步间隔分钟 (默认 5)
READMEEOF

# --- 启动 ---
/usr/sbin/sshd

# 启动时重启 frpc
if [ -n "$FRPC_CONFIG_URL" ] && [ -f /usr/local/bin/frpc ]; then
    restart_frpc
fi

# --- code-server (CNB 平台) ---
# CNB 会自动注入 code-server 进程，检测是否已运行
if pgrep -f '(^|/)code-server( |$)' >/dev/null || pgrep -f '/usr/lib/code-server/lib/node /usr/lib/code-server' >/dev/null; then
 echo "[code-server] 检测到 CNB 注入的进程，跳过启动"
else
 exec code-server --bind-addr 0.0.0.0:12345 $AUTH_ARGS /workspace
fi