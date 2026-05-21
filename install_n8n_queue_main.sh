#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

N8N_DIR="/home/n8n"
SKIP_DOCKER=false
DOMAIN=""
MAIN_PUBLIC_HOST=""
N8N_BASE_IMAGE="ghcr.io/n8n-io/n8n"
N8N_VERSION="latest"
POSTGRES_PUBLIC_PORT="5432"
REDIS_PUBLIC_PORT="6379"
LOCAL_WORKER_CONCURRENCY="5"
AUTO_UPDATE=""

show_help() {
    cat <<'EOF'
Cách dùng: bash install_n8n_queue_main.sh [tùy chọn]

Tùy chọn:
  -d, --dir DIR           Thư mục cài đặt (mặc định: /home/n8n)
  -s, --skip-docker       Bỏ qua bước cài Docker
      --domain DOMAIN     Domain n8n, ví dụ n8n.example.com
      --main-host HOST    Host/IP public để worker kết nối Postgres/Redis, mặc định dùng domain đã nhập
      --n8n-base-image IMAGE
                          Image gốc của n8n (mặc định: ghcr.io/n8n-io/n8n)
      --n8n-version TAG   Tag/version n8n (mặc định: latest)
  -h, --help              Hiển thị trợ giúp
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            N8N_DIR="$2"
            shift 2
            ;;
        -s|--skip-docker)
            SKIP_DOCKER=true
            shift
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --main-host)
            MAIN_PUBLIC_HOST="$2"
            shift 2
            ;;
        --n8n-base-image)
            N8N_BASE_IMAGE="$2"
            shift 2
            ;;
        --n8n-version)
            N8N_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Tùy chọn không hợp lệ: $1"
            show_help
            exit 1
            ;;
    esac
done

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    echo "LỖI: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Vui lòng chạy script bằng quyền root."
    fi
}

prompt_required() {
    local prompt="$1"
    local value=""
    while [[ -z "$value" ]]; do
        printf '%s: ' "$prompt" >&2
        read -r value
    done
    printf '%s' "$value"
}

prompt_secret() {
    local prompt="$1"
    local value=""
    while [[ -z "$value" ]]; do
        printf '%s: ' "$prompt" >&2
        read -r -s value
        echo >&2
    done
    printf '%s' "$value"
}

choose_secret() {
    local label="$1"
    local bytes="$2"
    if prompt_yes_no "Tự động tạo $label" "y"; then
        openssl rand -hex "$bytes"
    else
        prompt_secret "Nhập $label"
    fi
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value=""
    printf '%s [%s]: ' "$prompt" "$default" >&2
    read -r value
    printf '%s' "${value:-$default}"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer=""
    local suffix="[y/N]"
    if [[ "$default" == "y" ]]; then
        suffix="[Y/n]"
    fi
    printf '%s %s: ' "$prompt" "$suffix" >&2
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

get_public_ip() {
    curl -4 -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

validate_port() {
    local name="$1"
    local port="$2"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        die "$name phải là TCP port hợp lệ từ 1 đến 65535."
    fi
}

validate_positive_int() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
        die "$name phải là số nguyên dương."
    fi
}

create_swap() {
    log "Kiểm tra swap"
    local current_swap
    current_swap="$(swapon --show | wc -l)"
    if [[ "$current_swap" -le 1 ]]; then
        log "Tạo swap 2G tại /swapfile"
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        if ! grep -q '^vm.swappiness=' /etc/sysctl.conf; then
            echo 'vm.swappiness=10' >> /etc/sysctl.conf
        fi
        sysctl -p >/dev/null || true
    else
        log "Swap đã tồn tại"
    fi
}

install_base_packages() {
    log "Cài các gói cơ bản"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        apt-transport-https \
        ca-certificates \
        cron \
        curl \
        dnsutils \
        gnupg \
        lsb-release \
        openssl \
        software-properties-common \
        unzip \
        zip
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
}

install_docker() {
    if [[ "$SKIP_DOCKER" == "true" ]]; then
        log "Bỏ qua bước cài Docker"
        return
    fi

    log "Cài Docker và Docker Compose plugin"
    install -m 0755 -d /etc/apt/keyrings

    local os_id
    local codename
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID}"
    codename="${VERSION_CODENAME:-$(lsb_release -cs)}"

    if [[ "$os_id" != "ubuntu" && "$os_id" != "debian" ]]; then
        die "Script này chỉ hỗ trợ VPS Ubuntu/Debian dùng apt. Hệ điều hành phát hiện: $os_id"
    fi

    curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_id} ${codename} stable
