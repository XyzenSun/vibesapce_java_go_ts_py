FROM ubuntu:24.04

ENV LANG=C.UTF-8 \
    LANGUAGE=C.UTF-8 \
    GOLANG_VERSION=1.23.6 \
    GOPATH=/root/go \
    PATH=$PATH:/usr/local/go/bin:/root/go/bin:/root/.local/bin

# 层1: 系统包 + 基础工具
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates cron curl git nano openjdk-21-jdk openssh-client openssh-server python3 python3-pip rclone unzip vim wget zstd maven \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get autoremove -y \
    && apt-get clean

# 层2: 语言运行时
RUN wget -q https://go.dev/dl/go${GOLANG_VERSION}.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf go${GOLANG_VERSION}.linux-amd64.tar.gz \
    && rm -f go${GOLANG_VERSION}.linux-amd64.tar.gz \
    && apt-get update && apt-get install -y --no-install-recommends python3-venv && apt-get clean

# 层3: 全局 npm 包
RUN npm install -g typescript ts-node \
    && npm cache clean --force

# 层4: 语言开发工具
RUN go install -v golang.org/x/tools/gopls@latest \
    && go install -v github.com/go-delve/delve/cmd/dlv@latest \
    && go install -v honnef.co/go/tools/cmd/staticcheck@latest \
    && go clean -modcache \
    && go clean -cache

# 层5a: 安装 code-server
RUN curl -fsSL https://raw.githubusercontent.com/coder/code-server/main/install.sh | sh \
    && rm -rf /tmp/*

# 层5b: code-server 扩展
RUN code-server --install-extension MS-CEINTL.vscode-language-pack-zh-hans \
    && code-server --install-extension GitHub.github-vscode-theme \
    && code-server --install-extension DavidAnson.vscode-markdownlint \
    && code-server --install-extension g2developer.browser-in-vscode \
    && code-server --install-extension saltcoreyan.json-format-sortcore \
    && code-server --install-extension redhat.vscode-yaml \
    && code-server --install-extension Anthropic.claude-code \
    && code-server --install-extension golang.go \
    && code-server --install-extension eamodio.gitlens \
    && code-server --install-extension RooVeterinaryInc.roo-cline \
    && code-server --install-extension streetsidesoftware.code-spell-checker \
    && code-server --install-extension aminer.codegeex \
    && code-server --install-extension ms-python.python \
    && code-server --install-extension Pleiades.java-extension-pack-jdk \
    && rm -rf /tmp/* /root/.cache

# 层6: AI 工具
RUN npm install -g @anthropic-ai/claude-code@2.1.71 @cometix/ccline @musistudio/claude-code-router \
    && npm cache clean --force \
    && CC_SWITCH_FORCE=1 curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash \
    && echo '#!/bin/bash' > /usr/local/bin/vibe \
    && echo 'IS_SANDBOX=1 claude --dangerously-skip-permissions "$@"' >> /usr/local/bin/vibe \
    && chmod +x /usr/local/bin/vibe

# 层6b: Claude Code 配置
RUN mkdir -p ~/.claude \
    && printf '%s' '{"statusLine":{"type":"command","command":"ccline","padding":0},"env":{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","DISABLE_AUTOUPDATER":"1"}}' > ~/.claude/settings.json \
    && mkdir -p ~/.claude/output-styles \
    && (claude config set outputStyle "default" -g 2>/dev/null || true)

# 层7: SSH 配置
RUN mkdir -p /run/sshd \
    && sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 备份 /root，防止 volume 挂载覆盖镜像内文件
RUN mkdir /root-defaults && cp -a /root /root-defaults

# 创建 vibespace 管理命令，禁用 Git commit/tag 签名
RUN echo '#!/bin/bash' > /usr/local/bin/vibespace \
    && echo '/usr/local/bin/entrypoint.sh --commands' >> /usr/local/bin/vibespace \
    && chmod +x /usr/local/bin/vibespace \
    && git config --system tag.gpgSign false \
    && git config --system commit.gpgsign false

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
EXPOSE 12345 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
