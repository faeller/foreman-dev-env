#!/bin/bash
# destroy a test host vm

set -e

usage() {
    echo "Usage: $0 <hostname>"
    echo ""
    echo "Completely remove a test host VM and its storage."
}

if [ -z "$1" ]; then
    usage
    exit 1
fi

HOSTNAME="$1"

if ! virsh dominfo "$HOSTNAME" &>/dev/null; then
    echo "Error: VM '$HOSTNAME' not found."
    exit 1
fi

echo "This will permanently delete VM '$HOSTNAME' and all its storage."
read -p "Are you sure? [y/N] " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # stop if running
    virsh destroy "$HOSTNAME" 2>/dev/null || true

    # remove with storage
    virsh undefine "$HOSTNAME" --remove-all-storage

    echo "VM '$HOSTNAME' deleted."
else
    echo "Cancelled."
fi