EOF

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin

    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true

    docker version >/dev/null || die "Docker chưa hoạt động đúng."
    docker compose version >/dev/null || die "Docker Compose plugin chưa hoạt động đúng."
}

compose_exec() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    elif docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        die "Không tìm thấy Docker Compose."
    fi
}

check_domain() {
    local domain="$1"
    local server_ip
    local domain_ips
    server_ip="$(get_public_ip)"
    domain_ips="$(dig +short A "$domain" || true)"

    if echo "$domain_ips" | grep -Fxq "$server_ip"; then
        log "Domain $domain đã trỏ về server này ($server_ip)"
        return
    fi

    echo
    echo "Domain chưa trỏ đúng về server này."
    echo "  Domain: $domain"
    echo "  IPv4 server này: $server_ip"
    echo "  Bản ghi DNS A:"
    while IFS= read -r ip; do
        echo "    $ip"
    done <<< "$domain_ips"
    echo
    if ! prompt_yes_no "Vẫn tiếp tục" "n"; then
        die "Hãy trỏ DNS về VPS này rồi chạy lại script."
    fi
}

ensure_install_dir() {
    if [[ -f "$N8N_DIR/docker-compose.yml" || -f "$N8N_DIR/.env" ]]; then
        echo
        echo "Đã tìm thấy file n8n queue trong $N8N_DIR."
        echo "Tiếp tục có thể ghi đè docker-compose.yml, .env và các script hỗ trợ."
        read -r -p "Nhập YES để tiếp tục: " confirm
        [[ "$confirm" == "YES" ]] || die "Đã hủy."

        if [[ -f "$N8N_DIR/docker-compose.yml" ]]; then
            log "Dừng stack n8n hiện tại trước khi ghi lại file"
            (cd "$N8N_DIR" && compose_exec down --remove-orphans) || true
        fi
    fi

    mkdir -p \
        "$N8N_DIR/backups" \
        "$N8N_DIR/files/temp" \
        "$N8N_DIR/my-files"

    chown -R 1000:1000 \
        "$N8N_DIR/files" \
        "$N8N_DIR/my-files"

    chmod 750 "$N8N_DIR"
}

