#!/bin/bash
# ============================================================================
# Script Name  : notify_rejoin.sh
# Description  : Safely rejoins an isolated/fenced node as a standby coordinator.
#                [SECURITY ENFORCED] Execution is strictly limited to the target host itself.
# Organization : S-Core
# Author       : Kyuhwan Lee
# Date         : 2026-05-04
# Version      : 1.1.0
# OS           : RHEL 9.4
# Ownership    : gpadmin:gpadmin (755)
# Usage        : ./notify_rejoin.sh <TARGET_HOST_TO_REJOIN>
# Dependencies : gpinitstandby, SSH passwordless access (gpadmin)
#
# Modification History:
# Date       | Version | Author          | Description
# -----------|---------|-----------------|------------------------------------
# 2026-03-12 | 1.0.0   | Kyuhwan Lee     | Initial creation with enterprise-grade enhancements.
# 2026-03-12 | 2.0.0  | Kyuhwan Lee   | Applied enterprise-grade enhancements, 
#                                       including fixes for 'Suicide by pkill' regex bug, 
#                                       strict VIP/DB stop order for Split-Brain prevention, 
#                                       and switchover polling optimization.
# ============================================================================

# ----------------------------------------------------------------------------
# Environment Variables & Configuration
# ----------------------------------------------------------------------------
LOG_DIR="${HOME}/gpAdminLogs"
LOG_FILE="${LOG_DIR}/notify_rejoin_$(date +%Y%m%d_%H%M%S).log"
export PGPORT=${PGPORT:-5432}

# SSH Options for checking primary and executing gpinitstandby remotely
SSH_OPTS="-q -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=QUIET"

# Define Coordinator hosts via Environment Variable. Fallback to defaults.
CLUSTER_HOSTS=${COORDINATOR_HOSTS:-"<코디네이터_호스트> <스탠바이코디네이터_호스트>"}

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

log_msg() {
    local MSG="$1"
    local TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${TIMESTAMP}] ${MSG}" | tee -a "${LOG_FILE}"
}

print_usage() {
    echo "Usage: $0 <REJOIN_TARGET_HOST>"
    echo "Example: export COORDINATOR_HOSTS='node1 node2' && $0 \$(hostname)"
}

# ----------------------------------------------------------------------------
# 1. Parse Arguments & Initial Validations
# ----------------------------------------------------------------------------
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print_usage
    exit 0
fi

if [ "$#" -ne 1 ]; then
    echo "ERROR: Invalid number of arguments."
    print_usage
    exit 1
fi

TARGET_HOST="$1"
LOCAL_HOST=$(hostname)
CURRENT_USER=$(whoami)

if [ "${CURRENT_USER}" != "gpadmin" ]; then
    log_msg "FATAL: This script must be executed by the 'gpadmin' user."
    exit 1
fi

# [CRITICAL UPDATE] Rule Enforcement: Rejoin target MUST be the local host.
if [ "${TARGET_HOST}" != "${LOCAL_HOST}" ]; then
    log_msg "FATAL: Target host (${TARGET_HOST}) does not match local host (${LOCAL_HOST}). Remote rejoin execution is restricted."
    exit 1
fi

log_msg "INFO: Starting Rejoin Process for target host: ${TARGET_HOST}"
log_msg "INFO: Target Cluster Hosts pool: [${CLUSTER_HOSTS}]"

# ----------------------------------------------------------------------------
# 2. Identify the Active Primary Coordinator
# ----------------------------------------------------------------------------
log_msg "INFO: Step 1 - Identifying the current Active Primary Coordinator..."

ACTIVE_PRIMARY=""
for host in ${CLUSTER_HOSTS}; do
    if ssh ${SSH_OPTS} "${host}" "pg_isready -p ${PGPORT} -q" 2>/dev/null; then
        IS_RECOVERY=$(ssh ${SSH_OPTS} "${host}" "psql -p ${PGPORT} -t -A -c 'SELECT pg_is_in_recovery();'" 2>/dev/null)
        if [ "$IS_RECOVERY" == "f" ]; then
            ACTIVE_PRIMARY="${host}"
            break
        fi
    fi
done

if [ -z "${ACTIVE_PRIMARY}" ]; then
    log_msg "FATAL: Cannot detect an Active Primary Coordinator in the cluster."
    exit 1
