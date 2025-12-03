#!/bin/bash
# list all test host vms

echo "Test Host VMs:"
echo ""
virsh list --all 2>/dev/null | grep -v "^$" | head -20

echo ""
echo "Use 'virsh start <name>' to boot a host"
echo "Use 'virt-viewer <name>' to view console"
