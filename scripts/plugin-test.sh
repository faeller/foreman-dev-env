#!/bin/bash
# run tests for a plugin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

if [ -z "$1" ]; then
    echo "Usage: $0 <plugin-name> [test-file]"
    exit 1
fi

PLUGIN_NAME="$1"
TEST_FILE="${2:-}"

cd "$DEV_ENV_DIR"

if [ -n "$TEST_FILE" ]; then
    docker compose exec foreman bundle exec rake "test:${PLUGIN_NAME}" TEST="$TEST_FILE"
else
    docker compose exec foreman bundle exec rake "test:${PLUGIN_NAME}"
fi
