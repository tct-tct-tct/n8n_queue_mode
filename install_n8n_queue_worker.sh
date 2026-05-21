#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ======================================================================
# CẤU HÌNH NHẬP SẴN CHO WORKER
# Điền các giá trị lấy từ /home/n8n/show-worker-config.sh trên VPS main.
# Biến nào để trống thì script sẽ hỏi đúng biến đó khi chạy.
# MAIN_HOST có thể là IP hoặc domain main, dùng làm mặc định cho Postgres/Redis.
# ======================================================================
N8N_DIR="/home/n8n-worker"
SKIP_DOCKER=false
MAIN_HOST=""

POSTGRES_HOST=""
POSTGRES_PORT="5432"
POSTGRES_DB="n8n"
POSTGRES_USER="n8n"
POSTGRES_PASSWORD=""

REDIS_HOST=""
REDIS_PORT="6379"
REDIS_PASSWORD=""

N8N_ENCRYPTION_KEY=""
N8N_BASE_IMAGE="ghcr.io/n8n-io/n8n"
N8N_VERSION="latest"
WORKER_CONCURRENCY="5"

# yes/no. Để trống nếu muốn script hỏi khi chạy.
AUTO_UPDATE="no"

show_help() {
    cat <<'EOF'
Cách dùng: bash install_n8n_queue_worker.sh [tùy chọn]

Tùy chọn:
  -d, --dir DIR              Thư mục cài đặt (mặc định: /home/n8n-worker)
  -s, --skip-docker          Bỏ qua bước cài Docker
      --main-host HOST       Host/IP main để kết nối Postgres và Redis
      --n8n-base-image IMAGE Image gốc của n8n (mặc định: ghcr.io/n8n-io/n8n)
      --n8n-version TAG      Tag/version n8n (mặc định: latest)
  -h, --help                 Hiển thị trợ giúp

Phần lớn giá trị sẽ được hỏi khi chạy. Copy từ:
  /home/n8n/show-worker-config.sh
trên VPS main.
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
        --main-host)
            MAIN_HOST="$2"
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
        gnupg \
        lsb-release \
        openssl \
        postgresql-client \
        redis-tools \
        software-properties-common
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

test_tcp() {
    local host="$1"
    local port="$2"
    local name="$3"
    log "Kiểm tra kết nối TCP tới $name tại $host:$port"
    if timeout 8 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
        log "Kết nối TCP tới $name OK"
        return
    fi
    die "Không kết nối được tới $name tại $host:$port. Kiểm tra firewall main, host, port và security group của nhà cung cấp VPS."
}

test_postgres_auth() {
    log "Kiểm tra đăng nhập Postgres bằng user $POSTGRES_USER"
    if PGPASSWORD="$POSTGRES_PASSWORD" psql \
        "host=$POSTGRES_HOST port=$POSTGRES_PORT dbname=$POSTGRES_DB user=$POSTGRES_USER connect_timeout=8 sslmode=prefer" \
        -Atqc "SELECT 1" >/dev/null 2>&1; then
        log "Đăng nhập Postgres OK"
        return
    fi
    die "Đăng nhập Postgres thất bại. Kiểm tra POSTGRES_PASSWORD, POSTGRES_USER, POSTGRES_DB và host/port đã copy từ main."
}

test_redis_auth() {
    log "Kiểm tra đăng nhập Redis"
    local result
    result="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null || true)"
    if [[ "$result" == "PONG" ]]; then
        log "Đăng nhập Redis OK"
        return
    fi
    die "Đăng nhập Redis thất bại. Kiểm tra REDIS_PASSWORD và host/port đã copy từ main."
}

ensure_install_dir() {
    if [[ -f "$N8N_DIR/docker-compose.yml" || -f "$N8N_DIR/.env" ]]; then
        echo
        echo "Đã tìm thấy file worker trong $N8N_DIR."
        echo "Tiếp tục có thể ghi đè docker-compose.yml, .env và các script hỗ trợ."
        read -r -p "Nhập YES để tiếp tục: " confirm
        [[ "$confirm" == "YES" ]] || die "Đã hủy."

        if [[ -f "$N8N_DIR/docker-compose.yml" ]]; then
            log "Dừng stack worker hiện tại trước khi ghi lại file"
            (cd "$N8N_DIR" && compose_exec down --remove-orphans) || true
        fi
    fi

    mkdir -p \
        "$N8N_DIR/files/temp" \
        "$N8N_DIR/my-files"

    chown -R 1000:1000 \
        "$N8N_DIR/files" \
        "$N8N_DIR/my-files"

    chmod 750 "$N8N_DIR"
}

