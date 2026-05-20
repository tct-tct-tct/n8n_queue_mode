#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

N8N_DIR="/home/n8n"
SKIP_DOCKER=false
DOMAIN=""
MAIN_PUBLIC_HOST=""
N8N_VERSION="latest"
POSTGRES_PUBLIC_PORT="5432"
REDIS_PUBLIC_PORT="6379"
LOCAL_WORKER_CONCURRENCY="5"
AUTO_UPDATE=""

show_help() {
    cat <<'EOF'
Usage: bash install_n8n_queue_main.sh [options]

Options:
  -d, --dir DIR           Install directory (default: /home/n8n)
  -s, --skip-docker       Skip Docker installation
      --domain DOMAIN     n8n domain, for example n8n.example.com
      --main-host HOST    Public host/IP workers will use for Postgres/Redis
      --n8n-version TAG   n8n image tag (default: latest)
  -h, --help              Show this help
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
        --n8n-version)
            N8N_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run this script as root."
    fi
}

prompt_required() {
    local prompt="$1"
    local value=""
    while [[ -z "$value" ]]; do
        read -r -p "$prompt: " value
    done
    printf '%s' "$value"
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value=""
    read -r -p "$prompt [$default]: " value
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
    read -r -p "$prompt $suffix: " answer
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
        die "$name must be a valid TCP port between 1 and 65535."
    fi
}

validate_positive_int() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
        die "$name must be a positive integer."
    fi
}

create_swap() {
    log "Checking swap"
    local current_swap
    current_swap="$(swapon --show | wc -l)"
    if [[ "$current_swap" -le 1 ]]; then
        log "Creating 2G swap at /swapfile"
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
        log "Swap already exists"
    fi
}

install_base_packages() {
    log "Installing base packages"
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
        log "Skipping Docker installation"
        return
    fi

    log "Installing Docker and Docker Compose plugin"
    install -m 0755 -d /etc/apt/keyrings

    local os_id
    local codename
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID}"
    codename="${VERSION_CODENAME:-$(lsb_release -cs)}"

    if [[ "$os_id" != "ubuntu" && "$os_id" != "debian" ]]; then
        die "This installer supports Ubuntu/Debian apt-based VPS only. Detected: $os_id"
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

    docker version >/dev/null || die "Docker is not working."
    docker compose version >/dev/null || die "Docker Compose plugin is not working."
}

compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "Docker Compose was not found."
    fi
}

check_domain() {
    local domain="$1"
    local server_ip
    local domain_ips
    server_ip="$(get_public_ip)"
    domain_ips="$(dig +short A "$domain" || true)"

    if echo "$domain_ips" | grep -Fxq "$server_ip"; then
        log "Domain $domain points to this server ($server_ip)"
        return
    fi

    echo
    echo "Domain check did not match this server."
    echo "  Domain: $domain"
    echo "  This server IPv4: $server_ip"
    echo "  DNS A records:"
    while IFS= read -r ip; do
        echo "    $ip"
    done <<< "$domain_ips"
    echo
    if ! prompt_yes_no "Continue anyway" "n"; then
        die "Point DNS to this VPS, then run the script again."
    fi
}

ensure_install_dir() {
    if [[ -f "$N8N_DIR/docker-compose.yml" || -f "$N8N_DIR/.env" ]]; then
        echo
        echo "Existing n8n queue files found in $N8N_DIR."
        echo "Continuing may overwrite docker-compose.yml, .env, and helper scripts."
        read -r -p "Type YES to continue: " confirm
        [[ "$confirm" == "YES" ]] || die "Cancelled."
    fi

    mkdir -p \
        "$N8N_DIR/backups" \
        "$N8N_DIR/files/temp" \
        "$N8N_DIR/main-data" \
        "$N8N_DIR/my-files" \
        "$N8N_DIR/worker-local-data"

    chown -R 1000:1000 \
        "$N8N_DIR/files" \
        "$N8N_DIR/main-data" \
        "$N8N_DIR/my-files" \
        "$N8N_DIR/worker-local-data"

    chmod 750 "$N8N_DIR"
}

