#!/bin/bash
# view logs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

SERVICE="${1:-foreman}"

case "$SERVICE" in
    foreman|worker|orchestrator|db|redis|candlepin|pulp-api|pulp-content|pulp-worker)
        docker compose logs -f "$SERVICE"
        ;;
    all)
        docker compose logs -f
        ;;
    rails)
        docker compose exec foreman tail -f log/development.log
        ;;
    *)
        echo "Usage: $0 [foreman|worker|orchestrator|db|redis|candlepin|pulp-*|rails|all]"
        exit 1
        ;;
esac
