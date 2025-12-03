#!/bin/bash
# stop the foreman dev environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

echo "Stopping all containers..."
docker compose down

echo "Done. Database data is preserved in Docker volumes."
echo "To remove all data: docker compose down -v"
