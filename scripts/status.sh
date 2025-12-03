#!/bin/bash
# show environment status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║        Foreman Dev Environment Status                     ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

echo "Containers:"
docker compose ps
echo ""

echo "Volumes:"
docker volume ls | grep dev-env || echo "  No volumes found"
echo ""

echo "Linked Plugins:"
if docker compose exec -T foreman ls bundler.d/*.local.rb 2>/dev/null; then
    docker compose exec -T foreman cat bundler.d/*.local.rb 2>/dev/null | grep "gem " | sed 's/^/  /'
else
    echo "  None (or container not running)"
fi
echo ""

echo "Access: http://localhost:3000"
