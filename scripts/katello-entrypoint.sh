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

    # seed only if needed (check for admin user)
    if ! bundle exec rails runner "exit(User.find_by(login: 'admin') ? 0 : 1)" 2>/dev/null; then
        echo "[entrypoint] seeding database..."
        bundle exec rake db:seed
    fi

    if [ ! -f public/webpack/manifest.json ]; then
        echo "[entrypoint] compiling webpack..."
        bundle exec rake webpack:compile
    fi

    touch /tmp/.foreman-initialized
    echo "[entrypoint] ready"
fi

# exec the command
exec "$@"
