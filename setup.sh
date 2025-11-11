#!/bin/sh -e

# ==========================Script Config==========================

readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly BOLDGREEN='\033[1;32m'
readonly DIM='\033[2m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# No diagnostics for: 'printf "...${FOO}"'
# shellcheck disable=SC2059

# Docker Compose Constants
INFLUXDB_PORT=8181  # Can be changed if port is in use
EXPLORER_PORT=8888  # Can be changed if port is in use
readonly EXPLORER_IMAGE="influxdata/influxdb3-ui:1.4.0"
readonly DEFAULT_DATABASE="mydb"
readonly MANUAL_TOKEN_MSG="MANUAL_TOKEN_CREATION_REQUIRED"
readonly DOCKER_OUTPUT_FILTER='grep -v "version.*obsolete" | grep -v "Creating$" | grep -v "Created$" | grep -v "Starting$" | grep -v "Started$" | grep -v "Running$"'

ARCHITECTURE=$(uname -m)
ARTIFACT=""
OS=""
INSTALL_LOC=~/.influxdb
BINARY_NAME="influxdb3"
PORT=8181

# Set the default (latest) version here. Users may specify a version using the
# --version arg (handled below)
INFLUXDB_VERSION="3.6.0"
EDITION="Core"
EDITION_TAG="core"


# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            INFLUXDB_VERSION="$2"
            shift 2
            ;;
        enterprise)
            EDITION="Enterprise"
            EDITION_TAG="enterprise"
            shift 1
            ;;
        *)
            echo "Usage: $0 [enterprise] [--version VERSION]"
            echo "  enterprise: Install the Enterprise edition (optional)"
            echo "  --version VERSION: Specify InfluxDB version (default: $INFLUXDB_VERSION)"
            exit 1
            ;;
    esac
done



# ==========================Detect OS/Architecture==========================

case "$(uname -s)" in
    Linux*)     OS="Linux";;
    Darwin*)    OS="Darwin";;
    *)         OS="UNKNOWN";;
esac

if [ "${OS}" = "Linux" ]; then
    if [ "${ARCHITECTURE}" = "x86_64" ] || [ "${ARCHITECTURE}" = "amd64" ]; then
        ARTIFACT="linux_amd64"
    elif [ "${ARCHITECTURE}" = "aarch64" ] || [ "${ARCHITECTURE}" = "arm64" ]; then
        ARTIFACT="linux_arm64"
    fi
elif [ "${OS}" = "Darwin" ]; then
    if [ "${ARCHITECTURE}" = "x86_64" ]; then
        printf "Intel Mac support is coming soon!\n"
        printf "Visit our public Discord at \033[4;94mhttps://discord.gg/az4jPm8x${NC} for additional guidance.\n"
        printf "View alternative binaries on our Getting Started guide at \033[4;94mhttps://docs.influxdata.com/influxdb3/${EDITION_TAG}/${NC}.\n"
        exit 1
    else
        ARTIFACT="darwin_arm64"
    fi
fi

# Exit if unsupported system
[ -n "${ARTIFACT}" ] || {
    printf "Unfortunately this script doesn't support your '${OS}' | '${ARCHITECTURE}' setup, or was unable to identify it correctly.\n"
    printf "Visit our public Discord at \033[4;94mhttps://discord.gg/az4jPm8x${NC} for additional guidance.\n"
    printf "View alternative binaries on our Getting Started guide at \033[4;94mhttps://docs.influxdata.com/influxdb3/${EDITION_TAG}/${NC}.\n"
    exit 1
}

URL="https://dl.influxdata.com/influxdb/releases/influxdb3-${EDITION_TAG}-${INFLUXDB_VERSION}_${ARTIFACT}.tar.gz"



# ==========================Reusable Script Functions ==========================

# Function to check if Docker is available and running
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Function to find available ports for InfluxDB and Explorer
find_available_ports() {
    show_progress="${1:-true}"

    lsof_exec=$(command -v lsof)
    if [ -z "$lsof_exec" ]; then
        # lsof not available, skip port checking
        return 0
    fi

    # Check InfluxDB port
    ORIGINAL_INFLUXDB_PORT=$INFLUXDB_PORT
    while lsof -i:"$INFLUXDB_PORT" -t >/dev/null 2>&1; do
        INFLUXDB_PORT=$((INFLUXDB_PORT + 1))
        if [ "$INFLUXDB_PORT" -gt 32767 ]; then
            printf "└─${RED} Could not find an available port for InfluxDB. Aborting.${NC}\n"
            exit 1
        fi
    done

    # Only show if port changed
    if [ "$INFLUXDB_PORT" != "$ORIGINAL_INFLUXDB_PORT" ] && [ "$show_progress" = "true" ]; then
        printf "├─${DIM} Using port %s for InfluxDB (default %s in use)${NC}\n" "$INFLUXDB_PORT" "$ORIGINAL_INFLUXDB_PORT"
    fi

    # Check Explorer port
    ORIGINAL_EXPLORER_PORT=$EXPLORER_PORT
    while lsof -i:"$EXPLORER_PORT" -t >/dev/null 2>&1; do
        EXPLORER_PORT=$((EXPLORER_PORT + 1))
        if [ "$EXPLORER_PORT" -gt 32767 ]; then
            printf "└─${RED} Could not find an available port for Explorer. Aborting.${NC}\n"
            exit 1
        fi
    done

    # Only show if port changed
    if [ "$EXPLORER_PORT" != "$ORIGINAL_EXPLORER_PORT" ] && [ "$show_progress" = "true" ]; then
        printf "├─${DIM} Using port %s for Explorer (default %s in use)${NC}\n" "$EXPLORER_PORT" "$ORIGINAL_EXPLORER_PORT"
    fi
}

# Utility function to filter Docker Compose output
filter_docker_output() {
    eval "$DOCKER_OUTPUT_FILTER" || true
}

# Utility function to open URL in browser
open_browser_url() {
    URL="$1"
    if command -v open >/dev/null 2>&1; then
        open "$URL" >/dev/null 2>&1 &
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL" >/dev/null 2>&1 &
    elif command -v start >/dev/null 2>&1; then
        start "$URL" >/dev/null 2>&1 &
    fi
}

# Utility function to create docker directories with permissions
create_docker_directories() {
    DOCKER_DIR="$1"

    mkdir -p "$DOCKER_DIR/influxdb3/data"
    mkdir -p "$DOCKER_DIR/influxdb3/plugins"
    mkdir -p "$DOCKER_DIR/explorer/db"
    mkdir -p "$DOCKER_DIR/explorer/config"

    chmod 700 "$DOCKER_DIR/explorer/db" 2>/dev/null || true
    chmod 755 "$DOCKER_DIR/explorer/config" 2>/dev/null || true
}

# Utility function to generate session secret
generate_session_secret() {
    openssl rand -hex 32 2>/dev/null || date +%s | sha256sum | head -c 32
}

