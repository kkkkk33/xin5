#!/bin/bash
set -e

# ========== 配置区 ==========
TG_TOKEN="8526087156:AAHR5forb44MA061r0zgcPMiGtkkxHD5K6o"
TG_CHAT_ID="6303873752"

SNI_DOMAIN="www.microsoft.com"
TLS_PWD="CDSA4fsdfds9fads49"
LISTEN_PORT=10111
SOCKS_PORT=1080

# ⭐ 直接在这里修改你的指纹类型 (可选: chrome, edge, firefox, safari, randomized) ⭐
TLS_FINGERPRINT="chrome"
# ============================

echo -e "-> 已选择指纹模式: \033[32m${TLS_FINGERPRINT}\033[0m\n"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. 检查 Docker ──────────────────────────────
log "检查 Docker 环境..."
if ! command -v docker &>/dev/null; then
    warn "Docker 未安装，正在安装..."
    apt-get update -qq && apt-get install -y -qq docker.io
    systemctl start docker && systemctl enable docker
fi
docker info &>/dev/null || err "Docker 守护进程未运行"

# ── 2. 清理旧容器 ───────────────────────────────
log "清理旧容器..."
docker rm -f sing-box shadow-tls ja3proxy ss-rust ss-local 2>/dev/null || true
sleep 1
fuser -k ${LISTEN_PORT}/tcp 2>/dev/null || true
fuser -k ${SOCKS_PORT}/tcp  2>/dev/null || true
sleep 1

# ── 3. 生成代理配置文件 ─────────────────────────
log "生成代理配置文件..."
mkdir -p ./singbox_config

cat <<EOF > ./singbox_config/config.json
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": ${SOCKS_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out",
      "tls": {
        "enabled": true,
        "utls": {
          "enabled": true,
          "fingerprint": "${TLS_FINGERPRINT}"
        }
      }
    }
  ]
}
EOF

# ── 4. 启动 Sing-Box 服务 ────────────────────────
log "启动 Sing-Box 核心代理..."
docker run -d \
    --name sing-box \
    --restart always \
    --network host \
    -v $(pwd)/singbox_config:/etc/sing-box \
    ghcr.io/sagernet/sing-box:latest \
    run -c /etc/sing-box/config.json

log "等待 Sing-Box 启动..."
for i in $(seq 1 15); do
    if ss -tlnp 2>/dev/null | grep -q "${SOCKS_PORT}"; then
        log "Sing-Box 已在本地监听 ${SOCKS_PORT} (SOCKS5)"
        break
    fi
    sleep 1
done

# ── 5. 启动外层 Shadow-TLS ─────────────────────
log "启动 Shadow-TLS 服务端..."
docker run -d \
    --name shadow-tls \
    --restart always \
    --network host \
    --entrypoint shadow-tls \
    ghcr.io/ihciah/shadow-tls:v0.2.23 \
    --v3 server \
    --listen "0.0.0.0:${LISTEN_PORT}" \
    --server "127.0.0.1:${SOCKS_PORT}" \
    --tls "${SNI_DOMAIN}:443" \
    --password "${TLS_PWD}"

sleep 2

# ── 6. 验证容器状态 ────────────────────────────
log "验证容器运行状态..."
for c in sing-box shadow-tls; do
    s=$(docker inspect -f '{{.State.Status}}' $c 2>/dev/null)
    if [ "$s" != "running" ]; then
        warn "$c 状态异常: $s"
        docker logs $c 2>&1 | tail -15
    else
        log "$c 运行正常"
    fi
done

# ── 7. 获取公网 IP ─────────────────────────────
SERVER_IP=$(curl -s --max-time 10 ipv4.icanhazip.com || \
            curl -s --max-time 10 api.ipify.org)
[ -z "$SERVER_IP" ] && err "无法获取公网 IP"
log "服务器 IP: ${SERVER_IP}"

# ── 8. 生成小火箭节点链接 ──────────────────────
STLS_B64=$(python3 -c "
import base64, json
obj = {'version': '3', 'host': '${SNI_DOMAIN}', 'password': '${TLS_PWD}'}
print(base64.urlsafe_b64encode(json.dumps(obj, separators=(',',':')).encode()).decode().rstrip('='))
")

SS_LINK="socks5://127.0.0.1:${SOCKS_PORT}?shadow-tls=${STLS_B64}&host=${SNI_DOMAIN}#TLS_${TLS_FINGERPRINT}_${SERVER_IP}"

# ── 9. 推送 Telegram + 输出汇总 ─────────────────
curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=🔗 节点部署成功 (出站指纹: ${TLS_FINGERPRINT}):
服务器 IP: ${SERVER_IP}
监听端口: ${LISTEN_PORT}" >/dev/null

echo ""
echo "══════════════════════════════════════════════"
echo "  部署完成！出站指纹已设置为: ${TLS_FINGERPRINT}"
echo "══════════════════════════════════════════════"
echo "  服务器 IP      : ${SERVER_IP}"
echo "  监听端口      : ${LISTEN_PORT}"
echo "  出站 TLS 指纹  : ${TLS_FINGERPRINT}"
echo "══════════════════════════════════════════════"
echo "  节点链接:"
echo "  ${SS_LINK}"
echo "══════════════════════════════════════════════"
docker ps --format "table {{.Names}}\t{{.Status}}"