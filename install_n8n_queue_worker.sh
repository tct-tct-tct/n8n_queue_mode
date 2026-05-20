#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

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
N8N_VERSION="latest"
WORKER_CONCURRENCY="5"
AUTO_UPDATE=""

show_help() {
    cat <<'EOF'
Usage: bash install_n8n_queue_worker.sh [options]

Options:
  -d, --dir DIR              Install directory (default: /home/n8n-worker)
  -s, --skip-docker          Skip Docker installation
      --main-host HOST       Main host/IP for Postgres and Redis
      --n8n-version TAG      n8n image tag (default: latest)
  -h, --help                 Show this help

Most values are prompted interactively. Copy them from:
  /home/n8n/show-worker-config.sh
on the main VPS.
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

prompt_secret() {
    local prompt="$1"
    local value=""
    while [[ -z "$value" ]]; do
        read -r -s -p "$prompt: " value
        echo >&2
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
        gnupg \
        lsb-release \
        openssl \
        software-properties-common
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

test_tcp() {
    local host="$1"
    local port="$2"
    local name="$3"
    log "Testing TCP connection to $name at $host:$port"
    if timeout 8 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
        log "$name TCP connection OK"
        return
    fi
    die "Cannot connect to $name at $host:$port. Check main firewall, host, port, and provider security group."
}

ensure_install_dir() {
    if [[ -f "$N8N_DIR/docker-compose.yml" || -f "$N8N_DIR/.env" ]]; then
        echo
        echo "Existing worker files found in $N8N_DIR."
        echo "Continuing may overwrite docker-compose.yml, .env, and helper scripts."
        read -r -p "Type YES to continue: " confirm
        [[ "$confirm" == "YES" ]] || die "Cancelled."
    fi

    mkdir -p \
        "$N8N_DIR/files/temp" \
        "$N8N_DIR/my-files" \
        "$N8N_DIR/worker-data"

    chown -R 1000:1000 \
        "$N8N_DIR/files" \
        "$N8N_DIR/my-files" \
        "$N8N_DIR/worker-data"

    chmod 750 "$N8N_DIR"
}

write_project_files() {
    log "Writing n8n worker files"

    cat > "$N8N_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=n8n_queue_worker
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_PORT=${POSTGRES_PORT}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_VERSION=${N8N_VERSION}
WORKER_CONCURRENCY=${WORKER_CONCURRENCY}
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
EOF
    chmod 600 "$N8N_DIR/.env"

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
services:
  n8n-worker:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        N8N_VERSION: ${N8N_VERSION}
    container_name: n8n-worker
    restart: always
    user: "1000:1000"
    command: worker --concurrency=${WORKER_CONCURRENCY}
    environment:
      NODE_ENV: production
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      EXECUTIONS_MODE: queue
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
      NODE_FUNCTION_ALLOW_BUILTIN: child_process,path,fs,util
      NODE_FUNCTION_ALLOW_EXTERNAL: "*"
      N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE: "true"
    volumes:
      - ./worker-data:/home/node/.n8n
      - ./files:/files
      - ./my-files:/home/my-files
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
    echo "Testing \$name at \$host:\$port"
    timeout 8 bash -c "</dev/tcp/\${host}/\${port}" 2>/dev/null
}

test_tcp "\$POSTGRES_HOST" "\$POSTGRES_PORT" "Postgres"
test_tcp "\$REDIS_HOST" "\$REDIS_PORT" "Redis"
echo "Connections OK"
EOF
    chmod 700 "$N8N_DIR/check-connection.sh"

    cat > "$N8N_DIR/logs-worker.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    COMPOSE="docker compose"
fi
\$COMPOSE logs -f n8n-worker
EOF
    chmod 700 "$N8N_DIR/logs-worker.sh"

    cat > "$N8N_DIR/restart-worker.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$N8N_DIR"
if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    COMPOSE="docker compose"
fi
\$COMPOSE restart n8n-worker
docker ps --filter 'name=n8n-worker'
EOF
    chmod 700 "$N8N_DIR/restart-worker.sh"

    cat > "$N8N_DIR/update-worker.sh" <<EOF
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

echo "Pulling base n8n image tag: \$N8N_VERSION"
docker pull "docker.n8n.io/n8nio/n8n:\$N8N_VERSION" || true

echo "Rebuilding and restarting worker..."
\$COMPOSE build --pull --no-cache
\$COMPOSE up -d
docker image prune -f
echo "Worker update complete."
EOF
    chmod 700 "$N8N_DIR/update-worker.sh"
}

configure_auto_update() {
    if [[ "$AUTO_UPDATE" == "yes" ]]; then
        local cron_job="20 */12 * * * $N8N_DIR/update-worker.sh >> $N8N_DIR/update.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-worker.sh" || true; echo "$cron_job") | crontab -
        log "Auto update enabled every 12 hours"
    else
        (crontab -l 2>/dev/null | grep -v "$N8N_DIR/update-worker.sh" || true) | crontab - || true
        log "Auto update disabled"
    fi
}