# Utility function to wait for container to be ready
wait_for_container_ready() {
    CONTAINER_NAME="$1"
    READY_MESSAGE="$2"
    TIMEOUT="${3:-60}"
    EDITION_TYPE="${4:-}"
    LICENSE_TYPE="${5:-}"

    printf "├─ Starting InfluxDB"
    ELAPSED=0
    EMAIL_MESSAGE_SHOWN=false

    while [ $ELAPSED -lt $TIMEOUT ]; do
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "$READY_MESSAGE"; then
            printf "${NC}\n"
            printf "├─${GREEN} InfluxDB is ready${NC}\n"
            return 0
        fi

        if ! docker ps | grep -q "$CONTAINER_NAME"; then
            printf "${NC}\n"
            printf "├─${RED} Error: InfluxDB container stopped unexpectedly${NC}\n"
            docker logs --tail 20 "$CONTAINER_NAME"
            return 1
        fi

        if [ $ELAPSED -eq $((TIMEOUT - 1)) ]; then
            printf "${NC}\n"
            printf "├─${RED} Error: InfluxDB failed to start within ${TIMEOUT} seconds${NC}\n"
            return 1
        fi

        # Show email verification message after 4 seconds for Enterprise with new license
        if [ "$EDITION_TYPE" = "enterprise" ] && [ -n "$LICENSE_TYPE" ] && \
           [ $ELAPSED -ge 4 ] && [ "$EMAIL_MESSAGE_SHOWN" = "false" ]; then
            printf "${NC}\n"
            printf "├─${YELLOW} License activation requires email verification${NC}\n"
            printf "├─${BOLD} → Check your inbox and verify your email address${NC}\n"
            printf "├─ Continuing startup"
            EMAIL_MESSAGE_SHOWN=true
        fi

        printf "."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
}

