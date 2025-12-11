#!/bin/bash
# manage containerized test hosts for foreman
# usage: ./testhosts.sh start    # start all test hosts
#        ./testhosts.sh stop     # stop all test hosts
#        ./testhosts.sh status   # show status
#        ./testhosts.sh ssh <n>  # ssh into testhost<n> or testhost-debian
#        ./testhosts.sh exec <n> <cmd>  # run command on testhost<n>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEV_ENV_DIR"

# load and export .env (override any stale shell vars)
if [ -f .env ]; then
    unset RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
    source .env
    export RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# docker compose project name (container prefix)
PROJECT_NAME=$(basename "$DEV_ENV_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')

# all test hosts
TESTHOSTS="testhost1 testhost2 testhost3 testhost-debian"

usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  start          Start all test hosts (requires foreman to be running)"
    echo "  stop           Stop all test hosts"
    echo "  status         Show test host status"
    echo "  ssh <n>        SSH into testhost<n> (e.g., ssh 1, ssh debian)"
    echo "  exec <n> <cmd> Run command on testhost<n>"
    echo "  logs <n>       Show logs for testhost<n>"
    echo "  register       Register all hosts with Foreman"
    echo ""
    echo "Examples:"
    echo "  $0 start              # start all testhosts"
    echo "  $0 ssh 1              # ssh into testhost1"
    echo "  $0 ssh debian         # ssh into testhost-debian"
    echo "  $0 exec 2 uptime      # run uptime on testhost2"
}

start_hosts() {
    echo -e "${BLUE}[testhosts]${NC} Building and starting test hosts..."
    docker compose --profile testhosts up -d $TESTHOSTS
    echo ""
    echo -e "${GREEN}[testhosts]${NC} Test hosts started!"
    echo ""
    echo "Hosts will auto-register with Foreman (if running)"
    echo "Use '$0 status' to see host details"
    echo "Use '$0 ssh <n>' to connect (e.g., $0 ssh 1, $0 ssh debian)"
}

stop_hosts() {
    echo -e "${BLUE}[testhosts]${NC} Stopping test hosts..."
    docker compose --profile testhosts stop $TESTHOSTS 2>/dev/null || true
    docker compose --profile testhosts rm -f $TESTHOSTS 2>/dev/null || true
    echo -e "${GREEN}[testhosts]${NC} Test hosts stopped"
}

show_status() {
    echo -e "${BLUE}[testhosts]${NC} Test Host Status"
    echo ""
    printf "%-20s %-12s %-18s %-6s\n" "HOST" "STATUS" "IP" "SSH"
    echo "─────────────────────────────────────────────────────────────"

    for host in $TESTHOSTS; do
        container="${PROJECT_NAME}-${host}-1"

        # check if running
        if docker ps --format '{{.Names}}' | grep -q "$container"; then
            status="${GREEN}running${NC}"
            ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null || echo "unknown")
        else
            status="${RED}stopped${NC}"
            ip="-"
        fi

        # get ssh port
        case "$host" in
            testhost1) ssh_port="2201" ;;
            testhost2) ssh_port="2202" ;;
            testhost3) ssh_port="2203" ;;
            testhost-debian) ssh_port="2204" ;;
            *) ssh_port="-" ;;
        esac

        printf "%-20s ${status}     %-18s %-6s\n" "$host" "$ip" "$ssh_port"
    done

    echo ""
    echo "SSH: ./scripts/testhosts.sh ssh <n|debian>"
    echo "     or: ssh root@localhost -p <port> (password: changeme)"
}

# resolve host name from shorthand
resolve_host() {
    local n="$1"
    case "$n" in
        1|2|3) echo "testhost$n" ;;
        debian) echo "testhost-debian" ;;
        testhost*) echo "$n" ;;
        *) echo "testhost$n" ;;
    esac
}

ssh_host() {
    local n="$1"
    if [ -z "$n" ]; then
        echo "Usage: $0 ssh <n|debian>"
        echo "Example: $0 ssh 1, $0 ssh debian"
        exit 1
    fi

    local host=$(resolve_host "$n")
    local container="${PROJECT_NAME}-${host}-1"

    if ! docker ps --format '{{.Names}}' | grep -q "$container"; then
        echo "Error: $host is not running"
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
        echo "Usage: $0 exec <n|debian> <command>"
        echo "Example: $0 exec 1 uptime"
        exit 1
    fi

    local host=$(resolve_host "$n")
    local container="${PROJECT_NAME}-${host}-1"

    if ! docker ps --format '{{.Names}}' | grep -q "$container"; then
        echo "Error: $host is not running"
        exit 1
    fi

    docker exec -it "$container" $cmd
}

logs_host() {
    local n="$1"
    if [ -z "$n" ]; then
        echo "Usage: $0 logs <n|debian>"
        exit 1
    fi

    local host=$(resolve_host "$n")
    local container="${PROJECT_NAME}-${host}-1"
    docker logs -f "$container"
}

# foreman API helper
foreman_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local url="http://localhost:3000/api/v2/$endpoint"

    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" \
            -u admin:changeme \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "$url" \
            -u admin:changeme \
            -H "Content-Type: application/json"
    fi
}