fi

log_msg "INFO: Active Primary identified as: [${ACTIVE_PRIMARY}]"

if [ "${TARGET_HOST}" == "${ACTIVE_PRIMARY}" ]; then
    log_msg "FATAL: The target host (${TARGET_HOST}) is currently the Active Primary. Cannot rejoin."
    exit 1
fi

# Ensure GP environment is sourced on the remote node before echoing variables
REMOTE_GP_SRC="source /usr/local/greenplum-db/greenplum_path.sh"
COORD_DIR=$(ssh ${SSH_OPTS} "${ACTIVE_PRIMARY}" "${REMOTE_GP_SRC} && echo \${COORDINATOR_DATA_DIRECTORY}")
COORD_DIR=${COORD_DIR:-"/data1/coordinator/gpseg-1"}
log_msg "INFO: Coordinator data directory is set to: ${COORD_DIR}"

# ----------------------------------------------------------------------------
# 3. Clean up existing Standby catalog entries on the Active Primary
# ----------------------------------------------------------------------------
log_msg "INFO: Step 2 - Removing any stale standby configurations from the catalog..."

STALE_STANDBY=$(ssh ${SSH_OPTS} "${ACTIVE_PRIMARY}" "psql -p ${PGPORT} -t -A -c \"SELECT hostname FROM gp_segment_configuration WHERE content = -1 AND role = 'm';\"" 2>/dev/null)

if [ -n "${STALE_STANDBY}" ]; then
    log_msg "WARN: Found stale standby configuration for host [${STALE_STANDBY}]. Removing it..."
    ssh ${SSH_OPTS} "${ACTIVE_PRIMARY}" "${REMOTE_GP_SRC} && gpinitstandby -r -a" 2>&1 | tee -a "${LOG_FILE}"
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_msg "FATAL: Failed to remove stale standby configuration."
        exit 1
    fi
else
    log_msg "INFO: No stale standby configuration found. Proceeding."
fi

# ----------------------------------------------------------------------------
# 4. Target Host Cleanup (Local Execution Only)
# ----------------------------------------------------------------------------
log_msg "INFO: Step 3 - Cleaning up old data directory on target host: ${TARGET_HOST}..."

# Safety Check: Ensure COORD_DIR is not empty to prevent catastrophic rm -rf /
if [ -z "${COORD_DIR}" ]; then
    log_msg "FATAL: COORD_DIR variable is empty. Aborting to prevent accidental data loss."
    exit 1
fi

log_msg "INFO: Target is local host. Executing cleanup directly..."
pkill -9 -u gpadmin -f "postgres.*-D.*${COORD_DIR}" >/dev/null 2>&1 || true

rm -rf "${COORD_DIR}" >/dev/null 2>&1
CLEANUP_STATUS=$?

if [ ${CLEANUP_STATUS} -ne 0 ]; then
    log_msg "FATAL: Failed to execute cleanup on target host ${TARGET_HOST}. Check directory permissions."
    exit 1
fi

log_msg "INFO: Cleanup completed safely."

# ----------------------------------------------------------------------------
# 5. Execute Rejoin (Initialize Standby) from Active Primary
# ----------------------------------------------------------------------------
log_msg "INFO: Step 4 - Initializing standby coordinator on ${TARGET_HOST}..."

ssh ${SSH_OPTS} "${ACTIVE_PRIMARY}" "${REMOTE_GP_SRC} && gpinitstandby -s ${TARGET_HOST} -a" 2>&1 | tee -a "${LOG_FILE}"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_msg "FATAL: gpinitstandby utility failed."
    exit 1
fi
log_msg "INFO: Standby coordinator initialization successful."

# ----------------------------------------------------------------------------
# 6. Final Status Validation
# ----------------------------------------------------------------------------
log_msg "INFO: Step 5 - Validating final cluster state..."
echo "---------------------------------------------------------" | tee -a "${LOG_FILE}"
ssh ${SSH_OPTS} "${ACTIVE_PRIMARY}" "psql -p ${PGPORT} -c \"SELECT hostname, role, status FROM gp_segment_configuration WHERE content = -1;\"" 2>&1 | tee -a "${LOG_FILE}"
echo "---------------------------------------------------------" | tee -a "${LOG_FILE}"

log_msg "INFO: Rejoin process successfully finished."
exit 0