# Utility function to wait for Explorer to be fully ready
wait_for_explorer_ready() {
    TIMEOUT="${1:-60}"

    printf "├─ Starting Explorer"
    ELAPSED=0

    while [ $ELAPSED -lt $TIMEOUT ]; do
        if curl -s http://localhost:$EXPLORER_PORT >/dev/null 2>&1; then
            API_RESPONSE=$(curl -s http://localhost:$EXPLORER_PORT/api/health 2>&1)
            if echo "$API_RESPONSE" | grep -q "ok\|status\|healthy" 2>/dev/null; then
                printf "${NC}\n"
                printf "├─${GREEN} Explorer is ready${NC}\n"
                return 0
            fi
        fi

        printf "."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    printf "${NC}\n"
    return 1
}

# Utility function to create operator token via API
create_operator_token() {
    CONTAINER_NAME="$1"

    # Try API first with retries
    MAX_RETRIES=3
    RETRY=0
    TOKEN=""

    while [ $RETRY -lt $MAX_RETRIES ] && [ -z "$TOKEN" ]; do
        TOKEN_RESPONSE=$(curl -s -m 5 -X POST http://localhost:$INFLUXDB_PORT/api/v3/configure/token/admin 2>&1)
        TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

        if [ -z "$TOKEN" ] && [ $RETRY -lt $((MAX_RETRIES - 1)) ]; then
            sleep 2
            RETRY=$((RETRY + 1))
        else
            break
        fi
    done

    # Fallback to CLI if API fails
    if [ -z "$TOKEN" ]; then
        TOKEN_OUTPUT=$(docker exec "$CONTAINER_NAME" influxdb3 create token --admin 2>&1)
        TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '(apiv3|idb3)_[a-zA-Z0-9_-]+' | head -1)

        if [ -z "$TOKEN" ]; then
            echo "$MANUAL_TOKEN_MSG"
            return 1
        fi
    fi

    echo "$TOKEN"
    return 0
}

# Function to detect existing InfluxDB 3 installations
detect_existing_installations() {
    # Initialize detection variables
    BINARY_FOUND=false
    DOCKER_FOUND=false
    BINARY_RUNNING=false
    DOCKER_RUNNING=false
    BINARY_IN_PATH=false
    BINARY_VERSION=""
    BINARY_PATH_LOCATION=""
    BINARY_PID=""
    BINARY_DATA_SIZE=""
    DOCKER_DATA_SIZE=""

    # Check for binary installation
    if [ -f "$INSTALL_LOC/influxdb3" ]; then
        BINARY_FOUND=true
        # Try to get version
        BINARY_VERSION=$("$INSTALL_LOC/influxdb3" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi

    # Check if binary is in PATH (anywhere)
    if command -v influxdb3 >/dev/null 2>&1; then
        BINARY_IN_PATH=true
        BINARY_PATH_LOCATION=$(command -v influxdb3 2>/dev/null)
    fi

    # Check for running binary process
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x influxdb3 >/dev/null 2>&1; then
            BINARY_RUNNING=true
            BINARY_PID=$(pgrep -x influxdb3 | head -1)
        fi
    fi

    # Check for binary data directory
    if [ -d "$INSTALL_LOC/data" ]; then
        if command -v du >/dev/null 2>&1; then
            BINARY_DATA_SIZE=$(du -sh "$INSTALL_LOC/data" 2>/dev/null | cut -f1)
        fi
    fi

    # Set default Docker directory if not set
    DOCKER_DIR_CHECK="${DOCKER_DIR:-$HOME/.influxdb/docker}"

    # Check for Docker installation
    if [ -d "$DOCKER_DIR_CHECK" ] && [ -f "$DOCKER_DIR_CHECK/docker-compose.yml" ]; then
        DOCKER_FOUND=true
    fi

    # Check for running Docker containers (only if Docker is available)
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker ps --filter "name=influxdb3-core" --format "{{.Names}}" 2>/dev/null | grep -q influxdb3 || \
           docker ps --filter "name=influxdb3-enterprise" --format "{{.Names}}" 2>/dev/null | grep -q influxdb3; then
            DOCKER_RUNNING=true
        fi
    fi

    # Check for Docker data directory
    if [ -d "$DOCKER_DIR_CHECK/influxdb3/data" ]; then
        if command -v du >/dev/null 2>&1; then
            DOCKER_DATA_SIZE=$(du -sh "$DOCKER_DIR_CHECK/influxdb3/data" 2>/dev/null | cut -f1)
        fi
    fi
}

# Function to display existing installation status
display_installation_status() {
    # Only display if something was found
    if [ "$BINARY_FOUND" = true ] || [ "$DOCKER_FOUND" = true ]; then
        printf "\n"
        printf "Found existing: "

        FOUND_ITEMS=""

        if [ "$BINARY_FOUND" = true ]; then
            if [ "$BINARY_RUNNING" = true ]; then
                FOUND_ITEMS="Binary (running)"
            else
                FOUND_ITEMS="Binary (stopped)"
            fi
        fi

        if [ "$DOCKER_FOUND" = true ]; then
            if [ -n "$FOUND_ITEMS" ]; then
                FOUND_ITEMS="$FOUND_ITEMS, "
            fi
            if [ "$DOCKER_RUNNING" = true ]; then
                FOUND_ITEMS="${FOUND_ITEMS}Docker (running)"
            else
                FOUND_ITEMS="${FOUND_ITEMS}Docker (stopped)"
            fi
        fi

        printf "%s${NC}\n" "$FOUND_ITEMS"
        echo
    fi
}

# Function to generate Docker Compose YAML
generate_docker_compose_yaml() {
    EDITION_TYPE="$1"  # "core" or "enterprise"
    SESSION_SECRET="$2"
    LICENSE_EMAIL="$3"
    DOCKER_DIR="$4"

    # Determine edition-specific values
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        SERVICE_NAME="influxdb3-enterprise"
        IMAGE_NAME="influxdb:3-enterprise"
        CLUSTER_ARG="      - --cluster-id=cluster0"
        ENV_SECTION="    environment:
      - INFLUXDB3_ENTERPRISE_LICENSE_EMAIL=\${INFLUXDB_EMAIL}"
    else
        SERVICE_NAME="influxdb3-core"
        IMAGE_NAME="influxdb:3-core"
        CLUSTER_ARG=""
        ENV_SECTION=""
    fi

    cat > "$DOCKER_DIR/docker-compose.yml" << COMPOSE_EOF
services:
  ${SERVICE_NAME}:
    image: ${IMAGE_NAME}
    container_name: ${SERVICE_NAME}
    ports:
      - "${INFLUXDB_PORT}:8181"
    command:
      - influxdb3
      - serve
      - --node-id=node0${CLUSTER_ARG:+
${CLUSTER_ARG}}
      - --object-store=file
      - --data-dir=/var/lib/influxdb3/data
      - --plugin-dir=/var/lib/influxdb3/plugins${ENV_SECTION:+
${ENV_SECTION}}
    volumes:
      - ./influxdb3/data:/var/lib/influxdb3/data
      - ./influxdb3/plugins:/var/lib/influxdb3/plugins
    restart: unless-stopped
    networks:
      - influxdb-network

  influxdb3-explorer:
    image: ${EXPLORER_IMAGE}
    container_name: influxdb3-explorer
    command: ["--mode=admin"]
    ports:
      - "${EXPLORER_PORT}:80"
    volumes:
      - ./explorer/db:/db:rw
      - ./explorer/config:/app-root/config:ro
    environment:
      - SESSION_SECRET_KEY=\${SESSION_SECRET}
    restart: unless-stopped
    depends_on:
      - ${SERVICE_NAME}
    networks:
      - influxdb-network

networks:
  influxdb-network:
    driver: bridge
COMPOSE_EOF

    # Create .env file
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        cat > "$DOCKER_DIR/.env" << ENV_EOF
INFLUXDB_EMAIL=${LICENSE_EMAIL}
SESSION_SECRET=${SESSION_SECRET}
ENV_EOF
    else
        cat > "$DOCKER_DIR/.env" << ENV_EOF
SESSION_SECRET=${SESSION_SECRET}
ENV_EOF
    fi
}

# Function to configure Explorer via file
configure_explorer_via_file() {
    TOKEN="$1"
    INFLUXDB_URL="$2"
    SERVER_NAME="$3"
    DOCKER_DIR="$4"

    printf "├─ Configuring Explorer...\n"

    # Ensure config directory exists with correct permissions
    mkdir -p "$DOCKER_DIR/explorer/config"
    chmod 755 "$DOCKER_DIR/explorer/config"

    # Create the config.json file
    cat > "$DOCKER_DIR/explorer/config/config.json" <<EOF
{
  "DEFAULT_INFLUX_SERVER": "$INFLUXDB_URL",
  "DEFAULT_INFLUX_DATABASE": "mydb",
  "DEFAULT_API_TOKEN": "$TOKEN",
  "DEFAULT_SERVER_NAME": "$SERVER_NAME"
}
EOF

    chmod 644 "$DOCKER_DIR/explorer/config/config.json"

    return 0
}

# Unified function to setup Docker Compose (both Core and Enterprise)
setup_docker_compose() {
    EDITION_TYPE="$1"  # "core" or "enterprise"
    DOCKER_DIR="${2:-$HOME/.influxdb/docker}"
    LICENSE_EMAIL="$3"
    LICENSE_TYPE="$4"

    # Set edition-specific values
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        EDITION_NAME="Enterprise"
        CONTAINER_NAME="influxdb3-enterprise"
        SERVER_NAME="InfluxDB 3 Enterprise"
    else
        EDITION_NAME="Core"
        CONTAINER_NAME="influxdb3-core"
        SERVER_NAME="InfluxDB 3 Core"
    fi

    printf "\n${BOLD}Setting up Docker Compose for InfluxDB 3 ${EDITION_NAME}${NC}\n"

    # Verify Docker is running before doing any setup work (silent check)
    if ! check_docker; then
        printf "${RED}Error: Docker is not running${NC}\n\n"
        printf "${BOLD}Docker Connection Failed${NC}\n"
        printf "Docker is not responding. Please ensure Docker Desktop is running.\n\n"
        printf "${BOLD}How to fix:${NC}\n"
        printf "  • Open Docker Desktop and wait for it to start\n"
        printf "  • Check Docker Desktop status in your system tray\n"
        printf "  • Run ${BOLD}docker info${NC} to verify Docker is responding\n"
        printf "  • Restart Docker Desktop if necessary, then run this script again\n\n"
        return 1
    fi

    # Enterprise-specific: Handle license prompting
    if [ "$EDITION_TYPE" = "enterprise" ]; then
        # Check for existing license
        if [ -d "$DOCKER_DIR/influxdb3/data/cluster0" ] && [ -f "$DOCKER_DIR/influxdb3/data/cluster0/trial_or_home_license" ]; then
            printf "├─${DIM} Found existing license file${NC}\n"
        elif [ -z "$LICENSE_EMAIL" ]; then
            # Prompt for license if not provided
            printf "\n${BOLD}License Setup Required${NC}\n"
            printf "1) ${GREEN}Trial${NC} ${DIM}- Full features for 30 days (up to 256 cores)${NC}\n"
            printf "2) ${GREEN}Home${NC} ${DIM}- Free for non-commercial use (max 2 cores, single node)${NC}\n"
            printf "\nEnter choice (1-2): "
            read -r LICENSE_CHOICE

            case "${LICENSE_CHOICE:-1}" in
                1) LICENSE_TYPE="trial" ;;
                2) LICENSE_TYPE="home" ;;
                *) LICENSE_TYPE="trial" ;;
            esac

            printf "Enter your email: "
            read -r LICENSE_EMAIL
            while [ -z "$LICENSE_EMAIL" ]; do
                printf "Email is required. Enter your email: "
                read -r LICENSE_EMAIL
            done
        fi
    fi

    printf "├─ Creating directories\n"
    create_docker_directories "$DOCKER_DIR"

    # Check for available ports
    find_available_ports

    # Generate session secret
    SESSION_SECRET=$(generate_session_secret)

    printf "├─ Creating docker-compose.yml\n"
    generate_docker_compose_yaml "$EDITION_TYPE" "$SESSION_SECRET" "$LICENSE_EMAIL" "$DOCKER_DIR"

    cd "$DOCKER_DIR"

    # Pull InfluxDB image
    printf "├─ Pulling InfluxDB 3 ${EDITION_NAME} image\n"
    if docker compose pull "$CONTAINER_NAME" >/dev/null 2>&1; then
        printf "│  ${GREEN}Downloaded successfully${NC}\n"
    else
        printf "│  ${RED}Failed to download${NC}\n"
        printf "└─ ${RED}Error: Failed to pull InfluxDB image${NC}\n"
        printf "   Check your internet connection and Docker Hub access\n\n"
        return 1
    fi

    docker compose up -d "$CONTAINER_NAME" 2>&1 | filter_docker_output

    # Wait for InfluxDB to be ready
    if ! wait_for_container_ready "$CONTAINER_NAME" "startup time:" 60 "$EDITION_TYPE" "$LICENSE_TYPE"; then
        return 1
    fi

    sleep 2

    # Create operator token
    printf "├─ Creating operator token\n"
    TOKEN=$(create_operator_token "$CONTAINER_NAME")

    printf "└─${GREEN} Configuration complete${NC}\n\n"

    # Display token BEFORE launching Explorer
    if [ "$TOKEN" != "$MANUAL_TOKEN_MSG" ]; then
        printf "┌──────────────────────────────────────────────────────────────────────────────────────────────┐\n"
        printf "│ ${BOLD}OPERATOR TOKEN${NC}                                                                               │\n"
        printf "├──────────────────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ %s │\n" "$TOKEN"
        printf "├──────────────────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ ${RED}IMPORTANT:${NC} Save this token securely. It cannot be retrieved later.                           │\n"
        printf "└──────────────────────────────────────────────────────────────────────────────────────────────┘\n\n"

        # Now launch Explorer after showing the token
        printf "${BOLD}Launching Explorer...${NC}\n"

        # Pull Explorer image
        printf "├─ Pulling Explorer image\n"
        if docker compose pull influxdb3-explorer >/dev/null 2>&1; then
            printf "│  ${GREEN}Downloaded successfully${NC}\n"
        else
            printf "│  ${YELLOW}Warning: Failed to pull Explorer image${NC}\n"
            printf "│  Continuing with cached image if available\n"
        fi

        # Configure Explorer (use port 8181 for container-to-container communication)
        configure_explorer_via_file "$TOKEN" "http://${CONTAINER_NAME}:8181" "$SERVER_NAME" "$DOCKER_DIR"
        docker compose up -d influxdb3-explorer 2>&1 | filter_docker_output

        # Wait for Explorer to be ready
        if wait_for_explorer_ready 60; then
            printf "├─ Opening Explorer in browser\n"
            open_browser_url "http://localhost:${EXPLORER_PORT}/system-overview"
        fi
        printf "└─${GREEN} Done${NC}\n\n"
    else
        printf "${YELLOW}Create a token manually:${NC}\n"
        printf "  docker exec ${CONTAINER_NAME} influxdb3 create token --admin\n\n"
    fi

    # Display success message and access points AFTER Explorer launch
    printf "${BOLDGREEN}✓ InfluxDB 3 ${EDITION_NAME} with Explorer successfully deployed${NC}\n\n"
    printf "${BOLD}Access Points:${NC}\n"
    printf "├─ Explorer UI:  ${BLUE}http://localhost:${EXPLORER_PORT}${NC}\n"
    printf "├─ InfluxDB API: ${BLUE}http://localhost:${INFLUXDB_PORT}${NC}\n"
    printf "└─ Install Dir:  ${DIM}%s${NC}\n\n" "$DOCKER_DIR"

    return 0
}

