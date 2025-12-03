#!/bin/bash
# create a test host vm using libvirt
# uses qemu:///session (user-level) by default, falls back to qemu:///system with sudo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"

# defaults
MEMORY=2048
CPUS=2
DISK=20
OS_VARIANT="centos-stream9"
START=false
NETWORK="default"
PXE_BOOT=false

# detect libvirt connection - prefer session (no sudo needed)
detect_libvirt_connection() {
    if virsh -c qemu:///session list &>/dev/null 2>&1; then
        LIBVIRT_URI="qemu:///session"
        VIRSH="virsh -c qemu:///session"
        VIRT_INSTALL="virt-install --connect qemu:///session"
        QEMU_IMG="qemu-img"
        DISK_DIR="$HOME/.local/share/libvirt/images"
        mkdir -p "$DISK_DIR"
    else
        LIBVIRT_URI="qemu:///system"
        VIRSH="sudo virsh"
        VIRT_INSTALL="sudo virt-install"
        QEMU_IMG="sudo qemu-img"
        DISK_DIR="/var/lib/libvirt/images"
    fi
}

usage() {
    echo "Usage: $0 [options] <hostname>"
    echo ""
    echo "Create a test VM that can be managed by Foreman."
    echo ""
    echo "Options:"
    echo "  -m, --memory <MB>      Memory in MB (default: 2048)"
    echo "  -c, --cpus <N>         Number of CPUs (default: 2)"
    echo "  -d, --disk <GB>        Disk size in GB (default: 20)"
    echo "  -o, --os <variant>     OS variant (default: centos-stream9)"
    echo "  -n, --network <name>   Libvirt network (default: default)"
    echo "  -s, --start            Start the VM after creation"
    echo "  -p, --pxe              Create PXE-bootable VM (no OS)"
    echo "  -h, --help             Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 testhost1                        # Create with CentOS 9 cloud image"
    echo "  $0 -p testhost2                     # Create PXE-bootable (for provisioning)"
    echo "  $0 -m 4096 -c 4 -s webserver        # Beefy host, start immediately"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--memory) MEMORY="$2"; shift 2 ;;
        -c|--cpus) CPUS="$2"; shift 2 ;;
        -d|--disk) DISK="$2"; shift 2 ;;
        -o|--os) OS_VARIANT="$2"; shift 2 ;;
        -n|--network) NETWORK="$2"; shift 2 ;;
        -s|--start) START=true; shift ;;
        -p|--pxe) PXE_BOOT=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1"; usage; exit 1 ;;
        *) HOSTNAME="$1"; shift ;;
    esac
done

if [ -z "$HOSTNAME" ]; then
    echo "Error: hostname required"
    usage
    exit 1
fi

# check libvirt
if ! command -v virsh &> /dev/null; then
    echo "Error: virsh not found. Install libvirt."
    exit 1
fi

detect_libvirt_connection
echo "Using libvirt: $LIBVIRT_URI"

# check if vm exists
if $VIRSH dominfo "$HOSTNAME" &>/dev/null 2>&1; then
    echo "Error: VM '$HOSTNAME' already exists."
    echo "Delete it with: $VIRSH destroy $HOSTNAME; $VIRSH undefine $HOSTNAME --remove-all-storage"
    exit 1
fi

echo "Creating test host: $HOSTNAME"
echo "  Memory: ${MEMORY}MB"
echo "  CPUs:   $CPUS"
echo "  Disk:   ${DISK}GB"
echo "  Network: $NETWORK"
echo ""

DISK_PATH="$DISK_DIR/${HOSTNAME}.qcow2"

