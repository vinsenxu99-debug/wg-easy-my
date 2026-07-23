# 1. 自动检测并安装 Docker / Docker Compose
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# 2. 创建并进入工作目录
mkdir -p /opt/wg-easy && cd /opt/wg-easy

# 3. 交互式获取配置参数
read -p "请输入节点访问域名或IP [留空自动获取公网IP]: " INPUT_HOST
if [ -z "$INPUT_HOST" ]; then
    SERVER_HOST=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org)
    echo "已自动获取公网 IP: ${SERVER_HOST}"
else
    SERVER_HOST=${INPUT_HOST}
    echo "将使用域名/指定IP: ${SERVER_HOST}"
fi

read -p "请输入 Web 面板端口 [默认 50000]: " INPUT_PORT
WEB_PORT=${INPUT_PORT:-50000}

read -p "请输入 WireGuard UDP 端口 [默认 51820]: " INPUT_WG_PORT
WG_PORT=${INPUT_WG_PORT:-51820}

# 安全隐藏式输入密码
stty -echo 2>/dev/null
read -p "请输入 Web 登录密码 [默认 vinsen99]: " INPUT_PASS
stty echo 2>/dev/null
echo ""
ADMIN_PASS=${INPUT_PASS:-vinsen99}

# 4. 用官方自带的 wgpw 命令计算正确的 Hash
echo "------------------------------------------"
echo "正在生成加密 Hash..."
RAW_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "${ADMIN_PASS}" | grep 'PASSWORD_HASH=' | cut -d"'" -f2)

# 转义单 $ 为 $$ 以兼容 Docker Compose
ESCAPED_HASH=$(echo "${RAW_HASH}" | sed 's/\$/\$\$/g')

# 5. 生成 docker-compose.yml
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
      - "${WEB_PORT}:${WEB_PORT}/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
EOF

# 6. 重启容器生效
docker compose down 2>/dev/null || true
docker compose up -d

# 7. 打印部署信息
echo "=========================================="
echo "🎉 WG-Easy 部署完成！"
echo "=========================================="
echo "Web 面板地址   : http://${SERVER_HOST}:${WEB_PORT}"
echo "客户端 Endpoint: ${SERVER_HOST}:${WG_PORT}"
echo "登录密码       : ${ADMIN_PASS}"
echo "=========================================="