# Function to find available port (for binary installation)
find_available_port() {
    show_progress="${1:-true}"
    lsof_exec=$(command -v lsof) && {
        while [ -n "$lsof_exec" ] && lsof -i:"$PORT" -t >/dev/null 2>&1; do
            if [ "$show_progress" = "true" ]; then
                printf "├─${DIM} Port %s is in use. Finding new port.${NC}\n" "$PORT"
            fi
            PORT=$((PORT + 1))
            if [ "$PORT" -gt 32767 ]; then
                printf "└─${DIM} Could not find an available port. Aborting.${NC}\n"
                exit 1
            fi
            if ! "$lsof_exec" -i:"$PORT" -t >/dev/null 2>&1; then
                if [ "$show_progress" = "true" ]; then
                    printf "└─${DIM} Found an available port: %s${NC}\n" "$PORT"
                fi
                break
            fi
        done
    }
}

# Function to set up Quick Start defaults for both Core and Enterprise
setup_quick_start_defaults() {
    edition="${1:-core}"

    NODE_ID="node0"
    STORAGE_TYPE="File Storage"
    STORAGE_PATH="$HOME/.influxdb/data"
    PLUGIN_PATH="$HOME/.influxdb/plugins"
    STORAGE_FLAGS="--object-store=file --data-dir ${STORAGE_PATH} --plugin-dir ${PLUGIN_PATH}"
    STORAGE_FLAGS_ECHO="--object-store=file --data-dir ${STORAGE_PATH} --plugin-dir ${PLUGIN_PATH}"
    START_SERVICE="y"  # Always set for Quick Start

    # Enterprise-specific settings
    if [ "$edition" = "enterprise" ]; then
        CLUSTER_ID="cluster0"
        LICENSE_FILE_PATH="${STORAGE_PATH}/${CLUSTER_ID}/trial_or_home_license"
    fi

    # Create directories
    mkdir -p "${STORAGE_PATH}"
    mkdir -p "${PLUGIN_PATH}"
}

# Function to configure AWS S3 storage
configure_aws_s3_storage() {
    echo
    printf "${BOLD}AWS S3 Configuration${NC}\n"
    printf "├─ Enter AWS Access Key ID: "
    read -r AWS_KEY

    printf "├─ Enter AWS Secret Access Key: "
    stty -echo
    read -r AWS_SECRET
    stty echo

    echo
    printf "├─ Enter S3 Bucket: "
    read -r AWS_BUCKET

    printf "└─ Enter AWS Region (default: us-east-1): "
    read -r AWS_REGION
    AWS_REGION=${AWS_REGION:-"us-east-1"}

    STORAGE_FLAGS="--object-store=s3 --bucket=${AWS_BUCKET}"
    if [ -n "$AWS_REGION" ]; then
        STORAGE_FLAGS="$STORAGE_FLAGS --aws-default-region=${AWS_REGION}"
    fi
    STORAGE_FLAGS="$STORAGE_FLAGS --aws-access-key-id=${AWS_KEY}"
    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS --aws-secret-access-key=..."
    STORAGE_FLAGS="$STORAGE_FLAGS --aws-secret-access-key=${AWS_SECRET}"
}

# Function to configure Azure storage
configure_azure_storage() {
    echo
    printf "${BOLD}Azure Storage Configuration${NC}\n"
    printf "├─ Enter Storage Account Name: "
    read -r AZURE_ACCOUNT

    printf "└─ Enter Storage Access Key: "
    stty -echo
    read -r AZURE_KEY
    stty echo

    echo
    STORAGE_FLAGS="--object-store=azure --azure-storage-account=${AZURE_ACCOUNT}"
    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS --azure-storage-access-key=..."
    STORAGE_FLAGS="$STORAGE_FLAGS --azure-storage-access-key=${AZURE_KEY}"
}

# Function to configure Google Cloud storage
configure_google_cloud_storage() {
    echo
    printf "${BOLD}Google Cloud Storage Configuration${NC}\n"
    printf "└─ Enter path to service account JSON file: "
    read -r GOOGLE_SA
    STORAGE_FLAGS="--object-store=google --google-service-account=${GOOGLE_SA}"
    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
}

# Function to set up license for Enterprise Quick Start
setup_license_for_quick_start() {
    # Check if license file exists
    if [ -f "$LICENSE_FILE_PATH" ]; then
        printf "${DIM}Found existing license file, using it for quick start.${NC}\n"
        LICENSE_TYPE=""
        LICENSE_EMAIL=""
        LICENSE_DESC="Existing"
    else
        # Prompt for license type and email only
        echo
        printf "${BOLD}License Setup Required${NC}\n"
        printf "1) ${GREEN}Trial${NC} ${DIM}- Full features for 30 days (up to 256 cores)${NC}\n"
        printf "2) ${GREEN}Home${NC} ${DIM}- Free for non-commercial use (max 2 cores, single node)${NC}\n"
        echo
        printf "Enter choice (1-2): "
        read -r LICENSE_CHOICE

        case "${LICENSE_CHOICE:-1}" in
            1)
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
            2)
                LICENSE_TYPE="home"
                LICENSE_DESC="Home"
                ;;
            *)
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
        esac

        printf "Enter your email: "
        read -r LICENSE_EMAIL
        while [ -z "$LICENSE_EMAIL" ]; do
            printf "Email is required. Enter your email: "
            read -r LICENSE_EMAIL
        done
    fi
}

