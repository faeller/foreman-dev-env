#!/bin/bash
# foreman dev environment setup
# usage: ./setup.sh                 # production mode (official images)
#        ./setup.sh --source        # development mode (from git source)
#        ./setup.sh -v 3.17-stable  # specific version
#        ./setup.sh -k              # with katello

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[setup]${NC} $1"; }
success() { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
error() { echo -e "${RED}[setup]${NC} $1"; exit 1; }

# defaults
FOREMAN_VERSION="3.16-stable"
SOURCE_MODE=""
KATELLO_MODE=""

# parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            FOREMAN_VERSION="$2"
            shift 2
            ;;
        -s|--source)
            SOURCE_MODE="1"
            shift
            ;;
        -k|--katello)
            KATELLO_MODE="1"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -v, --version VERSION  Foreman version/branch (default: 3.16-stable)"
            echo "  -s, --source           Build from git source (enables dev mode)"
            echo "  -k, --katello          Enable Katello stack"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Modes:"
            echo "  Default (no --source): Uses official quay.io images, production mode"
            echo "                         Fast startup, but plugin assets need precompiling"
            echo ""
            echo "  With --source:         Builds from Foreman git repo, development mode"
            echo "                         Full asset pipeline, plugin assets work properly"
            echo "                         First build takes ~10 minutes"
            echo ""
            echo "Examples:"
            echo "  $0                        # quick setup with official images"
            echo "  $0 --source               # full dev environment from source"
            echo "  $0 -v develop --source    # bleeding edge from develop branch"
            echo "  $0 -k                     # with katello"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

cd "$DEV_ENV_DIR"

# create directories
mkdir -p bundler.d
mkdir -p ../foreman-plugins 2>/dev/null || true

# determine mode and dockerfile
if [ -n "$KATELLO_MODE" ] && [ -n "$SOURCE_MODE" ]; then
    RAILS_ENV="development"
    DOCKERFILE="Dockerfile.foreman-katello"
    MODE_DESC="katello development (from source)"
elif [ -n "$SOURCE_MODE" ]; then
    RAILS_ENV="development"
    DOCKERFILE="Dockerfile.foreman-source"
    MODE_DESC="development (from source)"
else
    RAILS_ENV="production"
    DOCKERFILE="Dockerfile.foreman"
    MODE_DESC="production (official images)"
fi

# save config to .env
cat > .env << EOF
FOREMAN_VERSION=$FOREMAN_VERSION
RAILS_ENV=$RAILS_ENV
FOREMAN_DOCKERFILE=$DOCKERFILE
SECRET_KEY_BASE=$(openssl rand -hex 64)
PLUGINS_PATH=../foreman-plugins
PULP_VERSION=3.63
EOF

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
if [ -n "$KATELLO_MODE" ]; then
echo "║   Foreman + Katello Environment Setup                     ║"
else
echo "║   Foreman Environment Setup                               ║"
fi
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║   Version: $FOREMAN_VERSION"
echo "║   Mode:    $MODE_DESC"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# check docker
if ! command -v docker &> /dev/null; then
    error "Docker not found. Install it first."
fi
success "Docker: $(docker --version | cut -d' ' -f3)"

if ! docker compose version &> /dev/null; then
    error "Docker Compose not found."
fi
success "Docker Compose: $(docker compose version --short)"

# clean up
log "Stopping any existing containers..."
docker compose down 2>/dev/null || true

# build image
if [ -n "$SOURCE_MODE" ]; then
    log "Building Foreman from source (this takes ~10 minutes first time)..."
    docker compose build foreman --build-arg FOREMAN_VERSION="$FOREMAN_VERSION"
else
    log "Building Foreman image (based on quay.io/foreman/foreman:$FOREMAN_VERSION)..."
    docker compose build foreman
fi

log "Starting database and redis..."
docker compose up -d db redis

log "Waiting for services to be healthy..."
sleep 5

# katello setup
if [ -n "$KATELLO_MODE" ]; then
    log "Setting up Katello services..."

    if [ ! -f "$DEV_ENV_DIR/config/pulp-certs/database_fields.symmetric.key" ]; then
        log "Creating Pulp encryption key..."
        mkdir -p "$DEV_ENV_DIR/config/pulp-certs"
        openssl rand -base64 32 > "$DEV_ENV_DIR/config/pulp-certs/database_fields.symmetric.key"
    fi

    if [ ! -f "$DEV_ENV_DIR/config/candlepin/certs/candlepin-ca.crt" ]; then
        log "Generating Candlepin CA certificate..."
        mkdir -p "$DEV_ENV_DIR/config/candlepin/certs"
        openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
            -keyout "$DEV_ENV_DIR/config/candlepin/certs/candlepin-ca.key" \
            -out "$DEV_ENV_DIR/config/candlepin/certs/candlepin-ca.crt" \
            -subj "/CN=candlepin-ca/O=Foreman Dev" 2>/dev/null
        chmod 644 "$DEV_ENV_DIR/config/candlepin/certs/candlepin-ca.key"
    fi

    # ensure candlepin volume has correct artemis dirs
    log "Setting up Candlepin volume permissions..."
    docker run --rm -v foreman-dev-env_candlepin_data:/data alpine sh -c \
        "mkdir -p /data/activemq-artemis/{bindings,journal,largemsgs,paging} && chmod -R 777 /data" 2>/dev/null || true

    log "Creating additional databases..."
    docker compose exec -T db psql -U foreman -c "CREATE DATABASE pulp;" 2>/dev/null || true
    docker compose exec -T db psql -U foreman -c "CREATE DATABASE candlepin;" 2>/dev/null || true
fi

log "Running database migrations..."
docker compose run --rm foreman bundle exec rake db:migrate 2>/dev/null || \
    docker compose run --rm foreman bundle exec rake db:create db:migrate

log "Seeding database (admin password: changeme)..."
docker compose run --rm -e SEED_ADMIN_PASSWORD=changeme foreman bundle exec rake db:seed

# sync plugins
log "Syncing plugins..."
"$SCRIPT_DIR/plugin.sh" sync

# install plugin dependencies if any plugins found
if ls bundler.d/*.local.rb 1>/dev/null 2>&1; then
    log "Installing plugin dependencies..."
    docker compose run --rm foreman bundle install
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete!                        ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║                                                           ║"
echo "║  Start:  ./scripts/start.sh                               ║"
echo "║  Access: http://localhost:3000                            ║"
echo "║                                                           ║"
echo "║  Credentials:                                             ║"
echo "║    Username: admin                                        ║"
echo "║    Password: changeme                                     ║"
echo "║                                                           ║"
echo "║  Version: $FOREMAN_VERSION"
echo "║  Mode:    $MODE_DESC"
echo "║                                                           ║"
if [ -n "$SOURCE_MODE" ]; then
echo "║  Development Mode:                                        ║"
echo "║    - Full asset pipeline enabled                          ║"
echo "║    - Plugin JS/CSS changes work without restart           ║"
echo "║    - Ruby changes require container restart               ║"
else
echo "║  Production Mode:                                         ║"
echo "║    - Fast startup with precompiled assets                 ║"
echo "║    - All changes require container restart                ║"
fi
echo "║                                                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