if [ "$PXE_BOOT" = true ]; then
    echo "Creating PXE-bootable VM..."

    $QEMU_IMG create -f qcow2 "$DISK_PATH" "${DISK}G"

    MAC="52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"

    $VIRT_INSTALL \
        --name "$HOSTNAME" \
        --memory "$MEMORY" \
        --vcpus "$CPUS" \
        --disk path="$DISK_PATH",format=qcow2,bus=virtio \
        --network network="$NETWORK",mac="$MAC",model=virtio \
        --os-variant generic \
        --boot network,hd \
        --graphics vnc,listen=0.0.0.0 \
        --noautoconsole \
        --print-xml > "/tmp/${HOSTNAME}.xml"

    $VIRSH define "/tmp/${HOSTNAME}.xml"

    echo ""
    echo "PXE-bootable VM created!"
    echo "  MAC: $MAC"
    echo ""
    echo "Configure this host in Foreman, then start it:"
    echo "  $VIRSH start $HOSTNAME"
    echo "  virt-viewer $HOSTNAME"
else
    echo "Creating cloud-init VM..."

    # download cloud image if needed
    CLOUD_IMAGE_DIR="$DISK_DIR/cloud-images"
    mkdir -p "$CLOUD_IMAGE_DIR"

    case "$OS_VARIANT" in
        centos-stream9|centos9)
            IMAGE_URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
            IMAGE_NAME="centos-stream-9.qcow2"
            ;;
        almalinux9|alma9)
            IMAGE_URL="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
            IMAGE_NAME="almalinux-9.qcow2"
            ;;
        *)
            echo "Unknown OS variant: $OS_VARIANT"
            echo "Supported: centos-stream9, almalinux9"
            exit 1
            ;;
    esac

    BASE_IMAGE="$CLOUD_IMAGE_DIR/$IMAGE_NAME"
    if [ ! -f "$BASE_IMAGE" ]; then
        echo "Downloading cloud image..."
        curl -L -o "$BASE_IMAGE" "$IMAGE_URL"
    fi

    # create disk from base
    $QEMU_IMG create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_PATH" "${DISK}G"

    # create cloud-init iso
    CLOUD_INIT_DIR="/tmp/cloud-init-${HOSTNAME}"
    mkdir -p "$CLOUD_INIT_DIR"

    cat > "$CLOUD_INIT_DIR/meta-data" << EOF
instance-id: $HOSTNAME
local-hostname: $HOSTNAME
EOF

    cat > "$CLOUD_INIT_DIR/user-data" << EOF
#cloud-config
users:
  - name: root
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo "# no ssh key found")
  - name: foreman
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo "# no ssh key found")
chpasswd:
  list: |
    root:changeme
  expire: False
runcmd:
  - echo "$HOSTNAME" > /etc/hostname
  - hostnamectl set-hostname $HOSTNAME
EOF

    genisoimage -output "$CLOUD_INIT_DIR/cloud-init.iso" \
        -volid cidata -joliet -rock \
        "$CLOUD_INIT_DIR/user-data" "$CLOUD_INIT_DIR/meta-data" 2>/dev/null || \
    mkisofs -output "$CLOUD_INIT_DIR/cloud-init.iso" \
        -volid cidata -joliet -rock \
        "$CLOUD_INIT_DIR/user-data" "$CLOUD_INIT_DIR/meta-data"

    mv "$CLOUD_INIT_DIR/cloud-init.iso" "$DISK_DIR/${HOSTNAME}-cloud-init.iso"
    rm -rf "$CLOUD_INIT_DIR"

    $VIRT_INSTALL \
        --name "$HOSTNAME" \
        --memory "$MEMORY" \
        --vcpus "$CPUS" \
        --disk path="$DISK_PATH",format=qcow2,bus=virtio \
        --disk path="$DISK_DIR/${HOSTNAME}-cloud-init.iso",device=cdrom \
        --network network="$NETWORK",model=virtio \
        --os-variant "$OS_VARIANT" \
        --graphics vnc,listen=0.0.0.0 \
        --noautoconsole \
        --import

    echo ""
    echo "Cloud-init VM created and starting!"
    echo "  Root password: changeme"
    echo "  SSH key: added if found"
    echo ""
    echo "Get IP: $VIRSH domifaddr $HOSTNAME"
    echo "Console: virt-viewer $HOSTNAME"
fi

if [ "$START" = true ] && [ "$PXE_BOOT" = true ]; then
    echo "Starting VM..."
    $VIRSH start "$HOSTNAME"
fi