# Function to prompt for storage configuration
prompt_storage_configuration() {
    # Prompt for storage solution
    echo
    printf "${BOLD}Select Your Storage Solution${NC}\n"
    printf "├─ 1) File storage (Persistent)\n"
    printf "├─ 2) Object storage (Persistent)\n"
    printf "├─ 3) In-memory storage (Non-persistent)\n"
    printf "└─ Enter your choice (1-3): "
    read -r STORAGE_CHOICE

    case "$STORAGE_CHOICE" in
        1)
            STORAGE_TYPE="File Storage"
            echo
            printf "Enter storage path (default: %s/data): " "${INSTALL_LOC}"
            read -r STORAGE_PATH
            STORAGE_PATH=${STORAGE_PATH:-"$INSTALL_LOC/data"}
            STORAGE_FLAGS="--object-store=file --data-dir ${STORAGE_PATH}"
            STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
            ;;
        2)
            STORAGE_TYPE="Object Storage"
            echo
            printf "${BOLD}Select Cloud Provider${NC}\n"
            printf "├─ 1) Amazon S3\n"
            printf "├─ 2) Azure Storage\n"
            printf "├─ 3) Google Cloud Storage\n"
            printf "└─ Enter your choice (1-3): "
            read -r CLOUD_CHOICE

            case $CLOUD_CHOICE in
                1)  # AWS S3
                    configure_aws_s3_storage
                    ;;

                2)  # Azure Storage
                    configure_azure_storage
                    ;;

                3)  # Google Cloud Storage
                    configure_google_cloud_storage
                    ;;

                *)
                    printf "Invalid cloud provider choice. Defaulting to file storage.\n"
                    STORAGE_TYPE="File Storage"
                    STORAGE_FLAGS="--object-store=file --data-dir $INSTALL_LOC/data"
                    STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
                    ;;
            esac
            ;;
        3)
            STORAGE_TYPE="memory"
            STORAGE_FLAGS="--object-store=memory"
            STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
            ;;

        *)
            printf "Invalid choice. Defaulting to file storage.\n"
            STORAGE_TYPE="File Storage"
            STORAGE_FLAGS="--object-store=file --data-dir $INSTALL_LOC/data"
            STORAGE_FLAGS_ECHO="$STORAGE_FLAGS"
            ;;
    esac
}

# Function to perform health check on server
perform_server_health_check() {
    timeout_seconds="${1:-30}"
    is_enterprise="${2:-false}"

    SUCCESS=0
    EMAIL_MESSAGE_SHOWN=false

    for i in $(seq 1 "$timeout_seconds"); do
        # on systems without a usable lsof, sleep a second to see if the pid is
        # still there to give influxdb a chance to error out in case an already
        # running influxdb is running on this port
        if [ -z "$lsof_exec" ]; then
            sleep 1
        fi

        if ! kill -0 "$PID" 2>/dev/null ; then
            if [ "$is_enterprise" = "true" ]; then
                printf "└─${DIM} Server process stopped unexpectedly${NC}\n"
            fi
            break
        fi

        if curl --max-time 1 -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
            printf "\n${BOLDGREEN}✓ InfluxDB 3 ${EDITION} is now installed and running on port %s. Nice!${NC}\n" "$PORT"
            SUCCESS=1
            break
        fi

        # Show email verification message after 10 seconds for Enterprise
        if [ "$is_enterprise" = "true" ] && [ "$i" -eq 10 ] && [ "$EMAIL_MESSAGE_SHOWN" = "false" ]; then
            printf "├─${YELLOW} License activation requires email verification${NC}\n"
            printf "├─${BOLD} → Check your inbox and click the verification link${NC}\n"
            EMAIL_MESSAGE_SHOWN=true
        fi

        # Show progress updates every 15 seconds after initial grace period
        if [ "$is_enterprise" = "true" ] && [ "$i" -gt 5 ] && [ $((i % 15)) -eq 0 ]; then
            printf "├─${DIM} Waiting for license verification (%s/%ss)${NC}\n" "$i" "$timeout_seconds"
        fi

        sleep 1
    done

    if [ $SUCCESS -eq 0 ]; then
        if [ "$is_enterprise" = "true" ]; then
            printf "└─${BOLD} Error: InfluxDB Enterprise failed to start within %s seconds${NC}\n\n" "$timeout_seconds"
            if [ "$show_progress" = "true" ]; then
                printf "${BOLD}This may be due to:${NC}\n"
                printf "   ├─${YELLOW} Email verification required${NC} ${BOLD}(MOST COMMON ISSUE)${NC}\n"
                printf "   │  ${BOLD}→ Check your inbox and click the verification link${NC}\n"
                printf "   ├─ Network connectivity issues during license retrieval\n"
                printf "   ├─ Invalid license type or email format\n"
                printf "   ├─ Port %s already in use\n" "$PORT"
                printf "   └─ Server startup issues\n"
            else
                if [ -n "$LICENSE_TYPE" ]; then
                    printf "   ├─${YELLOW} Check your email for license verification${NC} ${BOLD}(REQUIRED)${NC}\n"
                    printf "   │  ${BOLD}→ Click the verification link in your inbox${NC}\n"
                fi
                printf "   ├─ Network connectivity issues\n"
                printf "   └─ Port %s conflicts\n" "$PORT"
            fi

            # Kill the background process if it's still running
            if kill -0 "$PID" 2>/dev/null; then
                printf "   Stopping background server process...\n"
                kill "$PID" 2>/dev/null
            fi
        else
            printf "└─${BOLD} Error: InfluxDB failed to start; check permissions or other potential issues.${NC}\n"
            exit 1
        fi
    fi
}

# Function to display Enterprise server command
display_enterprise_server_command() {
    is_quick_start="${1:-false}"

    if [ "$is_quick_start" = "true" ]; then
        # Quick Start format
        printf "└─${DIM} Command: ${NC}\n"
        printf "${DIM}   influxdb3 serve \\\\${NC}\n"
        printf "${DIM}   --cluster-id=%s \\\\${NC}\n" "$CLUSTER_ID"
        printf "${DIM}   --node-id=%s \\\\${NC}\n" "$NODE_ID"
        if [ -n "$LICENSE_TYPE" ] && [ -n "$LICENSE_EMAIL" ]; then
            printf "${DIM}   --license-type=%s \\\\${NC}\n" "$LICENSE_TYPE"
            printf "${DIM}   --license-email=%s \\\\${NC}\n" "$LICENSE_EMAIL"
        fi
        printf "${DIM}   --http-bind=0.0.0.0:%s \\\\${NC}\n" "$PORT"
        printf "${DIM}   %s${NC}\n" "$STORAGE_FLAGS_ECHO"
        echo
    else
        # Custom configuration format
        printf "│\n"
        printf "├─ Running serve command:\n"
        printf "├─${DIM} influxdb3 serve \\\\${NC}\n"
        printf "├─${DIM} --cluster-id='%s' \\\\${NC}\n" "$CLUSTER_ID"
        printf "├─${DIM} --node-id='%s' \\\\${NC}\n" "$NODE_ID"
        printf "├─${DIM} --license-type='%s' \\\\${NC}\n" "$LICENSE_TYPE"
        printf "├─${DIM} --license-email='%s' \\\\${NC}\n" "$LICENSE_EMAIL"
        printf "├─${DIM} --http-bind='0.0.0.0:%s' \\\\${NC}\n" "$PORT"
        printf "├─${DIM} %s${NC}\n" "$STORAGE_FLAGS_ECHO"
        printf "│\n"
    fi
}

# =========================Installation==========================

# Attempt to clear screen and show welcome message
clear 2>/dev/null || true
printf "┌───────────────────────────────────────────────────┐\n"
printf "│ ${BOLD}Welcome to InfluxDB!${NC} We'll make this quick.       │\n"
printf "└───────────────────────────────────────────────────┘\n"