write_project_files() {
    local postgres_password="$1"
    local redis_password="$2"
    local encryption_key="$3"

    log "Writing n8n queue main files"

    cat > "$N8N_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=n8n_queue_main
DOMAIN=${DOMAIN}
MAIN_PUBLIC_HOST=${MAIN_PUBLIC_HOST}
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
# Copy these values into install_n8n_queue_worker.sh prompts.
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
N8N_VERSION=${N8N_VERSION}
EOF
    chmod 600 "$N8N_DIR/worker-connection.env"

    cat > "$N8N_DIR/Dockerfile" <<'EOF'
ARG N8N_VERSION=latest

FROM mwader/static-ffmpeg:7.1 AS ffmpeg_source

FROM docker.n8n.io/n8nio/n8n:${N8N_VERSION}

USER root

COPY --from=ffmpeg_source /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg_source /ffprobe /usr/local/bin/ffprobe

RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
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
  NODE_FUNCTION_ALLOW_BUILTIN: child_process,path,fs,util
  NODE_FUNCTION_ALLOW_EXTERNAL: "*"
  N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE: "true"
  EXECUTIONS_DATA_PRUNE: "true"
  EXECUTIONS_DATA_MAX_AGE: "168"
  EXECUTIONS_DATA_PRUNE_MAX_COUNT: "5000"

x-n8n-build: &n8n-build
  build:
    context: .
    dockerfile: Dockerfile
    args:
      N8N_VERSION: ${N8N_VERSION}
  restart: always
  user: "1000:1000"
  networks:
    - n8n_network

services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n-postgres
    restart: always
    environment:
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
    container_name: n8n-redis
    restart: always
    command: ["sh", "-c", "redis-server --appendonly yes --requirepass \"$${REDIS_PASSWORD}\""]
    environment:
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
      - ./main-data:/home/node/.n8n
      - ./files:/files
      - ./my-files:/home/my-files
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "node -e \"const http=require('http');const req=http.get('http://127.0.0.1:5678/healthz',res=>process.exit(res.statusCode===200?0:1));req.on('error',()=>process.exit(1));req.setTimeout(3000,()=>process.exit(1));\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  n8n-worker-local:
    <<: *n8n-build
    container_name: n8n-worker-local
    command: worker --concurrency=${LOCAL_WORKER_CONCURRENCY}
    environment:
      <<: *n8n-environment
      QUEUE_HEALTH_CHECK_ACTIVE: "false"
    volumes:
      - ./worker-local-data:/home/node/.n8n
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
    depends_on:
      n8n-main:
        condition: service_healthy

volumes:
  postgres_data:
  redis_data:
  caddy_data:
  caddy_config:

networks:
  n8n_network:
    name: n8n_queue_network
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
    echo "Missing \$CONFIG_FILE"
    exit 1
fi

echo "Use these values when running install_n8n_queue_worker.sh:"
echo
cat "\$CONFIG_FILE"
echo
echo "Security note: anyone with these values can access your n8n database/queue and decrypt credentials."
EOF
    chmod 700 "$N8N_DIR/show-worker-config.sh"

    cat > "$N8N_DIR/backup-n8n.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N8N_DIR="$N8N_DIR"
ENV_FILE="\$N8N_DIR/.env"
[[ -f "\$ENV_FILE" ]] || { echo "Missing \$ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
set -a
. "\$ENV_FILE"
set +a

BACKUP_DATE="\$(date '+%Y%m%d_%H%M%S')"
WORK_DIR="\$N8N_DIR/backups/tmp_\$BACKUP_DATE"
ARCHIVE="\$N8N_DIR/backups/n8n_queue_backup_\$BACKUP_DATE.zip"
mkdir -p "\$WORK_DIR"

echo "Creating Postgres dump..."
docker exec -e PGPASSWORD="\$POSTGRES_PASSWORD" n8n-postgres \\
    pg_dump -U "\$POSTGRES_USER" "\$POSTGRES_DB" > "\$WORK_DIR/postgres.sql"

cp "\$N8N_DIR/.env" "\$WORK_DIR/.env"
cp "\$N8N_DIR/worker-connection.env" "\$WORK_DIR/worker-connection.env"
cp "\$N8N_DIR/docker-compose.yml" "\$WORK_DIR/docker-compose.yml"
cp "\$N8N_DIR/Dockerfile" "\$WORK_DIR/Dockerfile"
cp "\$N8N_DIR/Caddyfile" "\$WORK_DIR/Caddyfile"

(cd "\$WORK_DIR" && zip -r "\$ARCHIVE" . >/dev/null)
rm -rf "\$WORK_DIR"
find "\$N8N_DIR/backups" -name 'n8n_queue_backup_*.zip' -mtime +7 -delete

echo "Backup created: \$ARCHIVE"
EOF
    chmod 700 "$N8N_DIR/backup-n8n.sh"

    cat > "$N8N_DIR/restart-n8n.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N8N_DIR="$N8N_DIR"
cd "\$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    COMPOSE="docker compose"
fi
\$COMPOSE restart n8n-main n8n-worker-local caddy
docker ps --filter 'name=n8n-'
docker ps --filter 'name=caddy'
EOF
    chmod 700 "$N8N_DIR/restart-n8n.sh"

    cat > "$N8N_DIR/update-n8n.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N8N_DIR="$N8N_DIR"
cd "\$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    COMPOSE="docker compose"
fi

# shellcheck disable=SC1090
set -a
. "\$N8N_DIR/.env"
set +a

echo "Creating backup before update..."
"\$N8N_DIR/backup-n8n.sh"

echo "Pulling base n8n image tag: \$N8N_VERSION"
docker pull "docker.n8n.io/n8nio/n8n:\$N8N_VERSION" || true

echo "Rebuilding and restarting stack..."
\$COMPOSE build --pull --no-cache
\$COMPOSE up -d
docker image prune -f
echo "Update complete."
EOF
    chmod 700 "$N8N_DIR/update-n8n.sh"
}

configure_auto_update() {
    if [[ "$AUTO_UPDATE" == "yes" ]]; then
        local cron_job="0 */12 * * * $N8N_DIR/update-n8n.sh >> $N8N_DIR/update.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-n8n.sh" || true; echo "$cron_job") | crontab -
        log "Auto update enabled every 12 hours"
    else
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-n8n.sh" || true) | crontab - || true
        log "Auto update disabled"
    fi
}