write_project_files() {
    log "Ghi file cấu hình n8n worker"

    cat > "$N8N_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=n8n-worker
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_PORT=${POSTGRES_PORT}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_BASE_IMAGE=${N8N_BASE_IMAGE}
N8N_VERSION=${N8N_VERSION}
WORKER_CONCURRENCY=${WORKER_CONCURRENCY}
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
EOF
    chmod 600 "$N8N_DIR/.env"

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
services:
  n8n-worker:
    image: n8n-custom:${N8N_VERSION}
    build:
      context: .
      dockerfile: Dockerfile
      args:
        N8N_BASE_IMAGE: ${N8N_BASE_IMAGE}
        N8N_VERSION: ${N8N_VERSION}
    container_name: n8n-worker
    restart: always
    user: "1000:1000"
    command: worker --concurrency=${WORKER_CONCURRENCY}
    environment:
      NODE_ENV: production
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      TZ: ${GENERIC_TIMEZONE}
      EXECUTIONS_MODE: queue
      OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS: "true"
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: ${POSTGRES_HOST}
      DB_POSTGRESDB_PORT: "${POSTGRES_PORT}"
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      QUEUE_BULL_REDIS_HOST: ${REDIS_HOST}
      QUEUE_BULL_REDIS_PORT: "${REDIS_PORT}"
      QUEUE_BULL_REDIS_PASSWORD: ${REDIS_PASSWORD}
      QUEUE_HEALTH_CHECK_ACTIVE: "false"
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
    volumes:
      - worker_data:/home/node/.n8n
      - ./files:/files
      - ./my-files:/home/my-files

volumes:
  worker_data:
    name: worker_data
EOF

    cat > "$N8N_DIR/check-connection.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N8N_DIR="$N8N_DIR"
# shellcheck disable=SC1090
set -a
. "\$N8N_DIR/.env"
set +a

test_tcp() {
    local host="\$1"
    local port="\$2"
    local name="\$3"
    echo "Kiểm tra \$name tại \$host:\$port"
    timeout 8 bash -c "</dev/tcp/\${host}/\${port}" 2>/dev/null
}

test_tcp "\$POSTGRES_HOST" "\$POSTGRES_PORT" "Postgres"
test_tcp "\$REDIS_HOST" "\$REDIS_PORT" "Redis"

echo "Kiểm tra đăng nhập Postgres"
PGPASSWORD="\$POSTGRES_PASSWORD" psql \
    "host=\$POSTGRES_HOST port=\$POSTGRES_PORT dbname=\$POSTGRES_DB user=\$POSTGRES_USER connect_timeout=8 sslmode=prefer" \
    -Atqc "SELECT 1" >/dev/null

echo "Kiểm tra đăng nhập Redis"
redis-cli -h "\$REDIS_HOST" -p "\$REDIS_PORT" -a "\$REDIS_PASSWORD" --no-auth-warning PING | grep -q '^PONG$'

echo "Kết nối và đăng nhập OK"
EOF
    chmod 700 "$N8N_DIR/check-connection.sh"

    cat > "$N8N_DIR/logs-worker.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    compose_exec() { docker-compose "\$@"; }
else
    compose_exec() { docker compose "\$@"; }
fi
compose_exec logs -f n8n-worker
EOF
    chmod 700 "$N8N_DIR/logs-worker.sh"

    cat > "$N8N_DIR/restart-worker.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    compose_exec() { docker-compose "\$@"; }
else
    compose_exec() { docker compose "\$@"; }
fi
compose_exec restart n8n-worker
docker ps --filter 'name=n8n-worker'
EOF
    chmod 700 "$N8N_DIR/restart-worker.sh"

    cat > "$N8N_DIR/update-worker.sh" <<EOF
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

echo "Tải image gốc n8n: \$N8N_BASE_IMAGE:\$N8N_VERSION"
docker pull "\$N8N_BASE_IMAGE:\$N8N_VERSION" || true

echo "Build lại và khởi động worker..."
compose_exec build --pull --no-cache
compose_exec up -d
docker image prune -f
echo "Cập nhật worker hoàn tất."
EOF
    chmod 700 "$N8N_DIR/update-worker.sh"
}

configure_auto_update() {
    if [[ "$AUTO_UPDATE" == "yes" ]]; then
        local cron_job="20 */12 * * * $N8N_DIR/update-worker.sh >> $N8N_DIR/update.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-worker.sh" || true; echo "$cron_job") | crontab -
        log "Đã bật tự động cập nhật mỗi 12 giờ"
    else
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-worker.sh" || true) | crontab - || true
        log "Đã tắt tự động cập nhật"
    fi
}

