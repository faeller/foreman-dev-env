#!/bin/bash
# foreman host registration script with OS auto-detection
# runs on container boot to register with foreman

FOREMAN_URL="${FOREMAN_URL:-http://foreman:3000}"
FOREMAN_USER="${FOREMAN_USER:-admin}"
FOREMAN_PASSWORD="${FOREMAN_PASSWORD:-changeme}"
HOSTNAME="${TESTHOST_HOSTNAME:-$(hostname)}"
REGISTER_WITH_FOREMAN="${REGISTER_WITH_FOREMAN:-0}"

log() { echo "[foreman-register] $1"; }

# skip if registration disabled
if [ "$REGISTER_WITH_FOREMAN" != "1" ]; then
    log "Registration disabled (REGISTER_WITH_FOREMAN != 1)"
    exit 0
fi

log "Registering with Foreman at $FOREMAN_URL..."

# wait for foreman to be available (up to 5 min)
for i in {1..60}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$FOREMAN_URL/api/v2/status" 2>/dev/null)
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then
        log "Foreman is available"
        break
    fi
    if [ $i -eq 60 ]; then
        log "Foreman not available after 5 minutes, giving up"
        exit 1
    fi
    log "Waiting for Foreman... ($i/60)"
    sleep 5
done

# collect host info
IP=$(hostname -I | awk '{print $1}')
MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || echo "")
ARCH=$(uname -m)

# detect OS from /etc/os-release
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)
    OS_MINOR=$(echo "$VERSION_ID" | cut -d. -f2)
    [ -z "$OS_MINOR" ] && OS_MINOR=""

    # capitalize first letter for OS name
    OS_NAME="$(echo "$ID" | sed 's/./\U&/')"

    # determine family from ID_LIKE or ID
    OS_RELEASE=""
    if echo "$ID $ID_LIKE" | grep -qE 'rhel|fedora|centos'; then
        OS_FAMILY="Redhat"
    elif echo "$ID $ID_LIKE" | grep -qE 'debian|ubuntu'; then
        OS_FAMILY="Debian"
        OS_RELEASE="$VERSION_CODENAME"
    else
        OS_FAMILY="Linux"
    fi
else
    OS_NAME="Unknown"
    OS_MAJOR="1"
    OS_MINOR=""
    OS_FAMILY="Linux"
    OS_RELEASE=""
fi

log "Detected OS: $OS_NAME $OS_MAJOR.$OS_MINOR ($OS_FAMILY)"
log "Host info: $HOSTNAME ($IP, $MAC, $ARCH)"

# helper function to call foreman API
foreman_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    if [ -n "$data" ]; then
        curl -s -X "$method" "$FOREMAN_URL/api/v2/$endpoint" \
            -u "$FOREMAN_USER:$FOREMAN_PASSWORD" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "$FOREMAN_URL/api/v2/$endpoint" \
            -u "$FOREMAN_USER:$FOREMAN_PASSWORD" \
            -H "Content-Type: application/json"
    fi
}

# get or create architecture
get_or_create_arch() {
    local arch_name="$1"

    # map uname arch to foreman arch name
    case "$arch_name" in
        x86_64) arch_name="x86_64" ;;
        aarch64) arch_name="aarch64" ;;
        *) arch_name="$arch_name" ;;
    esac

    # search for existing
    local result=$(foreman_api GET "architectures?search=name=$arch_name")
    local arch_id=$(echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -n "$arch_id" ]; then
        echo "$arch_id"
        return
    fi

    # create new
    log "Creating architecture: $arch_name"
    result=$(foreman_api POST "architectures" "{\"architecture\":{\"name\":\"$arch_name\"}}")
    echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

# get or create operating system
get_or_create_os() {
    local name="$1"
    local major="$2"
    local minor="$3"
    local family="$4"
    local release_name="$5"

    # search for existing (name and major version)
    local search="name=$name AND major=$major"
    local result=$(foreman_api GET "operatingsystems?search=$(echo "$search" | sed 's/ /%20/g')")
    local os_id=$(echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -n "$os_id" ]; then
        echo "$os_id"
        return
    fi

    # create new
    log "Creating OS: $name $major"
    local os_data="{\"operatingsystem\":{\"name\":\"$name\",\"major\":\"$major\",\"minor\":\"$minor\",\"family\":\"$family\""
    if [ -n "$release_name" ]; then
        os_data="$os_data,\"release_name\":\"$release_name\""
    fi
    os_data="$os_data}}"
    result=$(foreman_api POST "operatingsystems" "$os_data")
    echo "$result" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

# get architecture and OS IDs
ARCH_ID=$(get_or_create_arch "$ARCH")
OS_ID=$(get_or_create_os "$OS_NAME" "$OS_MAJOR" "$OS_MINOR" "$OS_FAMILY" "$OS_RELEASE")

log "Architecture ID: $ARCH_ID, OS ID: $OS_ID"

# check if host already exists
EXISTING=$(foreman_api GET "hosts?search=name=$HOSTNAME")
EXISTING_COUNT=$(echo "$EXISTING" | grep -o '"total":[0-9]*' | cut -d: -f2)

if [ "$EXISTING_COUNT" = "1" ]; then
    log "Host $HOSTNAME already registered, updating..."
    # get host id
    HOST_ID=$(echo "$EXISTING" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    foreman_api PUT "hosts/$HOST_ID" "{
        \"host\": {
            \"ip\": \"$IP\",
            \"mac\": \"$MAC\",
            \"operatingsystem_id\": $OS_ID,
            \"architecture_id\": $ARCH_ID
        }
    }" > /dev/null && log "Host updated" || log "Update failed"
else
    log "Creating new host $HOSTNAME..."
    RESULT=$(foreman_api POST "hosts" "{
        \"host\": {
            \"name\": \"$HOSTNAME\",
            \"ip\": \"$IP\",
            \"mac\": \"$MAC\",
            \"build\": false,
            \"managed\": false,
            \"operatingsystem_id\": $OS_ID,
            \"architecture_id\": $ARCH_ID,
            \"comment\": \"Container test host - $OS_NAME $OS_MAJOR\"
        }
    }")

    if echo "$RESULT" | grep -q '"id"'; then
        log "Host registered successfully"
    else
        log "Registration result: $RESULT"
    fi
fi

log "Done"
