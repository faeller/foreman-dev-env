#!/bin/bash
set -e

cd /home/foreman

# first-run setup (skip if already done this container lifetime)
if [ ! -f /tmp/.foreman-initialized ]; then
    echo "[entrypoint] checking initialization..."

    # wait for db
    until bundle exec rake db:version 2>/dev/null; do
        echo "[entrypoint] waiting for database..."
        sleep 2
    done

    # run migrations only if pending
    if bundle exec rake db:abort_if_pending_migrations 2>&1 | grep -q "pending"; then
        echo "[entrypoint] running migrations..."
        bundle exec rake db:create 2>/dev/null || true
        bundle exec rake db:migrate
    else
        echo "[entrypoint] migrations up to date"
    fi

    # always run seed on first start (idempotent, ensures permissions exist)
    echo "[entrypoint] seeding database..."
    SEED_ADMIN_PASSWORD="${SEED_ADMIN_PASSWORD:-changeme}" bundle exec rake db:seed

    # compile webpack if not present
    if [ ! -f public/webpack/manifest.json ]; then
        echo "[entrypoint] compiling webpack (first run, takes ~1 min)..."
        mkdir -p public/webpack
        NODE_ENV=development ./node_modules/.bin/webpack --config config/webpack.config.js
    fi

    touch /tmp/.foreman-initialized
    echo "[entrypoint] ready"
fi

# exec the command
exec "$@"
