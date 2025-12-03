#!/bin/bash
# foreman host registration script
# runs on container boot to register with foreman

FOREMAN_URL="${FOREMAN_URL:-http://foreman:3000}"
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
    if curl -s -o /dev/null -w "%{http_code}" "$FOREMAN_URL/api/v2/status" 2>/dev/null | grep -q "200"; then
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
OS=$(cat /etc/os-release | grep "^PRETTY_NAME=" | cut -d'"' -f2)

log "Host info: $HOSTNAME ($IP, $MAC)"

# check if host already exists
EXISTING=$(curl -s "$FOREMAN_URL/api/v2/hosts?search=name=$HOSTNAME" \
    -u admin:changeme \
    -H "Content-Type: application/json" 2>/dev/null | grep -o '"total":[0-9]*' | cut -d':' -f2)

if [ "$EXISTING" = "1" ]; then
    log "Host $HOSTNAME already registered, updating..."
    # update existing host
    curl -s -X PUT "$FOREMAN_URL/api/v2/hosts/$HOSTNAME" \
        -u admin:changeme \
        -H "Content-Type: application/json" \
        -d "{
            \"host\": {
                \"ip\": \"$IP\",
                \"mac\": \"$MAC\"
            }
        }" > /dev/null && log "Host updated" || log "Update failed"
else
    log "Creating new host $HOSTNAME..."
    # create new host
    RESULT=$(curl -s -X POST "$FOREMAN_URL/api/v2/hosts" \
        -u admin:changeme \
        -H "Content-Type: application/json" \
        -d "{
            \"host\": {
                \"name\": \"$HOSTNAME\",
                \"ip\": \"$IP\",
                \"mac\": \"$MAC\",
                \"build\": false,
                \"managed\": true,
                \"comment\": \"Container test host - $OS\"
            }
        }" 2>&1)

    if echo "$RESULT" | grep -q '"id"'; then
        log "Host registered successfully"
    else
        log "Registration result: $RESULT"
    fi
fi

log "Done"