collect_inputs() {
    if [[ -z "$MAIN_HOST" && ( -z "$POSTGRES_HOST" || -z "$REDIS_HOST" ) ]]; then
        MAIN_HOST="$(prompt_required "Nhập MAIN_HOST hoặc IP/domain main")"
    fi

    if [[ -z "$POSTGRES_HOST" ]]; then
        POSTGRES_HOST="${MAIN_HOST}"
    fi
    if [[ -z "$POSTGRES_HOST" ]]; then
        POSTGRES_HOST="$(prompt_required "Host Postgres")"
    fi

    if [[ -z "$POSTGRES_PORT" ]]; then
        POSTGRES_PORT="$(prompt_required "Port Postgres")"
    fi
    if [[ -z "$POSTGRES_DB" ]]; then
        POSTGRES_DB="$(prompt_required "Database Postgres")"
    fi
    if [[ -z "$POSTGRES_USER" ]]; then
        POSTGRES_USER="$(prompt_required "User Postgres")"
    fi

    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        POSTGRES_PASSWORD="$(prompt_required "Mật khẩu Postgres từ main, hiển thị khi nhập")"
    fi

    if [[ -z "$REDIS_HOST" ]]; then
        REDIS_HOST="${MAIN_HOST}"
    fi
    if [[ -z "$REDIS_HOST" ]]; then
        REDIS_HOST="$(prompt_required "Host Redis")"
    fi

    if [[ -z "$REDIS_PORT" ]]; then
        REDIS_PORT="$(prompt_required "Port Redis")"
    fi

    if [[ -z "$REDIS_PASSWORD" ]]; then
        REDIS_PASSWORD="$(prompt_required "Mật khẩu Redis từ main, hiển thị khi nhập")"
    fi

    if [[ -z "$N8N_ENCRYPTION_KEY" ]]; then
        N8N_ENCRYPTION_KEY="$(prompt_required "N8N_ENCRYPTION_KEY từ main, hiển thị khi nhập")"
    fi

    if [[ -z "$N8N_BASE_IMAGE" ]]; then
        N8N_BASE_IMAGE="$(prompt_required "Image gốc của n8n")"
    fi
    if [[ -z "$N8N_VERSION" ]]; then
        N8N_VERSION="$(prompt_required "Tag image n8n")"
    fi
    if [[ -z "$WORKER_CONCURRENCY" ]]; then
        WORKER_CONCURRENCY="$(prompt_required "Số luồng worker")"
    fi

    validate_port "Port Postgres" "$POSTGRES_PORT"
    validate_port "Port Redis" "$REDIS_PORT"
    validate_positive_int "Số luồng worker" "$WORKER_CONCURRENCY"

    if [[ -z "$AUTO_UPDATE" ]]; then
        if prompt_yes_no "Bật tự động cập nhật mỗi 12 giờ? Khuyến nghị: không, cập nhật main/worker cùng lúc" "n"; then
            AUTO_UPDATE="yes"
        else
            AUTO_UPDATE="no"
        fi
    fi
    case "$AUTO_UPDATE" in
        yes|YES|y|Y)
            AUTO_UPDATE="yes"
            ;;
        no|NO|n|N)
            AUTO_UPDATE="no"
            ;;
        *)
            die "AUTO_UPDATE chỉ được là yes hoặc no."
            ;;
    esac

    if [[ -z "$MAIN_HOST" ]]; then
        MAIN_HOST="$POSTGRES_HOST"
    fi
}

main() {
    require_root
    install_base_packages
    create_swap
    collect_inputs

    test_tcp "$POSTGRES_HOST" "$POSTGRES_PORT" "Postgres"
    test_tcp "$REDIS_HOST" "$REDIS_PORT" "Redis"
    test_postgres_auth
    test_redis_auth

    install_docker
    ensure_install_dir
    write_project_files

    log "Build image n8n worker custom"
    cd "$N8N_DIR"
    compose_exec build --pull

    log "Khởi động n8n worker"
    compose_exec up -d
    configure_auto_update

    echo
    echo "======================================================================"
    echo "Đã cài xong n8n queue worker"
    echo "======================================================================"
    echo "Thư mục cài đặt: $N8N_DIR"
    echo "Worker này không mở port public."
    echo
    echo "Lệnh hữu ích:"
    echo "  $N8N_DIR/check-connection.sh"
    echo "  $N8N_DIR/logs-worker.sh"
    echo "  $N8N_DIR/restart-worker.sh"
    echo "  $N8N_DIR/update-worker.sh"
    echo "======================================================================"
}

main "$@"