write_project_files() {
    local postgres_password="$1"
    local redis_password="$2"
    local encryption_key="$3"

    log "Ghi file cấu hình n8n queue main"

    cat > "$N8N_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=n8n
DOMAIN=${DOMAIN}
MAIN_PUBLIC_HOST=${MAIN_PUBLIC_HOST}
N8N_BASE_IMAGE=${N8N_BASE_IMAGE}
N8N_VERSION=${N8N_VERSION}
N8N_ENCRYPTION_KEY=${encryption_key}
POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_PUBLIC_PORT=${POSTGRES_PUBLIC_PORT}
REDIS_PASSWORD=${redis_password}
REDIS_PUBLIC_PORT=${REDIS_PUBLIC_PORT}
LOCAL_WORKER_CONCURRENCY=${LOCAL_WORKER_CONCURRENCY}
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
EOF
    chmod 600 "$N8N_DIR/.env"

    cat > "$N8N_DIR/worker-connection.env" <<EOF
# Dùng các giá trị này khi chạy install_n8n_queue_worker.sh.
MAIN_HOST=${MAIN_PUBLIC_HOST}
POSTGRES_HOST=${MAIN_PUBLIC_HOST}
POSTGRES_PORT=${POSTGRES_PUBLIC_PORT}
POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${postgres_password}
REDIS_HOST=${MAIN_PUBLIC_HOST}
REDIS_PORT=${REDIS_PUBLIC_PORT}
REDIS_PASSWORD=${redis_password}
N8N_ENCRYPTION_KEY=${encryption_key}
N8N_BASE_IMAGE=${N8N_BASE_IMAGE}
N8N_VERSION=${N8N_VERSION}
EOF
    chmod 600 "$N8N_DIR/worker-connection.env"

    cat > "$N8N_DIR/Dockerfile" <<'EOF'
ARG N8N_BASE_IMAGE=ghcr.io/n8n-io/n8n
ARG N8N_VERSION=latest

FROM mwader/static-ffmpeg:7.1 AS ffmpeg_source

FROM ${N8N_BASE_IMAGE}:${N8N_VERSION}

USER root

COPY --from=ffmpeg_source /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg_source /ffprobe /usr/local/bin/ffprobe

RUN if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache bash ca-certificates; \
    elif command -v apt-get >/dev/null 2>&1; then \
        apt-get update && apt-get install -y --no-install-recommends bash ca-certificates && \
        rm -rf /var/lib/apt/lists/*; \
    fi && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    mkdir -p /files/temp /home/my-files && \
    chown -R 1000:1000 /files /home/my-files /home/node && \
    ffmpeg -version | head -n 1 && \
    ffprobe -version | head -n 1

USER node
EOF

    cat > "$N8N_DIR/docker-compose.yml" <<'EOF'
x-n8n-environment: &n8n-environment
  NODE_ENV: production
  GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
  TZ: ${GENERIC_TIMEZONE}
  EXECUTIONS_MODE: queue
  OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS: "true"
  N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
  DB_TYPE: postgresdb
  DB_POSTGRESDB_HOST: postgres
  DB_POSTGRESDB_PORT: "5432"
  DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
  DB_POSTGRESDB_USER: ${POSTGRES_USER}
  DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
  QUEUE_BULL_REDIS_HOST: redis
  QUEUE_BULL_REDIS_PORT: "6379"
  QUEUE_BULL_REDIS_PASSWORD: ${REDIS_PASSWORD}
  N8N_DEFAULT_BINARY_DATA_MODE: database
  N8N_DIAGNOSTICS_ENABLED: "false"
  N8N_HIRING_BANNER_ENABLED: "false"
  N8N_RESTRICT_FILE_ACCESS_TO: /home/node;/home/my-files;/files;/tmp
  NODES_EXCLUDE: "[]"
  NODE_FUNCTION_ALLOW_BUILTIN: child_process,path,fs,util
  NODE_FUNCTION_ALLOW_EXTERNAL: "*"
  N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE: "true"
  EXECUTIONS_DATA_PRUNE: "true"
  EXECUTIONS_DATA_MAX_AGE: "168"
  EXECUTIONS_DATA_PRUNE_MAX_COUNT: "5000"
  N8N_EXECUTIONS_DATA_MAX_SIZE: "304857600"

x-n8n-build: &n8n-build
  image: n8n-custom:${N8N_VERSION}
  build:
    context: .
    dockerfile: Dockerfile
    args:
      N8N_BASE_IMAGE: ${N8N_BASE_IMAGE}
      N8N_VERSION: ${N8N_VERSION}
  restart: always
  user: "1000:1000"
  networks:
    - n8n_network

services:
  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: always
    environment:
      TZ: ${GENERIC_TIMEZONE}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "${POSTGRES_PUBLIC_PORT}:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - n8n_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \"$${POSTGRES_USER}\" -d \"$${POSTGRES_DB}\""]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: always
    command: ["sh", "-c", "redis-server --appendonly yes --requirepass \"$${REDIS_PASSWORD}\""]
    environment:
      TZ: ${GENERIC_TIMEZONE}
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    ports:
      - "${REDIS_PUBLIC_PORT}:6379"
    volumes:
      - redis_data:/data
    networks:
      - n8n_network
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$${REDIS_PASSWORD}\" ping | grep PONG"]
      interval: 10s
      timeout: 5s
      retries: 10

  n8n-main:
    <<: *n8n-build
    container_name: n8n-main
    environment:
      <<: *n8n-environment
      N8N_HOST: ${DOMAIN}
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${DOMAIN}/
    volumes:
      - n8n_data:/home/node/.n8n
      - ./files:/files
      - ./my-files:/home/my-files
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "node -e \"const http=require('http');const req=http.get('http://127.0.0.1:5678/healthz',res=>process.exit(res.statusCode===200?0:1));req.on('error',()=>process.exit(1));req.setTimeout(3000,()=>process.exit(1));\""]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 180s

  n8n-worker:
    <<: *n8n-build
    container_name: n8n-worker
    command: worker --concurrency=${LOCAL_WORKER_CONCURRENCY}
    environment:
      <<: *n8n-environment
      QUEUE_HEALTH_CHECK_ACTIVE: "false"
    volumes:
      - worker_data:/home/node/.n8n
      - ./files:/files
      - ./my-files:/home/my-files
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - n8n_network

volumes:
  postgres_data:
    name: postgres_data
  redis_data:
    name: redis_data
  n8n_data:
    name: n8n_data
  worker_data:
    name: worker_data
  caddy_data:
    name: caddy_data
  caddy_config:
    name: caddy_config

networks:
  n8n_network:
    name: n8n_network
    driver: bridge
EOF

    cat > "$N8N_DIR/Caddyfile" <<EOF
${DOMAIN} {
    reverse_proxy n8n-main:5678
}
EOF

    cat > "$N8N_DIR/show-worker-config.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG_FILE="$N8N_DIR/worker-connection.env"
if [[ ! -f "\$CONFIG_FILE" ]]; then
    echo "Không tìm thấy \$CONFIG_FILE"
    exit 1
fi

echo "Dùng các giá trị này khi chạy install_n8n_queue_worker.sh:"
echo
cat "\$CONFIG_FILE"
echo
echo "Lưu ý bảo mật: ai có các giá trị này có thể truy cập database/queue n8n và giải mã credentials."
EOF
    chmod 700 "$N8N_DIR/show-worker-config.sh"

    cat > "$N8N_DIR/backup-n8n.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N8N_DIR="$N8N_DIR"
ENV_FILE="\$N8N_DIR/.env"
[[ -f "\$ENV_FILE" ]] || { echo "Không tìm thấy \$ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
set -a
. "\$ENV_FILE"
set +a

BACKUP_DATE="\$(date '+%Y%m%d_%H%M%S')"
WORK_DIR="\$N8N_DIR/backups/tmp_\$BACKUP_DATE"
ARCHIVE="\$N8N_DIR/backups/n8n_queue_backup_\$BACKUP_DATE.zip"
mkdir -p "\$WORK_DIR"

    echo "Tạo bản dump Postgres..."
    docker exec -e PGPASSWORD="\$POSTGRES_PASSWORD" postgres \\
    pg_dump -U "\$POSTGRES_USER" "\$POSTGRES_DB" > "\$WORK_DIR/postgres.sql"

cp "\$N8N_DIR/.env" "\$WORK_DIR/.env"
cp "\$N8N_DIR/worker-connection.env" "\$WORK_DIR/worker-connection.env"
cp "\$N8N_DIR/docker-compose.yml" "\$WORK_DIR/docker-compose.yml"
cp "\$N8N_DIR/Dockerfile" "\$WORK_DIR/Dockerfile"
cp "\$N8N_DIR/Caddyfile" "\$WORK_DIR/Caddyfile"

(cd "\$WORK_DIR" && zip -r "\$ARCHIVE" . >/dev/null)
rm -rf "\$WORK_DIR"
find "\$N8N_DIR/backups" -name 'n8n_queue_backup_*.zip' -mtime +7 -delete

echo "Đã tạo backup: \$ARCHIVE"
EOF
    chmod 700 "$N8N_DIR/backup-n8n.sh"

    cat > "$N8N_DIR/restart-n8n.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N8N_DIR="$N8N_DIR"
cd "\$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    compose_exec() { docker-compose "\$@"; }
else
    compose_exec() { docker compose "\$@"; }
fi
compose_exec restart n8n-main n8n-worker caddy
docker ps --filter 'name=postgres'
docker ps --filter 'name=redis'
docker ps --filter 'name=n8n'
docker ps --filter 'name=caddy'
EOF
    chmod 700 "$N8N_DIR/restart-n8n.sh"

    cat > "$N8N_DIR/update-n8n.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N8N_DIR="$N8N_DIR"
cd "\$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    compose_exec() { docker-compose "\$@"; }
else
    compose_exec() { docker compose "\$@"; }
fi

# shellcheck disable=SC1090
set -a
. "\$N8N_DIR/.env"
set +a

echo "Tạo backup trước khi cập nhật..."
"\$N8N_DIR/backup-n8n.sh"

echo "Tải image gốc n8n: \$N8N_BASE_IMAGE:\$N8N_VERSION"
docker pull "\$N8N_BASE_IMAGE:\$N8N_VERSION" || true

echo "Build lại và khởi động stack..."
compose_exec build --pull --no-cache
compose_exec up -d postgres redis
compose_exec up -d n8n-main n8n-worker || true

waited=0
max_wait=600
while (( waited < max_wait )); do
    if docker inspect --format='{{.State.Health.Status}}' n8n-main 2>/dev/null | grep -q "healthy"; then
        break
    fi
    sleep 5
    waited=$((waited + 5))
    echo "Đang chờ n8n-main healthy... \${waited}s/\${max_wait}s"
done

if ! docker inspect --format='{{.State.Health.Status}}' n8n-main 2>/dev/null | grep -q "healthy"; then
    echo "n8n-main chưa healthy sau \${max_wait}s. Kiểm tra logs:"
    echo "  cd \$N8N_DIR && docker compose logs n8n-main"
    exit 1
fi

compose_exec up -d caddy
docker image prune -f
echo "Cập nhật hoàn tất."
EOF
    chmod 700 "$N8N_DIR/update-n8n.sh"
}

configure_auto_update() {
    if [[ "$AUTO_UPDATE" == "yes" ]]; then
        local cron_job="0 */12 * * * $N8N_DIR/update-n8n.sh >> $N8N_DIR/update.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-n8n.sh" || true; echo "$cron_job") | crontab -
        log "Đã bật tự động cập nhật mỗi 12 giờ"
    else
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-n8n.sh" || true) | crontab - || true
        log "Đã tắt tự động cập nhật"
    fi
}

