#!/bin/bash
# ============================================================================
# Script Name : /etc/keepalived/notify_master.sh
# Description : Orchestrates WHPG transition to MASTER state.
#              Triggered by Keepalived during VIP acquisition.
# Organization : S-Core
# Author    : Kyuhwan Lee
# Date     : 2026-03-12
# Version   : 2.0.0
# OS      : RHEL 9.4
# Ownership  : root:root or gpadmin:gpadmin (755)
# Usage    : ./notify_master.sh <TYPE> <NAME> <STATE>
# Dependencies : Keepalived, PostgreSQL/WHPG Client (psql)
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
CURRENT_STATE="${1:-MASTER}"
LOG_DIR="/dbaashome/gpadmin/gpAdminLogs"
LOG_FILE="${LOG_DIR}/whpg_failover_$(date +%Y%m%d).log"
LOGGER_TAG="WHPG_HA_NOTIFY"

get_time() {
  date +"%Y-%m-%d %H:%M:%S"
}

logger -t "$LOGGER_TAG" "$(get_time) INFO: [$HOSTNAME] notify_master.sh triggered. State: $CURRENT_STATE"

if [[ "$CURRENT_STATE" == "MASTER" ]]; then


  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"
  chmod 644 "${LOG_FILE}"
  chown gpadmin:gpadmin "${LOG_FILE}" >/dev/null 2>&1 || true

  echo "===================================================" >> "${LOG_FILE}"
  echo "[$(get_time)] INFO: HA Failover/Switchover process started on $HOSTNAME." >> "${LOG_FILE}"

  GP_PATH_SCRIPT="/usr/local/greenplum-db/greenplum_path.sh"
  export COORDINATOR_DATA_DIRECTORY="/data1/coordinator/gpseg-1"
  export PGPORT=5432

  if [ -f "$GP_PATH_SCRIPT" ]; then
    source "$GP_PATH_SCRIPT"
  else
    echo "[$(get_time)] FATAL: Cannot find GP_PATH_SCRIPT." >> "${LOG_FILE}"
    exit 1
  fi

  SIGNAL_FILE="${COORDINATOR_DATA_DIRECTORY}/standby.signal"

  if [ -f "$SIGNAL_FILE" ]; then
    echo "[$(get_time)] INFO: standby.signal found. Proceeding with gpactivatestandby..." >> "${LOG_FILE}"

    MAX_RETRIES=6
    RETRY_DELAY=5
    ATTEMPT=1
    IS_PROMOTED=0

    while [ $ATTEMPT -le $MAX_RETRIES ]; do
      echo "[$(get_time)] INFO: Executing gpactivatestandby (Attempt $ATTEMPT/$MAX_RETRIES)..." >> "${LOG_FILE}"

      gpactivatestandby -d "${COORDINATOR_DATA_DIRECTORY}" -a >> "${LOG_FILE}" 2>&1
      SERVICE_START_STATUS=$?

      if [[ $SERVICE_START_STATUS -eq 0 ]]; then
        logger -t "$LOGGER_TAG" "$(get_time) SUCCESS: [$HOSTNAME] WHPG Standby activated successfully."
        echo "[$(get_time)] SUCCESS: gpactivatestandby completed." >> "${LOG_FILE}"
        IS_PROMOTED=1
        break
      else
        echo "[$(get_time)] WARN: gpactivatestandby failed with exit code $SERVICE_START_STATUS." >> "${LOG_FILE}"
        echo "[$(get_time)] WARN: Old Primary might still be shutting down. Waiting $RETRY_DELAY seconds..." >> "${LOG_FILE}"
        sleep $RETRY_DELAY
        ((ATTEMPT++))
      fi
    done

    if [[ $IS_PROMOTED -eq 0 ]]; then
      echo "[$(get_time)] FATAL: gpactivatestandby failed or aborted after maximum retries." >> "${LOG_FILE}"
      echo "[$(get_time)] FATAL: Initiating Self-Fencing. Stopping Keepalived to release VIP..." >> "${LOG_FILE}"
      logger -t "$LOGGER_TAG" "$(get_time) FATAL: [$HOSTNAME] Promotion failed. Triggering Self-Fencing (Keepalived Stop)."

      # [CRITICAL FIX] Self-Fencing logic to prevent Network Split-Brain
      sudo systemctl stop keepalived

      echo "[$(get_time)] INFO: Self-Fencing complete. Node isolated to prevent network collision." >> "${LOG_FILE}"
      exit 1
    fi
  else
    echo "[$(get_time)] INFO: Node is already Primary. Promotion logic skipped." >> "${LOG_FILE}"
  fi
else
  logger -t "$LOGGER_TAG" "$(get_time) WARN: [$HOSTNAME] State is not MASTER ($CURRENT_STATE)."
fi

exit 0
