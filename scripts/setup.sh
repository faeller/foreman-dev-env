#!/bin/bash
# foreman dev environment setup
# usage: ./setup.sh                 # development mode from source (default)
#        ./setup.sh -k              # with katello
#        ./setup.sh -v 3.17-stable  # specific version
#        ./setup.sh --production    # use official images instead of source

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

# clear any stale shell env vars that might override .env
unset RAILS_ENV FOREMAN_DOCKERFILE

# defaults
FOREMAN_VERSION="3.16-stable"
SOURCE_MODE="1"
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
        -p|--production)
            SOURCE_MODE=""
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
            echo "  -k, --katello          Enable Katello stack"
            echo "  -p, --production       Use official images instead of building from source"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Modes:"
            echo "  Default:               Builds from Foreman git repo, development mode"
            echo "                         Full asset pipeline, plugin assets work properly"
            echo "                         First build takes ~10 minutes"
            echo ""
            echo "  With --production:     Uses official quay.io images, production mode"
            echo "                         Fast startup, but plugin assets need precompiling"
            echo ""
            echo "Examples:"
            echo "  $0                        # dev environment from source (default)"
            echo "  $0 -k                     # with katello"
            echo "  $0 -v develop             # bleeding edge from develop branch"
            echo "  $0 --production           # quick setup with official images"
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
env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose down 2>/dev/null || true

# determine compose files
# use env -u to prevent shell vars from overriding .env
COMPOSE_CMD="env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose"
if [ -n "$KATELLO_MODE" ]; then
    COMPOSE_CMD="env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose -f docker-compose.yml -f docker-compose.katello.yml"
fi

# set vars for docker compose (read from .env, not exported to parent shell)
FOREMAN_DOCKERFILE="$DOCKERFILE"

# build image
if [ -n "$SOURCE_MODE" ]; then
    log "Building Foreman from source (this takes ~10 minutes first time)..."
    $COMPOSE_CMD build foreman --build-arg FOREMAN_VERSION="$FOREMAN_VERSION"
else
    log "Building Foreman image (based on quay.io/foreman/foreman:$FOREMAN_VERSION)..."
    $COMPOSE_CMD build foreman
fi

log "Starting database and redis..."
env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose up -d db redis

# ensure webpack volume has correct permissions for foreman user
# volume name is <project>_foreman_webpack where project defaults to directory name
PROJECT_NAME=$(basename "$DEV_ENV_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
docker run --rm -v "${PROJECT_NAME}_foreman_webpack:/webpack" alpine chown -R 1000:1000 /webpack 2>/dev/null || true

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
    docker run --rm -v ${PROJECT_NAME}_candlepin_data:/data alpine sh -c \
        "mkdir -p /data/activemq-artemis/{bindings,journal,largemsgs,paging} && chmod -R 777 /data" 2>/dev/null || true

    log "Creating additional databases..."
    docker compose exec -T db psql -U foreman -c "CREATE DATABASE pulp;" 2>/dev/null || true
    docker compose exec -T db psql -U foreman -c "CREATE DATABASE candlepin;" 2>/dev/null || true
fi

log "Running database migrations..."
$COMPOSE_CMD run --rm foreman bundle exec rake db:migrate 2>/dev/null || \
    $COMPOSE_CMD run --rm foreman bundle exec rake db:create db:migrate

# seed via entrypoint on first start (handles password correctly)
# for source mode, entrypoint will seed with SEED_ADMIN_PASSWORD=changeme
if [ -z "$SOURCE_MODE" ]; then
    log "Seeding database (admin password: changeme)..."
    $COMPOSE_CMD run --rm -e SEED_ADMIN_PASSWORD=changeme foreman bundle exec rake db:seed
fi

# sync plugins
log "Syncing plugins..."
"$SCRIPT_DIR/plugin.sh" sync

# install plugin dependencies if any plugins found (skip for katello - has bundled deps)
if [ -z "$KATELLO_MODE" ] && ls bundler.d/*.local.rb 1>/dev/null 2>&1; then
    log "Installing plugin dependencies..."
    $COMPOSE_CMD run --rm foreman bundle install
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete!                        ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║                                                           ║"
if [ -n "$KATELLO_MODE" ]; then
echo "║  Start:  ./scripts/start-katello.sh                       ║"
else
echo "║  Start:  ./scripts/start.sh                               ║"
fi
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