wait_for_main() {
    local max_wait=600
    local waited=0
    log "Chờ n8n-main healthy"
    while (( waited < max_wait )); do
        if docker inspect --format='{{.State.Health.Status}}' n8n-main 2>/dev/null | grep -q "healthy"; then
            log "n8n-main đã healthy"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        echo "Đang chờ... ${waited}s/${max_wait}s"
    done
    echo "n8n-main chưa healthy sau ${max_wait}s. Kiểm tra logs:"
    echo "  cd $N8N_DIR && docker compose logs n8n-main"
    return 1
}

start_stack() {
    log "Khởi động Postgres và Redis"
    compose_exec up -d postgres redis

    log "Khởi động n8n-main và n8n-worker"
    compose_exec up -d n8n-main n8n-worker || true

    wait_for_main

    log "Khởi động Caddy"
    compose_exec up -d caddy
}

wait_for_https_ssl() {
    local domain="$1"
    local max_wait=300
    local waited=0
    local status=""

    log "Chờ Caddy cấp SSL và HTTPS sẵn sàng cho https://${domain}"
    while (( waited < max_wait )); do
        if openssl s_client -connect "${domain}:443" -servername "$domain" -verify_hostname "$domain" </dev/null >/tmp/n8n_ssl_check.log 2>&1; then
            status="$(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://${domain}/" 2>/dev/null || true)"
            if [[ "$status" =~ ^(200|301|302|307|308)$ ]]; then
                log "HTTPS/SSL đã sẵn sàng cho https://${domain} (HTTP $status)"
                rm -f /tmp/n8n_ssl_check.log
                return 0
            fi
        fi

        sleep 5
        waited=$((waited + 5))
        echo "Đang chờ SSL... ${waited}s/${max_wait}s"
    done

    echo "Caddy chưa sẵn sàng SSL sau ${max_wait}s."
    echo "Bạn có thể kiểm tra logs:"
    echo "  cd $N8N_DIR && docker compose logs caddy"
    echo "Chi tiết kiểm tra SSL gần nhất:"
    sed 's/^/  /' /tmp/n8n_ssl_check.log 2>/dev/null || true
    return 1
}