printf "\n"
printf "${BOLD}Select Installation Type${NC}\n"
printf "\n"
printf "1) ${GREEN}Docker Compose${NC}  ${DIM}(Installs InfluxDB 3 %s + Explorer UI)${NC}\n" "$EDITION"
printf "2) ${GREEN}Simple Download${NC} ${DIM}(Binary installation, no dependencies)${NC}\n"
printf "\n"
printf "Enter your choice (1-2): "
read -r INSTALL_TYPE

case "$INSTALL_TYPE" in
    1)
        # Docker Compose installation
        if ! check_docker; then
            printf "\n${RED}Error:${NC} Docker is not installed or not running.\n"
            printf "Please install Docker Desktop and try again.\n"
            printf "Visit: ${BLUE}https://www.docker.com/products/docker-desktop${NC}\n\n"
            exit 1
        fi
        
        # Set default installation directory
        DOCKER_DIR="$HOME/.influxdb/docker"
        
        # Check if directory exists
        if [ -d "$DOCKER_DIR" ] && [ -f "$DOCKER_DIR/docker-compose.yml" ]; then
            printf "\n${YELLOW}Notice:${NC} Existing installation found at %s\n" "$DOCKER_DIR"
            printf "\nChoose an option:\n"
            printf "1) Restart existing setup (keeps data and token)\n"
            printf "2) Clean install ${DIM}(stops containers, deletes %s directory)${NC}\n" "$DOCKER_DIR"
            printf "3) Exit\n"
            printf "Enter choice (1-3): "
            read -r EXISTING_CHOICE
            
            case "$EXISTING_CHOICE" in
                1)
                    cd "$DOCKER_DIR"
                    printf "\nRestarting existing setup...\n"
                    docker compose down 2>/dev/null || true
                    sleep 2
                    docker compose up -d 2>&1 | grep -v "version.*obsolete" | grep -v "Creating$" | grep -v "Created$" | grep -v "Starting$" | grep -v "Started$" | grep -v "Running$" || true
                    
                    printf "\n${BOLDGREEN}✓ Setup restarted successfully${NC}\n\n"
                    printf "${BOLD}Access Points:${NC}\n"
                    printf "├─ Explorer UI:  ${BLUE}http://localhost:8888${NC}\n"
                    printf "└─ InfluxDB API: ${BLUE}http://localhost:8181${NC}\n\n"
                    exit 0
                    ;;
                2)
                    printf "\nPerforming clean install...\n"
                    cd "$DOCKER_DIR"
                    docker compose down 2>/dev/null || true
                    cd ..
                    rm -rf "$DOCKER_DIR"
                    ;;
                3)
                    printf "Setup cancelled.\n"
                    exit 0
                    ;;
                *)
                    printf "${RED}Invalid choice.${NC} Setup cancelled.\n"
                    exit 1
                    ;;
            esac
        fi
        
        # Run appropriate setup based on edition
        if [ "$EDITION" = "Enterprise" ]; then
            setup_docker_compose "enterprise" "$DOCKER_DIR"
        else
            setup_docker_compose "core" "$DOCKER_DIR"
        fi

        exit 0
        ;;
    2)
        # Binary installation selected - check for existing binary installation
        detect_existing_installations
        if [ "$BINARY_FOUND" = true ]; then
            printf "\n${YELLOW}Notice:${NC} Existing binary installation found at %s/influxdb3\n" "$INSTALL_LOC"
            if [ -n "$BINARY_VERSION" ]; then
                printf "Current version: %s\n" "$BINARY_VERSION"
                printf "New version: %s\n" "$INFLUXDB_VERSION"
            fi
            if [ -n "$BINARY_DATA_SIZE" ]; then
                printf "Data directory: %s/data (%s) ${GREEN}will be preserved${NC}\n" "$INSTALL_LOC" "$BINARY_DATA_SIZE"
            fi
            printf "\nChoose an option:\n"
            printf "1) Continue installation (upgrade/reinstall, keeps data)\n"
            printf "2) Exit\n"
            printf "Enter choice (1-2): "
            read -r BINARY_EXISTING_CHOICE

            case "$BINARY_EXISTING_CHOICE" in
                1)
                    printf "\nProceeding with installation...\n"
                    ;;
                2)
                    printf "Installation cancelled.\n"
                    exit 0
                    ;;
                *)
                    printf "${RED}Invalid choice.${NC} Installation cancelled.\n"
                    exit 1
                    ;;
            esac
        fi
        printf "\n\n"
        ;;
    *)
        printf "Invalid choice. Defaulting to binary installation.\n\n"
        ;;
esac

# attempt to find the user's shell config
shellrc=
if [ -n "$SHELL" ]; then
    tmp=~/.$(basename "$SHELL")rc
    if [ -e "$tmp" ]; then
        shellrc="$tmp"
    fi
fi

printf "${BOLD}Downloading InfluxDB 3 %s to %s${NC}\n" "$EDITION" "$INSTALL_LOC"
printf "├─${DIM} mkdir -p '%s'${NC}\n" "$INSTALL_LOC"
mkdir -p "$INSTALL_LOC"
printf "└─${DIM} curl -sSL '%s' -o '%s/influxdb3-${EDITION_TAG}.tar.gz'${NC}\n" "${URL}" "$INSTALL_LOC"
curl -sSL "${URL}" -o "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz"

echo
printf "${BOLD}Verifying '%s/influxdb3-${EDITION_TAG}.tar.gz'${NC}\n" "$INSTALL_LOC"
printf "└─${DIM} curl -sSL '%s.sha256' -o '%s/influxdb3-${EDITION_TAG}.tar.gz.sha256'${NC}\n" "${URL}" "$INSTALL_LOC"
curl -sSL "${URL}.sha256" -o "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz.sha256"
dl_sha=$(cut -d ' ' -f 1 "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz.sha256" | grep -E '^[0-9a-f]{64}$')
if [ -z "$dl_sha" ]; then
    printf "Could not find properly formatted SHA256 in '%s/influxdb3-${EDITION_TAG}.tar.gz.sha256'. Aborting.\n" "$INSTALL_LOC"
    exit 1
fi

ch_sha=
if [ "${OS}" = "Darwin" ]; then
    printf "└─${DIM} shasum -a 256 '%s/influxdb3-${EDITION_TAG}.tar.gz'" "$INSTALL_LOC"
    ch_sha=$(shasum -a 256 "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" | cut -d ' ' -f 1)
else
    printf "└─${DIM} sha256sum '%s/influxdb3-${EDITION_TAG}.tar.gz'" "$INSTALL_LOC"
    ch_sha=$(sha256sum "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" | cut -d ' ' -f 1)
fi
if [ "$ch_sha" = "$dl_sha" ]; then
    printf " (OK: %s = %s)${NC}\n" "$ch_sha" "$dl_sha"
else
    printf " (Error: %s != %s). Aborting.${NC}\n" "$ch_sha" "$dl_sha"
    exit 1
fi
printf "└─${DIM} rm '%s/influxdb3-${EDITION_TAG}.tar.gz.sha256'${NC}\n" "$INSTALL_LOC"
rm "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz.sha256"

printf "\n"
printf "${BOLD}Extracting and Processing${NC}\n"

# some tarballs have a leading component, check for that
TAR_LEVEL=0
if tar -tf "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" | grep -q '[a-zA-Z0-9]/influxdb3$' ; then
    TAR_LEVEL=1
