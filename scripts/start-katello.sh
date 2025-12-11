#!/bin/bash
# start foreman with katello UI in development mode
set -e

DEV_ENV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DEV_ENV_DIR"

# docker compose project name (for volume names)
PROJECT_NAME=$(basename "$DEV_ENV_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')

# load and export .env (override any stale shell vars)
if [ -f .env ]; then
    unset RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
    source .env
    export RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
fi

COMPOSE_FILES="-f docker-compose.yml -f docker-compose.katello.yml"

# wrapper to prevent shell vars from overriding .env
dc() { env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose $COMPOSE_FILES "$@"; }

# build katello image if not present
if ! docker images foreman-katello-dev:latest --format '{{.ID}}' | grep -q .; then
    echo "Building katello image (this takes ~5 minutes)..."
    dc build foreman
fi

# remove volumes that conflict with katello's bundled gems/assets
# these volumes mask the image's internal directories on fresh start
echo "Cleaning conflicting volumes..."
dc down foreman orchestrator worker 2>/dev/null || true
docker volume rm ${PROJECT_NAME}_foreman_vendor 2>/dev/null || true
docker volume rm ${PROJECT_NAME}_foreman_webpack 2>/dev/null || true

# start database first to ensure it's ready
echo "Starting database..."
dc up -d db redis
echo "Waiting for database..."
sleep 5

# check for incompatible foreman-only data (orgs exist but no katello tables)
# this happens when switching from foreman-only to katello mode
if dc exec -T db psql -U foreman -d foreman -tAc "
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM taxonomies WHERE type = 'Organization')
         AND NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'katello_providers')
        THEN 'incompatible'
        ELSE 'ok'
    END" 2>/dev/null | grep -q "incompatible"; then
    echo ""
    echo "WARNING: Database has foreman-only data that's incompatible with katello."
    echo "This happens when switching from foreman-only mode to katello mode."
    echo ""
    echo "Options:"
    echo "  1) Reset database: docker volume rm ${PROJECT_NAME}_postgres_data"
    echo "  2) Then run this script again"
    echo ""
    read -p "Reset database now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Resetting database..."
        dc down
        docker volume rm ${PROJECT_NAME}_postgres_data 2>/dev/null || true
        dc up -d db redis
        echo "Waiting for fresh database..."
        sleep 5
    else
        echo "Aborting. Reset the database manually or use foreman-only mode."
        exit 1
    fi
fi

# ensure candlepin/pulp databases exist (for switching from non-katello mode)
dc exec -T db psql -U foreman -d postgres -c "
    SELECT 'CREATE DATABASE candlepin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'candlepin')\gexec;
    SELECT 'CREATE DATABASE pulp' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'pulp')\gexec;
" 2>/dev/null || true

# start all services
echo "Starting services..."
dc --profile katello up -d

# wait for candlepin tables (liquibase sometimes fails silently on first run)
echo "Waiting for candlepin initialization..."
for i in {1..15}; do
    if dc exec -T db psql -U foreman -d candlepin -c "SELECT 1 FROM cp_owner LIMIT 1" &>/dev/null; then
        break
    fi
    if [ $i -eq 15 ]; then
        echo "Candlepin tables not found, restarting candlepin..."
        dc restart candlepin
        sleep 20
    fi
    sleep 2
done

echo ""
echo "Katello is starting. First run takes ~3 minutes for:"
echo "  - Database migrations"
echo "  - Webpack compilation"
echo ""
echo "Monitor progress with:"
echo "  dc logs -f foreman"
echo ""
echo "Access:"
echo "  - Foreman: http://localhost:3000 (admin / changeme)"
echo "  - Candlepin: http://localhost:8080/candlepin/status"
echo ""