main() {
    require_root
    install_base_packages
    create_swap

    if [[ -z "$DOMAIN" ]]; then
        DOMAIN="$(prompt_required "Nhập domain hoặc subdomain của n8n")"
    fi
    check_domain "$DOMAIN"

    if [[ -z "$MAIN_PUBLIC_HOST" ]]; then
        MAIN_PUBLIC_HOST="$(prompt_default "Nhập host/IP public để worker kết nối Postgres/Redis, Enter để dùng domain" "$DOMAIN")"
    fi

    POSTGRES_PUBLIC_PORT="$(prompt_default "Port Postgres cho worker" "$POSTGRES_PUBLIC_PORT")"
    REDIS_PUBLIC_PORT="$(prompt_default "Port Redis cho worker" "$REDIS_PUBLIC_PORT")"
    LOCAL_WORKER_CONCURRENCY="$(prompt_default "Số luồng worker local" "$LOCAL_WORKER_CONCURRENCY")"
    N8N_BASE_IMAGE="$(prompt_default "Image gốc của n8n" "$N8N_BASE_IMAGE")"
    N8N_VERSION="$(prompt_default "Tag image n8n" "$N8N_VERSION")"

    validate_port "Port Postgres" "$POSTGRES_PUBLIC_PORT"
    validate_port "Port Redis" "$REDIS_PUBLIC_PORT"
    validate_positive_int "Số luồng worker local" "$LOCAL_WORKER_CONCURRENCY"

    if prompt_yes_no "Bật tự động cập nhật mỗi 12 giờ? Khuyến nghị: không, cập nhật main/worker cùng lúc" "n"; then
        AUTO_UPDATE="yes"
    else
        AUTO_UPDATE="no"
    fi

    echo
    echo "CẢNH BÁO BẢO MẬT:"
    echo "Cấu hình này mở port Postgres $POSTGRES_PUBLIC_PORT và Redis $REDIS_PUBLIC_PORT để worker remote kết nối."
    echo "Mật khẩu tạo ra đủ mạnh, nhưng firewall/VPN/private network vẫn an toàn hơn nếu dùng được."
    if ! prompt_yes_no "Tiếp tục với chế độ host/password" "y"; then
        die "Đã hủy."
    fi

    install_docker
    ensure_install_dir

    local postgres_password
    local redis_password
    local encryption_key
    postgres_password="$(choose_secret "mật khẩu Postgres" 24)"
    redis_password="$(choose_secret "mật khẩu Redis" 24)"
    encryption_key="$(choose_secret "N8N_ENCRYPTION_KEY" 32)"

    write_project_files "$postgres_password" "$redis_password" "$encryption_key"

    log "Build image n8n custom"
    cd "$N8N_DIR"
    compose_exec build --pull

    log "Khởi động stack n8n queue"
    start_stack
    local ssl_ready="no"
    if wait_for_https_ssl "$DOMAIN"; then
        ssl_ready="yes"
    fi
    configure_auto_update

    echo
    echo "======================================================================"
    if [[ "$ssl_ready" == "yes" ]]; then
        echo "Đã cài xong n8n queue main"
    else
        echo "Stack n8n đã chạy, nhưng SSL chưa xác nhận sẵn sàng"
    fi
    echo "======================================================================"
    if [[ "$ssl_ready" == "yes" ]]; then
        echo "URL n8n: https://${DOMAIN}"
    else
        echo "URL n8n sẽ dùng sau khi SSL sẵn sàng: https://${DOMAIN}"
        echo "Kiểm tra Caddy: cd $N8N_DIR && docker compose logs caddy"
    fi
    echo "Thư mục cài đặt: $N8N_DIR"
    echo "Cấu hình worker: $N8N_DIR/worker-connection.env"
    echo
    echo "Xem thông tin kết nối worker:"
    echo "  $N8N_DIR/show-worker-config.sh"
    echo
    echo "Lệnh hữu ích:"
    echo "  cd $N8N_DIR && docker compose logs -f"
    echo "  $N8N_DIR/restart-n8n.sh"
    echo "  $N8N_DIR/backup-n8n.sh"
    echo "  $N8N_DIR/update-n8n.sh"
    echo
    echo "Các secret quan trọng đã được ghi vào:"
    echo "  $N8N_DIR/.env"
    echo "  $N8N_DIR/worker-connection.env"
    echo "======================================================================"
}

main "$@"
