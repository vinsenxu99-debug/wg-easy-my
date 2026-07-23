#!/bin/bash
set -e

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限或 sudo 执行此脚本！"
  exit 1
fi

echo "=========================================="
echo "🚀 WireGuard-Easy 智能一键部署脚本 (终极稳健版)"
echo "=========================================="

# 1. 环境清理、端口解锁与系统防火墙放行
echo "1. 正在清理系统锁并放行系统防火墙..."
killall -9 unattended-upgr apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock
rm -f /etc/nginx/sites-enabled/wg-easy 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

# 清理底层 iptables 并全量放行
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
iptables -F 2>/dev/null || true

if command -v ufw &> /dev/null; then
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw allow 51820/udp 2>/dev/null || true
fi

# 2. 交互获取配置参数
read -p "请输入节点访问域名 (留空则自动获取公网 IP): " INPUT_HOST

if [ -n "$INPUT_HOST" ]; then
    SERVER_HOST=${INPUT_HOST}
    USE_DOMAIN=true
    echo "✔ 已设置域名: ${SERVER_HOST}"
    
    read -p "请输入 Nginx HTTPS 对外访问端口 [默认 443]: " INPUT_HTTPS_PORT
    HTTPS_PORT=${INPUT_HTTPS_PORT:-443}
    
    read -p "请输入 WireGuard 后台容器内部端口 [默认 50000]: " INPUT_WEB_PORT
    WEB_PORT=${INPUT_WEB_PORT:-50000}
    BIND_IP="127.0.0.1"
else
    SERVER_HOST=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org)
    USE_DOMAIN=false
    echo "✔ 未输入域名，已自动获取公网 IP: ${SERVER_HOST}"
    
    read -p "请输入 Web 面板对外端口 [默认 50000]: " INPUT_PORT
    WEB_PORT=${INPUT_PORT:-50000}
    BIND_IP="0.0.0.0"
fi

read -p "请输入 WireGuard UDP 端口 [默认 51820]: " INPUT_WG_PORT
WG_PORT=${INPUT_WG_PORT:-51820}

# 密码输入（无回显）
stty -echo 2>/dev/null
read -p "请输入 Web 面板登录密码 [默认 vinsen99]: " INPUT_PASS
stty echo 2>/dev/null
echo ""
ADMIN_PASS=${INPUT_PASS:-vinsen99}

# 3. 安装依赖环境
echo "2. 正在检查并安装基础环境..."
apt-get update -y
apt-get install -y curl socat cron tar

if [ "$USE_DOMAIN" = true ]; then
    apt-get install -y nginx
fi

if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# 4. 创建工作及证书路径 (对标 3X-UI 路径规范)
mkdir -p /opt/wg-easy && cd /opt/wg-easy
SSL_DIR="/etc/ssl/wg-easy/${SERVER_HOST}"
mkdir -p "${SSL_DIR}"

# 5. 生成密码 Hash
echo "3. 正在计算密码 Hash..."
RAW_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "${ADMIN_PASS}" | grep 'PASSWORD_HASH=' | cut -d"'" -f2)
ESCAPED_HASH=$(echo "${RAW_HASH}" | sed 's/\$/\$\$/g')

# 6. 生成 docker-compose.yml
echo "4. 正在生成 Docker Compose 配置..."
cat <<EOF > docker-compose.yml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    environment:
      - WG_HOST=${SERVER_HOST}
      - PASSWORD_HASH=${ESCAPED_HASH}
      - WG_DEFAULT_DNS=8.8.8.8
      - WG_PORT=${WG_PORT}
      - PORT=${WEB_PORT}
    volumes:
      - ./etc_wireguard:/etc/wireguard
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${BIND_IP}:${WEB_PORT}:${WEB_PORT}/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
EOF

# 7. 启动 WG-Easy 容器
echo "5. 正在启动 WG-Easy 容器..."
docker compose down 2>/dev/null || true
docker compose up -d

