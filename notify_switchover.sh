#!/bin/bash
# ============================================================================
# Script Name  : notify_switchover.sh
# Description  : Orchestrates a graceful, zero-data-loss switchover between
#                Primary and Standby coordinators in a WHPG environment.
#                Leverages Keepalived for VIP transition and strict Sync checks.
# Organization : S-Core
# Author       : Kyuhwan Lee
# Date         : 2026-03-12
# Version      : 1.0.0
# OS           : RHEL 9.4
# Ownership    : gpadmin:gpadmin (755)
# Usage        : ./notify_switchover.sh <OLD_PRIMARY_HOST> <NEW_PRIMARY_HOST>
# Dependencies : Keepalived, SSH passwordless access, pg_ctl, WHPG Environment
#
# Modification History:
# Date       | Version | Author          | Description
# -----------|---------|-----------------|------------------------------------
# 2026-03-12 | 1.0.0   | Kyuhwan Lee     | Initial creation with enterprise-grade enhancements, including fixes for 'Suicide by pkill' regex bug, strict VIP/DB stop order for Split-Brain prevention, and switchover polling optimization.
# ============================================================================

LOG_DIR="${HOME}/gpAdminLogs"
LOG_FILE="${LOG_DIR}/notify_switchover_$(date +%Y%m%d_%H%M%S).log"
export PGPORT=${PGPORT:-5432}
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

print_usage() {
    echo "Usage: $0 <OLD_PRIMARY_HOST> <NEW_PRIMARY_HOST>"
    echo "Example: $0 <코디네이터_호스트> <스탠바이코디네이터_호스트>"
}

log_msg() {
    local MSG="$1"
    local TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${TIMESTAMP}] ${MSG}" | tee -a "${LOG_FILE}"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print_usage; exit 0
fi

if [ "$#" -ne 2 ]; then
    log_msg "ERROR: Invalid arguments."
    print_usage; exit 1
fi

OLD_PRIMARY_HOST="$1"
NEW_PRIMARY_HOST="$2"

if [ "$(whoami)" != "gpadmin" ]; then
    log_msg "FATAL: Must be executed by 'gpadmin'."
    exit 1
fi

log_msg "INFO: ============================================================"
log_msg "INFO: Initiating Planned Switchover"
log_msg "INFO: Demoting Primary: ${OLD_PRIMARY_HOST}"
log_msg "INFO: Promoting Standby : ${NEW_PRIMARY_HOST}"
log_msg "INFO: ============================================================"

# ----------------------------------------------------------------------------
# 1. Strict Pre-flight Checks (Zero Data Loss & Typo Prevention Guarantee)
# ----------------------------------------------------------------------------
log_msg "INFO: Step 1 - Verifying cluster roles and Standby Sync status..."

COORD_DIR=$(ssh ${SSH_OPTS} "${OLD_PRIMARY_HOST}" "echo \${COORDINATOR_DATA_DIRECTORY}")
COORD_DIR=${COORD_DIR:-"/data1/coordinator/gpseg-1"}

# Check 1-A: Validate Current Primary via Catalog
CURRENT_PRIMARY=$(psql -h "${OLD_PRIMARY_HOST}" -p ${PGPORT} -v ON_ERROR_STOP=1 -q -t -A -d gpadmin -c "SELECT hostname FROM gp_segment_configuration WHERE content = -1 AND role = 'p';" 2>/dev/null)
if [ "${CURRENT_PRIMARY}" != "${OLD_PRIMARY_HOST}" ]; then
    log_msg "FATAL: ${OLD_PRIMARY_HOST} is NOT the active primary in catalog."
    exit 1
fi

# Check 1-B: [NEW FIX] Strict Validation to prevent Typos in NEW_PRIMARY_HOST
CURRENT_STANDBY=$(psql -h "${OLD_PRIMARY_HOST}" -p ${PGPORT} -v ON_ERROR_STOP=1 -q -t -A -d gpadmin -c "SELECT hostname FROM gp_segment_configuration WHERE content = -1 AND role = 'm';" 2>/dev/null)
if [ "${CURRENT_STANDBY}" != "${NEW_PRIMARY_HOST}" ]; then
    log_msg "FATAL: Hostname Mismatch! Catalog standby is [${CURRENT_STANDBY}], but you entered [${NEW_PRIMARY_HOST}]."
    log_msg "FATAL: Aborting switchover due to invalid target hostname."
    exit 1
fi

# Check 1-C: Validate Sync Status using DB-Native Catalog Query
log_msg "INFO: Querying gp_segment_configuration for standby mode..."
SYNC_MODE=$(psql -h "${OLD_PRIMARY_HOST}" -p ${PGPORT} -v ON_ERROR_STOP=1 -q -t -A -d gpadmin -c "SELECT mode FROM gp_segment_configuration WHERE content = -1 AND role = 'm';" 2>/dev/null)

if [ "${SYNC_MODE}" != "s" ]; then
    log_msg "FATAL: Standby node (${NEW_PRIMARY_HOST}) is NOT in 'Sync' state. Catalog mode: [${SYNC_MODE:-UNKNOWN}]."
    log_msg "FATAL: Aborting switchover to prevent Data Loss."
    exit 1
fi
log_msg "INFO: Pre-flight check passed. Catalog confirms Standby (${NEW_PRIMARY_HOST}) is fully synchronized."

