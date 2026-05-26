#!/bin/bash
# ============================================================================
# Script Name  : /etc/keepalived/check_my_service.sh
# Description  : Keepalived health check script for WarehousePG Standby node.
# Organization : S-Core
# Author       : Kyuhwan Lee
# Date         : 2026-03-12
# Version      : 2.0.0
# OS           : RHEL 9.4
# Ownership    : root:root or gpadmin:gpadmin (755)
# Usage        : Executed automatically by Keepalived vrrp_script directive.
# Dependencies : Keepalived, PostgreSQL/WHPG local processes
#
# Modification History:
# Date       | Version | Author          | Description
# -----------|---------|-----------------|------------------------------------
# 2025-XX-XX | 1.0.0   | paul.son (EDB)  | Initial creation for Greenplum/WHPG HA setup.
# 2026-03-12 | 2.0.0   | Kyuhwan Lee     | Applied enterprise-grade enhancements, including fixes for 'Suicide by pkill' regex bug, strict VIP/DB stop order for Split-Brain prevention, and switchover polling optimization.
# ============================================================================

TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
HOSTNAME=$(hostname)

# Use loopback address to avoid external network routing overhead
DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_USER="gpadmin"
PG_ISREADY="/usr/local/greenplum-db/bin/pg_isready"

# Execute pg_isready with OS-level timeout (2s) to prevent Keepalived blocking.
# Removed '-i' from sudo to prevent high-overhead login shell execution.
# Redirect stdout and stderr to /dev/null as Keepalived only requires the exit code.
timeout 2s "$PG_ISREADY" -h "$DB_HOST" -d gpadmin -p "$DB_PORT" -U "$DB_USER" -t 1 > /dev/null 2>&1
RETURN_CODE=$?

# pg_isready exit code evaluation:
# 0  : Accepting connections (Normal Master state)
# 64 : Rejecting connections, but in recovery (Normal Standby/Mirror state)
# 1  : Server refusing connections (Startup phase, pg_hba.conf issue)
# 2  : No response (Process down, socket error)
# 3  : Invalid argument

# The Master node must be actively accepting connections (Return Code 0)
if [[ $RETURN_CODE -eq 0 ]]; then
          # Uncomment the logger for debugging if needed
            # logger "$TIMESTAMP INFO: [$HOSTNAME] Keepalived Master check OK (RC: $RETURN_CODE)"
              exit 0
      else
                # logger "$TIMESTAMP ERROR: [$HOSTNAME] Keepalived Master check FAILED (RC: $RETURN_CODE)"
                  exit 1
