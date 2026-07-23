# 1. 自动检测并安装 Docker / Docker Compose
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# 2. 创建并进入工作目录
mkdir -p /opt/wg-easy && cd /opt/wg-easy

# 3. 交互式获取参数 (按回车直接使用默认值)
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

# 4. 获取公网 IP
SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org)

# 5. 用官方自带的 wgpw 命令计算正确的 Hash
RAW_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "${ADMIN_PASS}" | grep 'PASSWORD_HASH=' | cut -d"'" -f2)

# 6. 关键避坑步骤：把单个 $ 转义为 $$（防止 docker-compose 损坏 Hash）
ESCAPED_HASH=$(echo "${RAW_HASH}" | sed 's/\$/\$\$/g')

# 7. 生成完美兼容的 docker-compose.yml
cat <<EOF > docker-compose.yml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    environment:
      - WG_HOST=${SERVER_IP}
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

# 8. 彻底销毁旧容器并重启
docker compose down 2>/dev/null || true
docker compose up -d

# 9. 打印部署信息
echo "=========================================="
echo "🎉 WG-Easy 部署成功！"
echo "=========================================="
echo "Web 后台地址 : http://${SERVER_IP}:${WEB_PORT}"
echo "登录密码     : ${ADMIN_PASS}"
echo "WireGuard端口: ${WG_PORT} (UDP)"
echo "=========================================="