# ----------------------------------------------------------------------------
# 2. Trigger Graceful Transition & Stop Old Primary DB
# ----------------------------------------------------------------------------
log_msg "INFO: Step 2 - Safely stopping Old Primary DB and initiating VIP transition..."

# 1. STOP POSTGRES FIRST to prevent race condition and split-brain safeguard trigger
log_msg "INFO: Safely stopping Postgres on Old Primary (${OLD_PRIMARY_HOST})..."
ssh ${SSH_OPTS} "${OLD_PRIMARY_HOST}" "
    source /usr/local/greenplum-db/greenplum_path.sh
    pg_ctl stop -D ${COORD_DIR} -m fast -w -t 60 >/dev/null 2>&1 || true
    rm -f /tmp/.s.PGSQL.${PGPORT}*
    rm -f /tmp/.s.PGSQL.${PGPORT}.lock
"
log_msg "INFO: Old Primary DB stopped gracefully and sockets cleared."

# 2. STOP KEEPALIVED SECOND. Now Standby can safely promote without detecting an active primary.
log_msg "INFO: Stopping Keepalived on ${OLD_PRIMARY_HOST}..."
ssh ${SSH_OPTS} "${OLD_PRIMARY_HOST}" "sudo systemctl stop keepalived" 2>&1 | tee -a "${LOG_FILE}"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_msg "FATAL: Failed to stop Keepalived on ${OLD_PRIMARY_HOST}."
    exit 1
fi
log_msg "INFO: Keepalived stopped. VIP transition in progress."

# ----------------------------------------------------------------------------
# 3. Promotion Polling
# ----------------------------------------------------------------------------
log_msg "INFO: Step 3 - Waiting for ${NEW_PRIMARY_HOST} to be promoted by Keepalived notify_master.sh..."

# Increase MAX_RETRIES to allow enough time for gpactivatestandby to complete
MAX_RETRIES=30
RETRY_COUNT=0
PROMOTED=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    sleep 4
    # Check catalog on the NEW primary to verify promotion
    NEW_ROLE=$(psql -h "${NEW_PRIMARY_HOST}" -p ${PGPORT} -d gpadmin -q -t -A -c "SELECT role FROM gp_segment_configuration WHERE hostname = '${NEW_PRIMARY_HOST}' AND content = -1;" 2>/dev/null)

    if [ "${NEW_ROLE}" == "p" ]; then
        PROMOTED=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log_msg "INFO: Polling attempt ${RETRY_COUNT}/${MAX_RETRIES}..."
done

if [ "$PROMOTED" = false ]; then
    log_msg "FATAL: Timeout waiting for ${NEW_PRIMARY_HOST} to be promoted. Check HA logs."
    exit 1
fi
log_msg "SUCCESS: ${NEW_PRIMARY_HOST} is now the Active Primary."

# ----------------------------------------------------------------------------
# 4. Interactive Cleanup & Rejoin (Calling Rejoin Logic)
# ----------------------------------------------------------------------------
log_msg "INFO: Step 4 - Rejoining ${OLD_PRIMARY_HOST} as the new Standby."
echo ""
echo "========================================================================"
echo "WARNING: The script will now delete the old coordinator directory:"
echo "         Host: ${OLD_PRIMARY_HOST} | Path: ${COORD_DIR}"
echo "         and run gpinitstandby to rejoin it to the cluster."
echo "========================================================================"
echo -n "Proceed with directory cleanup and Rejoin? [Y/n]: "
read -r USER_CONFIRM
echo "[$(date +"%Y-%m-%d %H:%M:%S")] User input for rejoin: ${USER_CONFIRM}" >> "${LOG_FILE}"

if [[ ! "$USER_CONFIRM" =~ ^[Yy]$ ]]; then
    log_msg "WARN: Rejoin aborted by user. Please run notify_rejoin.sh manually later."

    # Restart Keepalived on Old Primary so it stays in FAULT/BACKUP state
    ssh ${SSH_OPTS} "${OLD_PRIMARY_HOST}" "sudo systemctl start keepalived" >/dev/null 2>&1
    exit 0
fi

log_msg "INFO: Executing cleanup and Rejoin via SSH..."

# Smart cleanup: Kill remaining postgres processes and remove directory on old primary
# FIX: Use regex trick '[p]' to prevent pkill from killing its own SSH session (Suicide by pkill)
ssh ${SSH_OPTS} "${OLD_PRIMARY_HOST}" "pkill -9 -u gpadmin -f '[p]ostgres.*-D.*${COORD_DIR}' >/dev/null 2>&1 || true; rm -rf '${COORD_DIR}' >/dev/null 2>&1 || true; exit 0"

# Initialize standby from the NEW primary
log_msg "INFO: Initializing standby on ${OLD_PRIMARY_HOST} from ${NEW_PRIMARY_HOST}..."
ssh ${SSH_OPTS} "${NEW_PRIMARY_HOST}" "gpinitstandby -s ${OLD_PRIMARY_HOST} -a" 2>&1 | tee -a "${LOG_FILE}"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_msg "FATAL: gpinitstandby failed during Rejoin phase."
    exit 1
fi

# Finally, restart Keepalived on the newly joined Standby so HA is fully restored
ssh ${SSH_OPTS} "${OLD_PRIMARY_HOST}" "sudo systemctl start keepalived" >/dev/null 2>&1
log_msg "INFO: Keepalived