# 8. 智能 SSL 签发（支持 Let's Encrypt 限流后自动降级至 ZeroSSL）
SSL_SUCCESS=false
if [ "$USE_DOMAIN" = true ]; then
    echo "6. 正在初始化 acme.sh 并申请证书..."
    
    # 安装 acme.sh
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="admin@${SERVER_HOST}"
    fi
    ACME_BIN="$HOME/.acme.sh/acme.sh"
    
    # 释放 80 端口供 Standalone 模式验证
    systemctl stop nginx 2>/dev/null || true

    # 优先尝试 Let's Encrypt 默认签发
    $ACME_BIN --set-default-ca --server letsencrypt
    if ! $ACME_BIN --issue -d "${SERVER_HOST}" --standalone --listen-v4; then
        echo "⚠️ Let's Encrypt 申请受限或失败，正在自动切至 ZeroSSL 备用 CA 重新签发..."
        $ACME_BIN --set-default-ca --server zerossl
        $ACME_BIN --register-account -m "admin@${SERVER_HOST}" 2>/dev/null || true
        $ACME_BIN --issue -d "${SERVER_HOST}" --standalone --listen-v4 --force
    fi

    # 导出证书文件到目标路径
    $ACME_BIN --install-cert -d "${SERVER_HOST}" \
        --key-file       "${SSL_DIR}/privkey.pem"  \
        --fullchain-file "${SSL_DIR}/fullchain.pem" >/dev/null 2>&1 || true

    # 严格检查公钥与私钥文件是否有效存在（非空字节）
    if [ -s "${SSL_DIR}/fullchain.pem" ] && [ -s "${SSL_DIR}/privkey.pem" ]; then
        SSL_SUCCESS=true
        echo "✔ SSL 证书签发与文件校验成功！"
    else
        SSL_SUCCESS=false
        echo "❌ SSL 证书生成失败，系统将自动降级回退至纯 HTTP 模式！"
    fi

    # 8.4 配置 Nginx 规则
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    if [ "$SSL_SUCCESS" = true ]; then
        cat <<EOF > /etc/nginx/sites-available/wg-easy
server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${SERVER_HOST};

    ssl_certificate ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:${WEB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# HTTP 80 端口自动重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_HOST};
    return 301 https://\$host:${HTTPS_PORT}\$request_uri;
}
EOF
    else
        cat <<EOF > /etc/nginx/sites-available/wg-easy
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_HOST};

    location / {
        proxy_pass http://127.0.0.1:${WEB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    fi

    ln -sf /etc/nginx/sites-available/wg-easy /etc/nginx/sites-enabled/wg-easy
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    
    # 8.5 启动 Nginx
    nginx -t
    systemctl enable --now nginx
    systemctl restart nginx

    # 8.6 挂载自动续期重载钩子
    if [ "$SSL_SUCCESS" = true ]; then
        $ACME_BIN --install-cert -d "${SERVER_HOST}" \
            --key-file       "${SSL_DIR}/privkey.pem"  \
            --fullchain-file "${SSL_DIR}/fullchain.pem" \
            --reloadcmd     "systemctl reload nginx" >/dev/null 2>&1 || true
    fi
fi

# 9. 部署完成汇总
echo "=========================================="
echo "🎉 WireGuard-Easy 部署成功！"
echo "=========================================="

if [ "$USE_DOMAIN" = true ]; then
    if [ "$SSL_SUCCESS" = true ]; then
        echo "🔒 SSL 证书状态 : 正常生效 (含自动续订)"
        echo "📂 证书公钥路径 : ${SSL_DIR}/fullchain.pem"
        echo "🔑 证书私钥路径 : ${SSL_DIR}/privkey.pem"
        echo "------------------------------------------"
        if [ "$HTTPS_PORT" = "443" ]; then
            echo "🌐 Web 面板地址 : https://${SERVER_HOST}"
        else
            echo "🌐 Web 面板地址 : https://${SERVER_HOST}:${HTTPS_PORT}"
        fi
    else
        echo "❌ SSL 证书状态 : 申请失败 (已降级回退至 HTTP)"
        echo "🌐 Web 面板地址 : http://${SERVER_HOST}"
    fi
else
    echo "🌐 Web 面板地址 : http://${SERVER_HOST}:${WEB_PORT}"
fi

echo "🚀 客户端 Endpoint: ${SERVER_HOST}:${WG_PORT}"
echo "🔑 Web 面板密码  : ${ADMIN_PASS}"
echo "=========================================="