# get or create architecture in foreman
get_or_create_arch() {
    local arch_name="$1"

    local result=$(foreman_api GET "architectures?search=name=$arch_name")
    local arch_id=$(echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -n "$arch_id" ]; then
        echo "$arch_id"
        return
    fi

    echo -e "${BLUE}[testhosts]${NC} Creating architecture: $arch_name" >&2
    result=$(foreman_api POST "architectures" "{\"architecture\":{\"name\":\"$arch_name\"}}")
    echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

# get or create operating system in foreman
get_or_create_os() {
    local name="$1"
    local major="$2"
    local minor="$3"
    local family="$4"
    local release_name="$5"

    local search="name=$name AND major=$major"
    local result=$(foreman_api GET "operatingsystems?search=$(echo "$search" | sed 's/ /%20/g')")
    local os_id=$(echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -n "$os_id" ]; then
        echo "$os_id"
        return
    fi

    echo -e "${BLUE}[testhosts]${NC} Creating OS: $name $major" >&2
    local os_data="{\"operatingsystem\":{\"name\":\"$name\",\"major\":\"$major\",\"minor\":\"$minor\",\"family\":\"$family\""
    # debian family requires release_name
    if [ -n "$release_name" ]; then
        os_data="$os_data,\"release_name\":\"$release_name\""
    fi
    os_data="$os_data}}"
    result=$(foreman_api POST "operatingsystems" "$os_data")
    echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

register_hosts() {
    echo -e "${BLUE}[testhosts]${NC} Registering hosts with Foreman..."

    FOREMAN_URL="http://localhost:3000"

    # check foreman is running
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$FOREMAN_URL/api/v2/status" 2>/dev/null)
    if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "401" ]; then
        echo -e "${RED}[testhosts]${NC} Foreman not available at $FOREMAN_URL (HTTP $HTTP_CODE)"
        exit 1
    fi

    # get or create x86_64 architecture
    ARCH_ID=$(get_or_create_arch "x86_64")

    for host in $TESTHOSTS; do
        container="${PROJECT_NAME}-${host}-1"

        if ! docker ps --format '{{.Names}}' | grep -q "$container"; then
            echo -e "${YELLOW}[testhosts]${NC} $host not running, skipping"
            continue
        fi

        hostname="${host}.local"
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null)
        mac=$(docker exec "$container" cat /sys/class/net/eth0/address 2>/dev/null || echo "")

        # detect OS from container
        os_info=$(docker exec "$container" cat /etc/os-release 2>/dev/null || echo "")
        os_id=$(echo "$os_info" | grep "^ID=" | cut -d'=' -f2 | tr -d '"')
        os_id_like=$(echo "$os_info" | grep "^ID_LIKE=" | cut -d'=' -f2 | tr -d '"')
        os_version=$(echo "$os_info" | grep "^VERSION_ID=" | cut -d'"' -f2)
        os_codename=$(echo "$os_info" | grep "^VERSION_CODENAME=" | cut -d'=' -f2 | tr -d '"')
        os_major=$(echo "$os_version" | cut -d. -f1)
        os_minor=$(echo "$os_version" | cut -d. -f2)
        [ -z "$os_minor" ] && os_minor=""

        # capitalize first letter for OS name (foreman doesn't allow spaces)
        os_name="$(echo "$os_id" | sed 's/./\U&/')"

        # determine family from ID_LIKE or ID
        os_release=""
        if echo "$os_id $os_id_like" | grep -qE 'rhel|fedora|centos'; then
            os_family="Redhat"
        elif echo "$os_id $os_id_like" | grep -qE 'debian|ubuntu'; then
            os_family="Debian"
            os_release="$os_codename"
        else
            os_family="Linux"
        fi

        echo -e "${BLUE}[testhosts]${NC} Registering $hostname ($ip, $os_name $os_major)..."

        # get or create OS
        OS_ID=$(get_or_create_os "$os_name" "$os_major" "$os_minor" "$os_family" "$os_release")

        # check if host exists
        existing=$(foreman_api GET "hosts?search=name=$hostname")
        existing_count=$(echo "$existing" | grep -o '"total":[0-9]*' | cut -d: -f2)

        if [ "$existing_count" = "1" ]; then
            # update existing
            host_id=$(echo "$existing" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
            foreman_api PUT "hosts/$host_id" "{
                \"host\": {
                    \"ip\": \"$ip\",
                    \"mac\": \"$mac\",
                    \"operatingsystem_id\": $OS_ID,
                    \"architecture_id\": $ARCH_ID
                }
            }" > /dev/null
            echo -e "${GREEN}[testhosts]${NC} $hostname updated"
        else
            # create new (managed: false to avoid provisioning validation)
            result=$(foreman_api POST "hosts" "{
                \"host\": {
                    \"name\": \"$hostname\",
                    \"ip\": \"$ip\",
                    \"mac\": \"$mac\",
                    \"build\": false,
                    \"managed\": false,
                    \"operatingsystem_id\": $OS_ID,
                    \"architecture_id\": $ARCH_ID,
                    \"comment\": \"Container test host - $os_name $os_major\"
                }
            }")

            if echo "$result" | grep -q '"id"'; then
                echo -e "${GREEN}[testhosts]${NC} $hostname registered"
            else
                echo -e "${YELLOW}[testhosts]${NC} $hostname failed: $(echo "$result" | grep -o '"message":"[^"]*"' | head -1)"
            fi
        fi
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
