#!/bin/bash
# ============================================================================
# Script Name : /etc/keepalived/notify_state_change.sh
# Description : Handles Keepalived state transitions (BACKUP, FAULT, STOP).
#        Implements strict self-fencing and socket cleanup to prevent Split-Brain.
# Organization : S-Core
# Author    : Kyuhwan Lee
# Date     : 2026-05-04
# Version   : 2.1.2
# OS      : RHEL 9.4
# Ownership  : root:root (Keepalived runs as root)
# Usage    : ./notify_state_change.sh <TYPE> <NAME> <STATE> OR ./notify_state_change.sh <STATE>
# Dependencies : Keepalived, WHPG Environment
#
# Modification History:
# Date    | Version | Author     | Description
# -----------|---------|-----------------|------------------------------------
# 2025-XX-XX | 1.0.0  | paul.son (EDB) | Initial creation for Greenplum/WHPG HA setup.
# 2026-03-12 | 2.0.0  | Kyuhwan Lee   | Applied enterprise-grade enhancements, 
#                                       including fixes for 'Suicide by pkill' regex bug, 
#                                       strict VIP/DB stop order for Split-Brain prevention, 
#                                       and switchover polling optimization.
# ============================================================================

HOSTNAME=$(hostname)

# ----------------------------------------------------------------------------
# Adaptive Parameter Parsing
# Handles both standard 'notify' (3 args) and 'notify_fault' (1 arg) configurations.
# ----------------------------------------------------------------------------
if [ -z "$3" ]; then
  # When called explicitly like: notify_fault "/path/to/script.sh FAULT"
  TYPE="INSTANCE"
  NAME="DEFAULT"
  CURRENT_STATE="$1"
else
  # When called generically like: notify "/path/to/script.sh INSTANCE WHPG_VI FAULT"
  TYPE="$1"
  NAME="$2"
  CURRENT_STATE="$3"
fi

COORDINATOR_DATA_DIR="/data1/coordinator/gpseg-1"
GP_PATH_SCRIPT="/usr/local/greenplum-db/greenplum_path.sh"
PGPORT=5432
LOG_DIR="${HOME}/gpAdminLogs"
LOG_FILE="${LOG_DIR}/whpg_state_change_$(date +%Y%m%d).log"

# Ensure log directory exists and set correct permissions
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
chown gpadmin:gpadmin "$LOG_FILE" >/dev/null 2>&1 || true

get_time() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_msg() {
  local LEVEL="$1"
  local MSG="$2"
  logger "$(get_time) $LEVEL: [$HOSTNAME] $MSG"
  echo "[$(get_time)] $LEVEL: $MSG" >> "$LOG_FILE"
}

# ----------------------------------------------------------------------------
# Function   : cleanup_sockets
# Description : Removes orphaned Unix domain sockets including IC Proxy sockets.
# ----------------------------------------------------------------------------
cleanup_sockets() {
  log_msg "INFO" "Cleaning up all Unix domain socket files for port $PGPORT (including IC Proxy)..."

  # Catch standard sockets (.s.PGSQL.5432)
  rm -f /tmp/.s.PGSQL.${PGPORT}*

  # Catch IC Proxy sockets (.s.PGSQL.ic_proxy.5432.1670498)
  rm -f /tmp/.s.PGSQL.*${PGPORT}*
}

# ----------------------------------------------------------------------------
# Function   : fence_database
# Description : Hard kills DB operations when Split-Brain is imminent.
# ----------------------------------------------------------------------------
fence_database() {
  log_msg "WARN" "Initiating strict self-fencing for $COORDINATOR_DATA_DIR"

  # Source GP environment variables
  if [ -f "$GP_PATH_SCRIPT" ]; then
    source "$GP_PATH_SCRIPT"
  fi

  # 1. Attempt immediate shutdown to prevent any further transactions
  log_msg "INFO" "Executing pg_ctl stop -m immediate..."
  # Execute as gpadmin since Keepalived runs as root
  su - gpadmin -c "pg_ctl stop -m immediate -w -t 10 -D $COORDINATOR_DATA_DIR" >> "$LOG_FILE" 2>&1
  STOP_STATUS=$?

  # 2. Force kill remaining postgres processes matching the data directory
  if [ $STOP_STATUS -ne 0 ]; then
    log_msg "ERROR" "Immediate shutdown timed out or failed. Force killing postgres processes."
    pkill -9 -u gpadmin -f "postgres.*-D.*$COORDINATOR_DATA_DIR"
  else
    log_msg "INFO" "pg_ctl stop -m immediate completed safely. Enforcing process cleanup."
    pkill -9 -u gpadmin -f "postgres.*-D.*$COORDINATOR_DATA_DIR"
  fi

  # 3. Wipe out IPC and Socket files
  cleanup_sockets

  log_msg "INFO" "Self-Fencing complete. Node is fully isolated from DB operations."
}

log_msg "INFO" "Keepalived instance [$NAME] state changed to: $CURRENT_STATE"

case "$CURRENT_STATE" in
  "MASTER")
    log_msg "DEBUG" "State is MASTER. Handled by notify_master.sh."
    ;;
  "BACKUP")
    log_msg "INFO" "Node entered BACKUP state. Standby DB will remain active."
    ;;
  "FAULT")
    # Ensure Fencing ONLY triggers on absolute network isolation (Split-Brain risk)
    log_msg "ERROR" "Node entered FAULT state."

    # Check network reachability to the Gateway
    GATEWAY_IP="<게이트웨이IP>"
    ping -c 2 -W 1 "$GATEWAY_IP" > /dev/null 2>&1
    PING_STATUS=$?

    if [[ $PING_STATUS -ne 0 ]]; then
      log_msg "CRITICAL" "Network Gateway ($GATEWAY_IP) is unreachable. Split-Brain risk detected. Fencing database."
      fence_database
    else
      log_msg "WARN" "Network is UP. Local DB health check failed. Dropping VIP and cleaning sockets."
      cleanup_sockets
    fi
    ;;
  "STOP")
    log_msg "INFO" "Keepalived stopping. No immediate DB fencing required."
    ;;
  "DELETED")
    log_msg "CRITICAL" "VRRP Instance DELETED from configuration. No DB action taken."
    ;;
  *)
    log_msg "WARNING" "Unknown Keepalived state received: '$CURRENT_STATE' (Args: $1 $2 $3)"
    ;;
esac

exit 0
