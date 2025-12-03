#!/bin/bash
# manage containerized test hosts for foreman
# usage: ./testhosts.sh start    # start all test hosts
#        ./testhosts.sh stop     # stop all test hosts
#        ./testhosts.sh status   # show status
#        ./testhosts.sh ssh <n>  # ssh into testhost<n>
#        ./testhosts.sh exec <n> <cmd>  # run command on testhost<n>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  start          Start all test hosts (requires foreman to be running)"
    echo "  stop           Stop all test hosts"
    echo "  status         Show test host status"
    echo "  ssh <n>        SSH into testhost<n> (e.g., ssh 1)"
    echo "  exec <n> <cmd> Run command on testhost<n>"
    echo "  logs <n>       Show logs for testhost<n>"
    echo "  register       Register all hosts with Foreman"
    echo ""
    echo "Examples:"
    echo "  $0 start           # start testhost1, testhost2, testhost3"
    echo "  $0 ssh 1           # ssh into testhost1"
    echo "  $0 exec 2 uptime   # run uptime on testhost2"
}

start_hosts() {
    echo -e "${BLUE}[testhosts]${NC} Building and starting test hosts..."
    docker compose --profile testhosts up -d testhost1 testhost2 testhost3
    echo ""
    echo -e "${GREEN}[testhosts]${NC} Test hosts started!"
    echo ""
    echo "Hosts will auto-register with Foreman (if running)"
    echo "Use '$0 status' to see host details"
    echo "Use '$0 ssh <n>' to connect (e.g., $0 ssh 1)"
}

stop_hosts() {
    echo -e "${BLUE}[testhosts]${NC} Stopping test hosts..."
    docker compose --profile testhosts stop testhost1 testhost2 testhost3 2>/dev/null || true
    docker compose --profile testhosts rm -f testhost1 testhost2 testhost3 2>/dev/null || true
    echo -e "${GREEN}[testhosts]${NC} Test hosts stopped"
}

show_status() {
    echo -e "${BLUE}[testhosts]${NC} Test Host Status"
    echo ""
    printf "%-15s %-12s %-20s %-10s\n" "HOST" "STATUS" "IP" "SSH"
    echo "─────────────────────────────────────────────────────────────"

    for n in 1 2 3; do
        host="testhost$n"
        container="foreman-dev-env-${host}-1"

        # check if running
        if docker ps --format '{{.Names}}' | grep -q "$container"; then
            status="${GREEN}running${NC}"
            # get ip
            ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null || echo "unknown")
            ssh_cmd="docker exec -it $container bash"
        else
            status="${RED}stopped${NC}"
            ip="-"
            ssh_cmd="-"
        fi

        printf "%-15s ${status}     %-20s %-10s\n" "$host" "$ip" ""
    done

    echo ""
    echo "SSH: ./scripts/testhosts.sh ssh <n>"
}

ssh_host() {
    local n="$1"
    if [ -z "$n" ]; then
        echo "Usage: $0 ssh <n>"
        echo "Example: $0 ssh 1"
        exit 1
    fi

    container="foreman-dev-env-testhost${n}-1"
    if ! docker ps --format '{{.Names}}' | grep -q "$container"; then
        echo "Error: testhost${n} is not running"
        echo "Start it with: $0 start"
        exit 1
    fi

    docker exec -it "$container" bash
}

exec_host() {
    local n="$1"
    shift
    local cmd="$@"

    if [ -z "$n" ] || [ -z "$cmd" ]; then
        echo "Usage: $0 exec <n> <command>"
        echo "Example: $0 exec 1 uptime"
        exit 1
    fi

    container="foreman-dev-env-testhost${n}-1"
    if ! docker ps --format '{{.Names}}' | grep -q "$container"; then
        echo "Error: testhost${n} is not running"
        exit 1
    fi

    docker exec -it "$container" $cmd
}

logs_host() {
    local n="$1"
    if [ -z "$n" ]; then
        echo "Usage: $0 logs <n>"
        exit 1
    fi

    container="foreman-dev-env-testhost${n}-1"
    docker logs -f "$container"
}

register_hosts() {
    echo -e "${BLUE}[testhosts]${NC} Registering hosts with Foreman..."

    FOREMAN_URL="http://localhost:3000"

    # check foreman is running
    if ! curl -s -o /dev/null -w "%{http_code}" "$FOREMAN_URL/api/v2/status" 2>/dev/null | grep -q "200"; then
        echo -e "${RED}[testhosts]${NC} Foreman not available at $FOREMAN_URL"
        exit 1
    fi

    for n in 1 2 3; do
        container="foreman-dev-env-testhost${n}-1"

        if ! docker ps --format '{{.Names}}' | grep -q "$container"; then
            echo -e "${YELLOW}[testhosts]${NC} testhost${n} not running, skipping"
            continue
        fi

        hostname="testhost${n}.local"
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null)
        mac=$(docker exec "$container" cat /sys/class/net/eth0/address 2>/dev/null || echo "")

        echo -e "${BLUE}[testhosts]${NC} Registering $hostname ($ip)..."

        curl -s -X POST "$FOREMAN_URL/api/v2/hosts" \
            -u admin:changeme \
            -H "Content-Type: application/json" \
            -d "{
                \"host\": {
                    \"name\": \"$hostname\",
                    \"ip\": \"$ip\",
                    \"mac\": \"$mac\",
                    \"build\": false,
                    \"managed\": true
                }
            }" > /dev/null && echo -e "${GREEN}[testhosts]${NC} $hostname registered" || echo -e "${YELLOW}[testhosts]${NC} $hostname may already exist"
    done

    echo ""
    echo "Check hosts at: http://localhost:3000/hosts"
}

case "${1:-}" in
    start)
        start_hosts
        ;;
    stop)
        stop_hosts
        ;;
    status)
        show_status
        ;;
    ssh)
        ssh_host "$2"
        ;;
    exec)
        shift
        exec_host "$@"
        ;;
    logs)
        logs_host "$2"
        ;;
    register)
        register_hosts
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
