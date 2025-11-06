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
        if [ "$show_progress" = "true" ]; then
            printf "├─${DIM} Port %s is in use. Finding new port.${NC}\n" "$INFLUXDB_PORT"
        fi
        INFLUXDB_PORT=$((INFLUXDB_PORT + 1))
        if [ "$INFLUXDB_PORT" -gt 32767 ]; then
            printf "└─${RED} Could not find an available port for InfluxDB. Aborting.${NC}\n"
            exit 1
        fi
    done

    if [ "$INFLUXDB_PORT" != "$ORIGINAL_INFLUXDB_PORT" ] && [ "$show_progress" = "true" ]; then
        printf "├─${DIM} Found available InfluxDB port: %s${NC}\n" "$INFLUXDB_PORT"
    fi

    # Check Explorer port
    ORIGINAL_EXPLORER_PORT=$EXPLORER_PORT
    while lsof -i:"$EXPLORER_PORT" -t >/dev/null 2>&1; do
        if [ "$show_progress" = "true" ]; then
            printf "├─${DIM} Port %s is in use. Finding new port.${NC}\n" "$EXPLORER_PORT"
        fi
        EXPLORER_PORT=$((EXPLORER_PORT + 1))
        if [ "$EXPLORER_PORT" -gt 32767 ]; then
            printf "└─${RED} Could not find an available port for Explorer. Aborting.${NC}\n"
            exit 1
        fi
    done

    if [ "$EXPLORER_PORT" != "$ORIGINAL_EXPLORER_PORT" ] && [ "$show_progress" = "true" ]; then
        printf "├─${DIM} Found available Explorer port: %s${NC}\n" "$EXPLORER_PORT"
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

    printf "├─ Starting InfluxDB"
    ELAPSED=0

    while [ $ELAPSED -lt $TIMEOUT ]; do
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "$READY_MESSAGE"; then
            printf "${NC}\n"
            printf "├─${GREEN} InfluxDB is ready${NC}\n"
            return 0
        fi

        if ! docker ps | grep -q "$CONTAINER_NAME"; then
            printf "${NC}\n"
            printf "├─${RED} ERROR: InfluxDB container stopped unexpectedly${NC}\n"
            docker logs --tail 20 "$CONTAINER_NAME"
            return 1
        fi

        if [ $ELAPSED -eq $((TIMEOUT - 1)) ]; then
            printf "${NC}\n"
            printf "├─${RED} ERROR: InfluxDB failed to start within ${TIMEOUT} seconds${NC}\n"
            return 1
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

# Function to configure Explorer via API
configure_explorer_via_api() {
    TOKEN="$1"
    INFLUXDB_URL="$2"
    SERVER_NAME="$3"
    
    printf "├─ Configuring Explorer via API...\n"
    
    # Wait for Explorer API to be ready
    TIMEOUT=30
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if curl -s http://localhost:8888/api/health >/dev/null 2>&1; then
            break
        fi
        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done
    
    # Create the connection configuration via API
    RESPONSE=$(curl -s -X POST http://localhost:8888/api/connections \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${SERVER_NAME}\",
            \"url\": \"${INFLUXDB_URL}\",
            \"token\": \"${TOKEN}\",
            \"database\": \"mydb\"
        }" 2>&1)
    
    if echo "$RESPONSE" | grep -q "error\|Error"; then
        # API configuration failed, fall back to file-based config
        return 1
    fi
    
    return 0
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

    printf "├─ Creating directories...\n"
    create_docker_directories "$DOCKER_DIR"

    # Check for available ports
    find_available_ports

    # Generate session secret
    SESSION_SECRET=$(generate_session_secret)

    printf "├─ Creating docker-compose.yml...\n"
    generate_docker_compose_yaml "$EDITION_TYPE" "$SESSION_SECRET" "$LICENSE_EMAIL" "$DOCKER_DIR"

    printf "├─ Pulling Docker images...\n"
    cd "$DOCKER_DIR"
    docker compose pull 2>&1 | filter_docker_output
    docker compose up -d "$CONTAINER_NAME" 2>&1 | filter_docker_output

    # Wait for InfluxDB to be ready
    if ! wait_for_container_ready "$CONTAINER_NAME" "startup time:" 60; then
        return 1
    fi

    # Enterprise-specific: Show email message during wait if needed
    if [ "$EDITION_TYPE" = "enterprise" ] && [ -n "$LICENSE_TYPE" ]; then
        printf "├─${DIM} License activation may require email verification${NC}\n"
    fi

    sleep 2

    # Create operator token
    printf "├─ Creating operator token...\n"
    TOKEN=$(create_operator_token "$CONTAINER_NAME")

    if [ "$TOKEN" != "$MANUAL_TOKEN_MSG" ]; then
        printf "├─${GREEN} Token created successfully${NC}\n"

        # Configure Explorer (use port 8181 for container-to-container communication)
        configure_explorer_via_file "$TOKEN" "http://${CONTAINER_NAME}:8181" "$SERVER_NAME" "$DOCKER_DIR"
        docker compose up -d influxdb3-explorer 2>&1 | filter_docker_output

        # Wait for Explorer to be ready
        if wait_for_explorer_ready 60; then
            # Open browser
            printf "├─ Opening Explorer in browser...\n"
            open_browser_url "http://localhost:${EXPLORER_PORT}"
        fi
    fi

    printf "└─${GREEN} Configuration complete${NC}\n\n"

    # Display success message
    printf "${BOLDGREEN}✓ InfluxDB 3 ${EDITION_NAME} with Explorer successfully deployed${NC}\n\n"
    printf "${BOLD}Access Points:${NC}\n"
    printf "├─ Explorer UI:  ${BLUE}http://localhost:${EXPLORER_PORT}${NC}\n"
    printf "├─ InfluxDB API: ${BLUE}http://localhost:${INFLUXDB_PORT}${NC}\n"
    printf "└─ Install Dir:  ${DIM}%s${NC}\n\n" "$DOCKER_DIR"

    # Display token
    if [ "$TOKEN" != "$MANUAL_TOKEN_MSG" ]; then
        printf "┌──────────────────────────────────────────────────────────────────────────────────────────────┐\n"
        printf "│ ${BOLD}OPERATOR TOKEN${NC}                                                                               │\n"
        printf "├──────────────────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ %s │\n" "$TOKEN"
        printf "├──────────────────────────────────────────────────────────────────────────────────────────────┤\n"
        printf "│ ${RED}IMPORTANT:${NC} Save this token securely. It cannot be retrieved later.                           │\n"
        printf "└──────────────────────────────────────────────────────────────────────────────────────────────┘\n\n"
    else
        printf "${YELLOW}Create a token manually:${NC}\n"
        printf "  docker exec ${CONTAINER_NAME} influxdb3 create token --admin\n\n"
    fi

    return 0
}