fi
printf "├─${DIM} tar -xf '%s/influxdb3-${EDITION_TAG}.tar.gz' --strip-components=${TAR_LEVEL} -C '%s'${NC}\n" "$INSTALL_LOC" "$INSTALL_LOC"
tar -xf "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz" --strip-components="${TAR_LEVEL}" -C "$INSTALL_LOC"

printf "└─${DIM} rm '%s/influxdb3-${EDITION_TAG}.tar.gz'${NC}\n" "$INSTALL_LOC"
rm "$INSTALL_LOC/influxdb3-${EDITION_TAG}.tar.gz"

if [ -n "$shellrc" ] && ! grep -q "export PATH=.*$INSTALL_LOC" "$shellrc"; then
    echo
    printf "${BOLD}Adding InfluxDB to '%s'${NC}\n" "$shellrc"
    printf "└─${DIM} export PATH=\"\$PATH:%s/\" >> '%s'${NC}\n" "$INSTALL_LOC" "$shellrc"
    echo "export PATH=\"\$PATH:$INSTALL_LOC/\"" >> "$shellrc"
fi

export INFLUXDB3_SERVE_INVOCATION_METHOD="install-script"

if [ "${EDITION}" = "Core" ]; then
    # Prompt user for startup options
    echo
    printf "${BOLD}What would you like to do next?${NC}\n"
    printf "1) ${GREEN}Quick Start${NC} ${DIM}(recommended; data stored at %s/data)${NC}\n" "${INSTALL_LOC}"
    printf "2) ${GREEN}Custom Configuration${NC} ${DIM}(configure all options manually)${NC}\n"
    printf "3) ${GREEN}Skip startup${NC} ${DIM}(install only)${NC}\n"
    echo
    printf "Enter your choice (1-3): "
    read -r STARTUP_CHOICE
    STARTUP_CHOICE=${STARTUP_CHOICE:-1}

    case "$STARTUP_CHOICE" in
        1)
            # Quick Start - use defaults
            setup_quick_start_defaults core
            ;;
        2)
            # Custom Configuration - existing detailed flow
            START_SERVICE="y"
            ;;
        3)
            # Skip startup
            START_SERVICE="n"
            ;;
        *)
            printf "Invalid choice. Using Quick Start (option 1).\n"
            setup_quick_start_defaults core
            ;;
    esac

    if [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "2" ]; then
        # Prompt for Node ID
        echo
        printf "${BOLD}Enter Your Node ID${NC}\n"
        printf "├─ A Node ID is a unique, uneditable identifier for a service.\n"
        printf "└─ Enter a Node ID (default: node0): "
        read -r NODE_ID
        NODE_ID=${NODE_ID:-node0}

        # Prompt for storage solution
        prompt_storage_configuration

        # Ensure port is available; if not, find a new one.
        find_available_port

        # Start and give up to 30 seconds to respond
        echo

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"

        printf "${BOLD}Starting InfluxDB${NC}\n"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        printf "├─${DIM} Storage: %s${NC}\n" "$STORAGE_TYPE"
        printf "├─${DIM} Logs: %s${NC}\n" "$LOG_FILE"
        printf "├─${DIM} influxdb3 serve \\\\${NC}\n"
        printf "├─${DIM}   --node-id='%s' \\\\${NC}\n" "$NODE_ID"
        printf "├─${DIM}   --http-bind='0.0.0.0:%s' \\\\${NC}\n" "$PORT"
        printf "└─${DIM}   %s${NC}\n" "$STORAGE_FLAGS_ECHO"

        "$INSTALL_LOC/$BINARY_NAME" serve --node-id="$NODE_ID" --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        PID="$!"

        perform_server_health_check 30

    elif [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "1" ]; then
        # Quick Start flow - minimal output, just start the server
        echo
        printf "${BOLD}Starting InfluxDB (Quick Start)${NC}\n"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        printf "├─${DIM} Storage: %s/data${NC}\n" "${INSTALL_LOC}"
        printf "├─${DIM} Plugins: %s/plugins${NC}\n" "${INSTALL_LOC}"
        printf "├─${DIM} Logs: %s/logs/$(date +%Y%m%d_%H%M%S).log${NC}\n" "${INSTALL_LOC}"

        # Ensure port is available; if not, find a new one.
        ORIGINAL_PORT="$PORT"
        find_available_port false

        # Show port result
        if [ "$PORT" != "$ORIGINAL_PORT" ]; then
            printf "├─${DIM} Found available port: %s (%s-%s in use)${NC}\n" "$PORT" "$ORIGINAL_PORT" "$((PORT - 1))"
        fi

        # Show the command being executed
        printf "└─${DIM} Command:${NC}\n"
        printf "${DIM}    influxdb3 serve \\\\${NC}\n"
        printf "${DIM}     --node-id=%s \\\\${NC}\n" "$NODE_ID"
        printf "${DIM}     --http-bind=0.0.0.0:%s \\\\${NC}\n" "$PORT"
        printf "${DIM}     %s${NC}\n\n" "$STORAGE_FLAGS_ECHO"

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"

        # Start server in background
        "$INSTALL_LOC/$BINARY_NAME" serve --node-id="$NODE_ID" --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        PID="$!"

        perform_server_health_check 30

    else
        echo
        printf "${BOLDGREEN}✓ InfluxDB 3 ${EDITION} is now installed. Nice!${NC}\n"
    fi
