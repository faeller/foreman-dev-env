#!/bin/bash
# start foreman with katello UI in development mode
set -e

cd "$(dirname "$0")/.."

COMPOSE_FILES="-f docker-compose.yml -f docker-compose.katello.yml"

# build katello image if not present
if ! docker images foreman-katello-dev:latest --format '{{.ID}}' | grep -q .; then
    echo "Building katello image (this takes ~5 minutes)..."
    docker compose $COMPOSE_FILES build foreman
fi

# remove volumes that conflict with katello's bundled gems/assets
# these volumes mask the image's internal directories on fresh start
echo "Cleaning conflicting volumes..."
docker compose $COMPOSE_FILES down foreman orchestrator worker 2>/dev/null || true
docker volume rm foreman-dev-env_foreman_vendor 2>/dev/null || true
docker volume rm foreman-dev-env_foreman_webpack 2>/dev/null || true

# start database first to ensure it's ready
echo "Starting database..."
docker compose $COMPOSE_FILES up -d db redis
echo "Waiting for database..."
sleep 5

# ensure candlepin/pulp databases exist (for switching from non-katello mode)
docker compose $COMPOSE_FILES exec -T db psql -U foreman -d postgres -c "
    SELECT 'CREATE DATABASE candlepin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'candlepin')\gexec;
    SELECT 'CREATE DATABASE pulp' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'pulp')\gexec;
" 2>/dev/null || true

# start all services
echo "Starting services..."
docker compose $COMPOSE_FILES --profile katello up -d

echo ""
echo "Katello is starting. First run takes ~3 minutes for:"
echo "  - Database migrations"
echo "  - Webpack compilation"
echo ""
echo "Monitor progress with:"
echo "  docker compose $COMPOSE_FILES logs -f foreman"
echo ""
echo "Access:"
echo "  - Foreman: http://localhost:3000 (admin / changeme)"
echo "  - Candlepin: http://localhost:8080/candlepin/status"
echo ""