wait_for_main() {
    local max_wait=180
    local waited=0
    log "Waiting for n8n-main healthcheck"
    while (( waited < max_wait )); do
        if docker inspect --format='{{.State.Health.Status}}' n8n-main 2>/dev/null | grep -q "healthy"; then
            log "n8n-main is healthy"
            return
        fi
        sleep 5
        waited=$((waited + 5))
        echo "Waiting... ${waited}s/${max_wait}s"
    done
    echo "n8n-main was not healthy after ${max_wait}s. Check logs:"
    echo "  cd $N8N_DIR && $(compose_cmd) logs n8n-main"
}

main() {
    require_root
    install_base_packages
    create_swap

    if [[ -z "$DOMAIN" ]]; then
        DOMAIN="$(prompt_required "Enter n8n domain or subdomain")"
    fi
    check_domain "$DOMAIN"

    if [[ -z "$MAIN_PUBLIC_HOST" ]]; then
        local detected_ip
        detected_ip="$(get_public_ip)"
        MAIN_PUBLIC_HOST="$(prompt_default "Enter public host/IP workers will use for Postgres/Redis" "$detected_ip")"
    fi

    POSTGRES_PUBLIC_PORT="$(prompt_default "Postgres public port for workers" "$POSTGRES_PUBLIC_PORT")"
    REDIS_PUBLIC_PORT="$(prompt_default "Redis public port for workers" "$REDIS_PUBLIC_PORT")"
    LOCAL_WORKER_CONCURRENCY="$(prompt_default "Local worker concurrency" "$LOCAL_WORKER_CONCURRENCY")"
    N8N_VERSION="$(prompt_default "n8n image tag" "$N8N_VERSION")"

    validate_port "Postgres port" "$POSTGRES_PUBLIC_PORT"
    validate_port "Redis port" "$REDIS_PUBLIC_PORT"
    validate_positive_int "Local worker concurrency" "$LOCAL_WORKER_CONCURRENCY"

    if prompt_yes_no "Enable cron auto-update every 12 hours? Recommended: no, update main/workers together" "n"; then
        AUTO_UPDATE="yes"
    else
        AUTO_UPDATE="no"
    fi

    echo
    echo "SECURITY WARNING:"
    echo "This setup exposes Postgres port $POSTGRES_PUBLIC_PORT and Redis port $REDIS_PUBLIC_PORT for remote workers."
    echo "The generated passwords are strong, but firewall/VPN/private networking is still safer when possible."
    if ! prompt_yes_no "Continue with host/password mode" "y"; then
        die "Cancelled."
    fi

    install_docker
    ensure_install_dir

    local postgres_password
    local redis_password
    local encryption_key
    postgres_password="$(openssl rand -hex 24)"
    redis_password="$(openssl rand -hex 24)"
    encryption_key="$(openssl rand -hex 32)"

    write_project_files "$postgres_password" "$redis_password" "$encryption_key"

    local compose
    compose="$(compose_cmd)"
    log "Building n8n custom image"
    cd "$N8N_DIR"
    $compose build --pull

    log "Starting n8n queue stack"
    $compose up -d
    wait_for_main
    configure_auto_update

    echo
    echo "======================================================================"
    echo "n8n queue main installed"
    echo "======================================================================"
    echo "n8n URL: https://${DOMAIN}"
    echo "Install directory: $N8N_DIR"
    echo "Worker config: $N8N_DIR/worker-connection.env"
    echo
    echo "Show worker connection values:"
    echo "  $N8N_DIR/show-worker-config.sh"
    echo
    echo "Useful commands:"
    echo "  cd $N8N_DIR && $compose logs -f"
    echo "  $N8N_DIR/restart-n8n.sh"
    echo "  $N8N_DIR/backup-n8n.sh"
    echo "  $N8N_DIR/update-n8n.sh"
    echo
    echo "Important secrets were written to:"
    echo "  $N8N_DIR/.env"
    echo "  $N8N_DIR/worker-connection.env"
    echo "======================================================================"
}

main "$@"
