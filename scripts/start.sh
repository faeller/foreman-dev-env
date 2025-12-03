#!/bin/bash
# start foreman
# usage: ./start.sh           # foreman only (uses .env settings)
#        ./start.sh --source  # force source/dev mode
#        ./start.sh -k        # with katello
#        ./start.sh -t        # with test hosts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

# load version from .env
if [ -f .env ]; then
    source .env
fi

PROFILES=""
SOURCE_MODE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--katello) PROFILES="$PROFILES --profile katello"; shift ;;
        -t|--testhosts) PROFILES="$PROFILES --profile testhosts"; shift ;;
        -s|--source) SOURCE_MODE="1"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# override env for source mode
if [ -n "$SOURCE_MODE" ]; then
    export FOREMAN_DOCKERFILE="Dockerfile.foreman-source"
    export RAILS_ENV="development"
    MODE_INFO="(development mode)"
else
    MODE_INFO="(${RAILS_ENV:-production} mode)"
fi

echo "Starting Foreman ${FOREMAN_VERSION:-latest} $MODE_INFO..."
echo ""
echo "  Foreman: http://localhost:3000"
if [[ "$PROFILES" == *"katello"* ]]; then
    echo "  Pulp:    http://localhost:24817"
fi
if [[ "$PROFILES" == *"testhosts"* ]]; then
    echo "  Test hosts: testhost1, testhost2, testhost3"
fi
echo ""
echo "Press Ctrl+C to stop"
echo ""

docker compose $PROFILES up foreman orchestrator worker