else
    # Enterprise startup options
    echo
    printf "${BOLD}What would you like to do next?${NC}\n"
    printf "1) ${GREEN}Quick Start${NC} ${DIM}(recommended; data stored at %s/data)${NC}\n" "${INSTALL_LOC}"
    printf "2) ${GREEN}Custom Configuration${NC} ${DIM}(configure all options manually)${NC}\n"
    printf "3) ${GREEN}Skip startup${NC} ${DIM}(install only)${NC}\n"
    echo
    printf "Enter your choice (1-3): "
    read -r STARTUP_CHOICE
    STARTUP_CHOICE=${STARTUP_CHOICE:-1}

    case "$STARTUP_CHOICE" in
        1|*)
            # Quick Start - use defaults and check for existing license
            if [ "$STARTUP_CHOICE" != "1" ]; then
                printf "Invalid choice. Using Quick Start (option 1).\n"
            fi
            setup_quick_start_defaults enterprise
            setup_license_for_quick_start
            STORAGE_FLAGS="--object-store=file --data-dir ${STORAGE_PATH} --plugin-dir ${PLUGIN_PATH}"
            STORAGE_FLAGS_ECHO="--object-store=file --data-dir ${STORAGE_PATH} --plugin-dir ${PLUGIN_PATH}"
            START_SERVICE="y"
            ;;
        2)
            # Custom Configuration - existing detailed flow
            START_SERVICE="y"
            ;;
        3)
            # Skip startup
            START_SERVICE="n"
            ;;
    esac

    if [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "1" ]; then
        # Enterprise Quick Start flow
        echo
        printf "${BOLD}Starting InfluxDB Enterprise (Quick Start)${NC}\n"
        printf "├─${DIM} Cluster ID: %s${NC}\n" "$CLUSTER_ID"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        if [ -n "$LICENSE_TYPE" ]; then
            printf "├─${DIM} License Type: %s${NC}\n" "$LICENSE_DESC"
        fi
        if [ -n "$LICENSE_EMAIL" ]; then
            printf "├─${DIM} Email: %s${NC}\n" "$LICENSE_EMAIL"
        fi
        printf "├─${DIM} Storage: %s/data${NC}\n" "${INSTALL_LOC}"
        printf "├─${DIM} Plugins: %s/plugins${NC}\n" "${INSTALL_LOC}"

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"
        printf "├─${DIM} Logs: %s${NC}\n" "$LOG_FILE"

        # Ensure port is available; if not, find a new one.
        ORIGINAL_PORT="$PORT"
        find_available_port false

        # Show port result
        if [ "$PORT" != "$ORIGINAL_PORT" ]; then
            printf "├─${DIM} Found available port: %s (%s-%s in use)${NC}\n" "$PORT" "$ORIGINAL_PORT" "$((PORT - 1))"
        fi

        # Show the command being executed
        display_enterprise_server_command true

        # Start server in background with or without license flags
        if [ -n "$LICENSE_TYPE" ] && [ -n "$LICENSE_EMAIL" ]; then
            # New license needed
            "$INSTALL_LOC/$BINARY_NAME" serve --cluster-id="$CLUSTER_ID" --node-id="$NODE_ID" --license-type="$LICENSE_TYPE" --license-email="$LICENSE_EMAIL" --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        else
            # Existing license file
            "$INSTALL_LOC/$BINARY_NAME" serve --cluster-id="$CLUSTER_ID" --node-id="$NODE_ID" --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        fi
        PID="$!"

        printf "├─${DIM} Server started in background (PID: %s)${NC}\n" "$PID"

        perform_server_health_check 90 true

    elif [ "$START_SERVICE" = "y" ] && [ "$STARTUP_CHOICE" = "2" ]; then
        # Enterprise Custom Start flow
        echo
        # Prompt for Cluster ID
        printf "${BOLD}Enter Your Cluster ID${NC}\n"
        printf "├─ A Cluster ID determines part of the storage path hierarchy.\n"
        printf "├─ All nodes within the same cluster share this identifier.\n"
        printf "└─ Enter a Cluster ID (default: cluster0): "
        read -r CLUSTER_ID
        CLUSTER_ID=${CLUSTER_ID:-cluster0}

        # Prompt for Node ID
        echo
        printf "${BOLD}Enter Your Node ID${NC}\n"
        printf "├─ A Node ID distinguishes individual server instances within the cluster.\n"
        printf "└─ Enter a Node ID (default: node0): "
        read -r NODE_ID
        NODE_ID=${NODE_ID:-node0}

        # Prompt for license type
        echo
        printf "${BOLD}Select Your License Type${NC}\n"
        printf "├─ 1) Trial - Full features for 30 days (up to 256 cores)\n"
        printf "├─ 2) Home - Free for non-commercial use (max 2 cores, single node)\n"
        printf "└─ Enter your choice (1-2): "
        read -r LICENSE_CHOICE

        case "$LICENSE_CHOICE" in
            1)
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
            2)
                LICENSE_TYPE="home"
                LICENSE_DESC="Home"
                ;;
            *)
                printf "Invalid choice. Defaulting to trial.\n"
                LICENSE_TYPE="trial"
                LICENSE_DESC="Trial"
                ;;
        esac

        # Prompt for email
        echo
        printf "${BOLD}Enter Your Email Address${NC}\n"
        printf "├─ Required for license verification and activation\n"
        printf "├─${YELLOW} IMPORTANT: You MUST verify your email to activate the license${NC}\n"
        printf "├─${BOLD} → Check your inbox after entering your email${NC}\n"
        printf "└─ Email: "
        read -r LICENSE_EMAIL

        while [ -z "$LICENSE_EMAIL" ]; do
            printf "├─ Email address is required. Please enter your email: "
            read -r LICENSE_EMAIL
        done

        # Prompt for storage solution
        prompt_storage_configuration

        # Ensure port is available; if not, find a new one.
        find_available_port

        # Start Enterprise in background with licensing and give up to 90 seconds to respond (licensing takes longer)
        echo
        printf "${BOLD}Starting InfluxDB Enterprise${NC}\n"
        printf "├─${DIM} Cluster ID: %s${NC}\n" "$CLUSTER_ID"
        printf "├─${DIM} Node ID: %s${NC}\n" "$NODE_ID"
        printf "├─${DIM} License Type: %s${NC}\n" "$LICENSE_DESC"
        printf "├─${DIM} Email: %s${NC}\n" "$LICENSE_EMAIL"
        printf "├─${DIM} Storage: %s${NC}\n" "$STORAGE_TYPE"

        # Create logs directory and generate timestamped log filename
        mkdir -p "$INSTALL_LOC/logs"
        LOG_FILE="$INSTALL_LOC/logs/$(date +%Y%m%d_%H%M%S).log"
        printf "├─${DIM} Logs: %s${NC}\n" "$LOG_FILE"

        display_enterprise_server_command false

        # Start server in background
        "$INSTALL_LOC/$BINARY_NAME" serve --cluster-id="$CLUSTER_ID" --node-id="$NODE_ID" --license-type="$LICENSE_TYPE" --license-email="$LICENSE_EMAIL" --http-bind="0.0.0.0:$PORT" $STORAGE_FLAGS >> "$LOG_FILE" 2>&1 &
        PID="$!"

        printf "├─${DIM} Server started in background (PID: %s)${NC}\n" "$PID"

        perform_server_health_check 90 true

    else
        echo
        printf "${BOLDGREEN}✓ InfluxDB 3 ${EDITION} is now installed. Nice!${NC}\n"
    fi
fi

### SUCCESS INFORMATION ###
printf "\n"
if [ "${EDITION}" = "Enterprise" ] && [ "$SUCCESS" -eq 0 ] 2>/dev/null; then
    printf "${BOLD}Server startup failed${NC} - troubleshooting options:\n"
    printf "├─ ${BOLD}${YELLOW}Check email verification:${NC} ${BOLD}Look for verification email and click the link${NC}\n"
    printf "├─ ${BOLD}   → This is the most common issue for Enterprise activation${NC}\n"
    printf "├─ ${BOLD}Manual startup:${NC} Try running the server manually to see detailed logs:\n"
    printf "     influxdb3 serve \\\\\n"
    printf "     --cluster-id=%s \\\\\n" "${CLUSTER_ID:-cluster0}"
    printf "     --node-id=%s \\\\\n" "${NODE_ID:-node0}"
    printf "     --license-type=%s \\\\\n" "${LICENSE_TYPE:-trial}"
    printf "     --license-email=%s \\\\\n" "${LICENSE_EMAIL:-your@email.com}"
    printf "     %s\n" "${STORAGE_FLAGS_ECHO:-"--object-store=file --data-dir $INSTALL_LOC/data --plugin-dir $INSTALL_LOC/plugins"}"
    printf "└─ ${BOLD}Common issues:${NC} Network connectivity, invalid email format, port conflicts\n"
else
    printf "${BOLD}Next Steps${NC}\n"
    if [ -n "$shellrc" ]; then
        printf "├─ Run ${BOLD}source '%s'${NC}, then access InfluxDB with ${BOLD}influxdb3${NC} command.\n" "$shellrc"
    else
        printf "├─ Access InfluxDB with the ${BOLD}influxdb3${NC} command.\n"
    fi
    printf "├─ Create admin token: ${BOLD}influxdb3 create token --admin${NC}\n"
    printf "└─ Begin writing data! Learn more at https://docs.influxdata.com/influxdb3/${EDITION_TAG}/get-started/write/\n\n"
fi

printf "┌────────────────────────────────────────────────────────────────────────────────────────┐\n"
printf "│ Looking to use a UI for querying, plugins, management, and more?                       │\n"
printf "│ Get InfluxDB 3 Explorer at ${BLUE}https://docs.influxdata.com/influxdb3/explorer/#quick-start${NC} │\n"
printf "└────────────────────────────────────────────────────────────────────────────────────────┘\n\n"