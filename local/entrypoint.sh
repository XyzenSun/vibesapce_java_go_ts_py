#!/bin/bash
set -e

# ============================================
# Vibespace 管理菜单
# ============================================
# 支持 --commands 参数（交互式菜单）
if [ "$1" = "--commands" ]; then
    echo "============================================"
    echo "  Vibespace 管理菜单"
    echo "============================================"
    echo "  0. 退出"
    echo "============================================"
    read -p "请选择操作 [0-8]: " choice

    case "$choice" in
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
READMEEOF

# --- 启动 ---
/usr/sbin/sshd

exec /usr/sbin/sshd -D