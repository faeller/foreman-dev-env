#!/bin/bash
# start foreman
# usage: ./start.sh           # foreman only (uses .env settings)
#        ./start.sh -k        # with katello (redirects to start-katello.sh)
#        ./start.sh -t        # with test hosts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

# load and export .env (override any stale shell vars)
if [ -f .env ]; then
    unset RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
    source .env
    export RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
fi

PROFILES=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--katello)
            # katello needs special handling (volume cleanup, compose override)
            exec "$SCRIPT_DIR/start-katello.sh"
            ;;
        -t|--testhosts) PROFILES="$PROFILES --profile testhosts"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

MODE_INFO="(${RAILS_ENV:-development} mode)"

echo "Starting Foreman ${FOREMAN_VERSION:-latest} $MODE_INFO..."
echo ""
echo "  Foreman: http://localhost:3000"
if [[ "$PROFILES" == *"testhosts"* ]]; then
    echo "  Test hosts: testhost1, testhost2, testhost3"
fi
echo ""
echo "Press Ctrl+C to stop"
echo ""

# use env -u to remove shell vars that might override .env
env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose $PROFILES up foreman orchestrator worker
