# Proxmox Automated VM Backup Verification & Test Script

An automated Bash script for Proxmox VE that verifies the integrity and recoverability of virtual machine backups. It dynamically fetches VMs from a specified Proxmox resource pool, performs a test restore to an isolated temporary VMID, boots it with network isolation, verifies system health via the QEMU Guest Agent, captures a console screenshot, cleans up the environment, and sends a detailed email report.

---

## Features

- **Dynamic Pool Discovery:** Automatically retrieves the list of target VMs from a Proxmox resource pool using `pvesh` and `jq`.
- **Automated Test Restore:** Locates the latest backup archive from your Proxmox Backup Server (PBS) or local storage and restores it using `qmrestore`.
- **Safe Network Isolation:** Automatically disables all virtual network interfaces (`link_down=1`) on the test VM to prevent IP/MAC conflicts in your production network.
- **Resource Optimization:** Dynamically scales down the test VM's RAM to half of its original allocation to conserve hypervisor resources during verification.
- **Health Check:** Waits for the QEMU Guest Agent to respond (`ping`), confirming the OS has booted successfully.
- **Visual Diagnostics:** Captures a Proxmox monitor screenshot (`screendump`) of the test VM console.
- **Automated Cleanup:** Gracefully stops and completely purges (`--purge`) the temporary test VM after verification.
- **Email Alerting:** Sends HTML/text email reports via `mutt` with attached logs (and console screenshots on failure).

---

## Prerequisites

- Proxmox VE (tested on PVE 8+)
- `jq` utility installed (`apt install jq -y`)
- `mutt` and a configured local mail relay/MTA for sending emails
- QEMU Guest Agent installed inside the guest operating systems

---

## Configuration

Edit the configuration variables at the top of `backup.sh` to match your environment:

```bash
TEST_VMID="999"                      # Temporary VM ID used for the restore test
STORAGE_ID="pbs_stor_bkp"            # Proxmox storage ID where backups are kept
TARGET_STORAGE="NFS_SA3400d_r10"     # Target storage where the test VM will be built
TIMEOUT_SECONDS=180                  # Time to wait for the guest agent to respond (seconds)
EMAIL_TO="admins@yourdomain.com"     # Notification recipient