#!/bin/bash

# --- CONFIGURATION ---
SOURCE_VM_LIST="101 102 "           # The production VM ID you want to test
TEST_VMID="999"                     # Temporary VM ID used for the restore test
STORAGE_ID="pbs_stor_bkp"            # The Proxmox storage ID where backups are kept
TARGET_STORAGE="stor_for_restore"    # Target storage where the test VM will be built
TIMEOUT_SECONDS=180                  # Time to wait for the guest agent to respond
EMAIL_TO="admins@domain.name"
LOGFILE="/var/log/proxmox_vm_restore.log"
SCRFILE="/var/log/screenshot_vm_restore.ppm"

# Enable logging to file and stdout
truncate -s 0 "$LOGFILE"
exec &> >(tee -a "$LOGFILE")

# =========================
# FUNCTIONS
# =========================

send_email() {
    local vmid=$1
    local source=$2
    local backup=$3
    local status=$4
    local vmname=$5

    if [[ $status == true ]]; then
        subject="Proxmox VM Restore SUCCESS - VMID $source ($vmname)"
        echo -e "VMID: $vmid\nSource VMID: $source\nBackup: $backup\nResult: $status\n" \
        | mutt -s "$subject" "$EMAIL_TO" -a "$LOGFILE"
    else
        subject="Proxmox VM Restore FAIL - VMID $source ($vmname)"
        echo -e "VMID: $vmid\nSource VMID: $source\nBackup: $backup\nResult: $status\n" \
        | mutt -s "$subject" "$EMAIL_TO" -a "$LOGFILE" -a "$SCRFILE"
    fi
}
# =========================
# ENS FUNCTIONS
# =========================


echo "=== Starting Proxmox VM Backup Verification for VM $SOURCE_VMID ==="

# =========================
# MAIN LOOP
# =========================
SOURCE_VM_LIST=$(pvesh get /pools/pool_production --output-format json | jq -r '.members[] | .vmid' | tr '\n' ' ')
for SOURCE_VMID in $SOURCE_VM_LIST; do
  #truncate log file
  truncate -s 0 "$LOGFILE"

  # 1. Locate the latest backup file for the source VM
  echo "Searching for the latest backup in storage '$STORAGE_ID'..."
  #LATEST_BACKUP=$(pvesm list $STORAGE_ID | grep "vzdump-qemu-$SOURCE_VMID-" | sort | tail -n 1 | awk '{print $1}')
  LATEST_BACKUP=$(pvesm list $STORAGE_ID | grep "$SOURCE_VMID" | sort | tail -n 1 | awk '{print $1}')

  if [ -z "$LATEST_BACKUP" ]; then
    echo "ERROR: No backup found for VM $SOURCE_VMID on storage $STORAGE_ID."
    exit 1
  fi

  echo "Found latest backup file: $LATEST_BACKUP"
  VM_NAME="N/A"
  # 2. Restore the backup to the temporary Test VMID
  echo "Restoring to temporary VMID $TEST_VMID on storage $TARGET_STORAGE..."
  if ! qmrestore "$LATEST_BACKUP" "$TEST_VMID" --storage "$TARGET_STORAGE"; then
    echo "ERROR: Extraction / qmrestore failed."
    exit 1
  fi

  # 3. Safe Isolation: Disable network interfaces to prevent IP conflicts
  echo "Isolating network interfaces to avoid network/IP conflicts..."
  qm config $TEST_VMID | grep -E '^net[0-9]+:' | awk -F '[:]' '{print $1}' | while read -r net_interface; do
    echo "Disable network intrerface $net_interface for VM $TEST_VMID"
    qm set $TEST_VMID --$net_interface model=virtio,bridge=vmbr0,link_down=1
  done

  # --- Set half of original RAM ---
  ORIG_RAM=$(qm config "$TEST_VMID" | grep "^memory:" | awk '{print $2}')
  HALF_RAM=$(( ORIG_RAM / 2 ))
  [[ $HALF_RAM -lt $HALF_RAM_MIN ]] && HALF_RAM=$HALF_RAM_MIN
  qm set "$TEST_VMID" --memory "$HALF_RAM"
  echo "Set VMID $TEST_VMID memory to half of original: $HALF_RAM MB"

  # 4. Boot the restored test VM
  echo "Booting test VM $TEST_VMID..."
  qm start $TEST_VMID

  # 5. Perform consistency check via QEMU Guest Agent
  echo "Waiting for QEMU Guest Agent to respond (Checking VM health)..."
  SUCCESS=false
  for ((i=1; i<=TIMEOUT_SECONDS; i++)); do
    if qm agent $TEST_VMID ping > /dev/null 2>&1; then
        echo "SUCCESS: Restored VM booted completely and guest agent responded after $i seconds!"
        SUCCESS=true
        break
    fi
    sleep 1
  done
  pvesh create /nodes/pve1/qemu/$TEST_VMID/monitor --command "screendump $SCRFILE"
  VM_NAME=$(qm config "$TEST_VMID" | grep "^name:" | awk '{print $2}')
  [[ -z "$vm_name" ]] && vm_name="N/A"
  # 6. Clean up and purge the test environment
  echo "Stopping test VM $TEST_VMID..."
  qm stop $TEST_VMID --timeout 10 > /dev/null 2>&1
  qm set $TEST_VMID -protection 0
  echo "Destroying temporary test VM $TEST_VMID..."
  qm destroy $TEST_VMID --purge

  # 7. Final Report
  if [ "$SUCCESS" = true ]; then
    echo "=== TEST PASSED: Backup for VM $SOURCE_VMID is valid and functioning ==="
  else
    echo "=== TEST FAILED: Restored VM $TEST_VMID failed to initialize within time limit ==="
  fi

  # --- Send email with IP ---
  send_email "$TEST_VMID" "$SOURCE_VMID" "$LATEST_BACKUP" "$SUCCESS" "$VM_NAME"
done
echo "All restores completed!"