# Legacy wrapper for backward compatibility
setup_docker_compose_core() {
    setup_docker_compose "core" "$@"
}

# Legacy wrapper for backward compatibility
setup_docker_compose_enterprise() {
    DOCKER_DIR="${1:-$HOME/.influxdb/docker}"
    LICENSE_EMAIL="${2:-}"
    LICENSE_TYPE="${3:-}"
    setup_docker_compose "enterprise" "$DOCKER_DIR" "$LICENSE_EMAIL" "$LICENSE_TYPE"
}

# [Keep all other existing functions unchanged from original script]

# =========================Installation==========================

# Attempt to clear screen and show welcome message
clear 2>/dev/null || true
printf "┌───────────────────────────────────────────────────┐\n"
printf "│ ${BOLD}Welcome to InfluxDB!${NC} We'll make this quick.       │\n"
printf "└───────────────────────────────────────────────────┘\n"

echo
printf "${BOLD}Select Installation Type${NC}\n"
echo
printf "1) ${GREEN}Docker Compose${NC}  ${DIM}(Recommended - includes Explorer UI)${NC}\n"
printf "2) ${GREEN}Simple Download${NC} ${DIM}(Binary installation, no dependencies)${NC}\n"
echo
printf "Enter your choice (1-2): "
read -r INSTALL_TYPE

case "$INSTALL_TYPE" in
    1)
        # Docker Compose installation
        if ! check_docker; then
            printf "\n${RED}ERROR:${NC} Docker is not installed or not running.\n"
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
            printf "2) Clean install (deletes all data and creates new token)\n"
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
                    
                    if [ -f "explorer/config/config.json" ]; then
                        EXISTING_TOKEN=$(grep -oE '(apiv3|idb3)_[a-zA-Z0-9_-]+' explorer/config/config.json | head -1)
                        printf "\n${BOLDGREEN}✓ Setup restarted successfully${NC}\n\n"
                        printf "${BOLD}Access Points:${NC}\n"
                        printf "├─ Explorer UI:  ${BLUE}http://localhost:8888${NC}\n"
                        printf "└─ InfluxDB API: ${BLUE}http://localhost:8181${NC}\n\n"
                        if [ -n "$EXISTING_TOKEN" ]; then
                            printf "${BOLD}Existing Operator Token:${NC}\n"
                            printf "  %s\n\n" "$EXISTING_TOKEN"
                        fi
                    fi
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
            setup_docker_compose_enterprise "$DOCKER_DIR"
        else
            setup_docker_compose_core "$DOCKER_DIR"
        fi

        exit 0
        ;;
    2)
        printf "\n\n"
        ;;
    *)
        printf "Invalid choice. Defaulting to binary installation.\n\n"
        ;;
esac

# [Rest of the binary installation code remains unchanged from the original script]