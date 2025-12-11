#!/bin/bash
# stop the foreman dev environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

# load and export .env (override any stale shell vars)
if [ -f .env ]; then
    unset RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
    source .env
    export RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
fi

echo "Stopping all containers..."
env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose down

echo "Done. Database data is preserved in Docker volumes."
echo "To remove all data: docker compose down -v"