collect_inputs() {
    if [[ -z "$MAIN_HOST" ]]; then
        MAIN_HOST="$(prompt_required "Main host/IP from MAIN_HOST")"
    fi

    POSTGRES_HOST="$(prompt_default "Postgres host" "$MAIN_HOST")"
    POSTGRES_PORT="$(prompt_default "Postgres port" "$POSTGRES_PORT")"
    POSTGRES_DB="$(prompt_default "Postgres database" "$POSTGRES_DB")"
    POSTGRES_USER="$(prompt_default "Postgres user" "$POSTGRES_USER")"

    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        POSTGRES_PASSWORD="$(prompt_secret "Postgres password")"
    fi

    REDIS_HOST="$(prompt_default "Redis host" "$MAIN_HOST")"
    REDIS_PORT="$(prompt_default "Redis port" "$REDIS_PORT")"

    if [[ -z "$REDIS_PASSWORD" ]]; then
        REDIS_PASSWORD="$(prompt_secret "Redis password")"
    fi

    if [[ -z "$N8N_ENCRYPTION_KEY" ]]; then
        N8N_ENCRYPTION_KEY="$(prompt_secret "N8N_ENCRYPTION_KEY")"
    fi

    N8N_VERSION="$(prompt_default "n8n image tag" "$N8N_VERSION")"
    WORKER_CONCURRENCY="$(prompt_default "Worker concurrency" "$WORKER_CONCURRENCY")"

    validate_port "Postgres port" "$POSTGRES_PORT"
    validate_port "Redis port" "$REDIS_PORT"
    validate_positive_int "Worker concurrency" "$WORKER_CONCURRENCY"

    if prompt_yes_no "Enable cron auto-update every 12 hours? Recommended: no, update main/workers together" "n"; then
        AUTO_UPDATE="yes"
    else
        AUTO_UPDATE="no"
    fi
}

main() {
    require_root
    install_base_packages
    create_swap
    collect_inputs

    test_tcp "$POSTGRES_HOST" "$POSTGRES_PORT" "Postgres"
    test_tcp "$REDIS_HOST" "$REDIS_PORT" "Redis"

    install_docker
    ensure_install_dir
    write_project_files

    local compose
    compose="$(compose_cmd)"
    log "Building n8n worker custom image"
    cd "$N8N_DIR"
    $compose build --pull

    log "Starting n8n worker"
    $compose up -d
    configure_auto_update

    echo
    echo "======================================================================"
    echo "n8n queue worker installed"
    echo "======================================================================"
    echo "Install directory: $N8N_DIR"
    echo "No public port is exposed by this worker."
    echo
    echo "Useful commands:"
    echo "  $N8N_DIR/check-connection.sh"
    echo "  $N8N_DIR/logs-worker.sh"
    echo "  $N8N_DIR/restart-worker.sh"
    echo "  $N8N_DIR/update-worker.sh"
    echo "======================================================================"
}

main "$@"
