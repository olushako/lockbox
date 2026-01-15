#!/bin/bash
set -e

echo "========================================="
echo "Lockbox Backup Container"
echo "========================================="
echo "Starting at: $(date)"
echo ""

# Check required environment variables
if [ -z "$BACKUP_PASSWORD" ]; then
    echo "ERROR: BACKUP_PASSWORD environment variable is required!"
    exit 1
fi

if [ -z "$S3_ENDPOINT" ]; then
    echo "ERROR: S3_ENDPOINT environment variable is required!"
    exit 1
fi

if [ -z "$S3_ACCESS_KEY" ]; then
    echo "ERROR: S3_ACCESS_KEY environment variable is required!"
    exit 1
fi

if [ -z "$S3_SECRET_KEY" ]; then
    echo "ERROR: S3_SECRET_KEY environment variable is required!"
    exit 1
fi

echo "Configuration:"
echo "  S3 Endpoint: $S3_ENDPOINT"
echo "  S3 Bucket: ${S3_BUCKET_NAME:-lockbox}"
echo "  S3 Region: ${S3_REGION:-auto}"
echo "  Backup Retention: ${BACKUP_RETENTION_DAYS:-30} days"
echo "  Timezone: ${TZ:-UTC}"
echo ""

# Validate BACKUP_RETENTION_DAYS is a positive integer
if [ -n "$BACKUP_RETENTION_DAYS" ]; then
    if ! [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || [ "$BACKUP_RETENTION_DAYS" -lt 1 ]; then
        echo "ERROR: BACKUP_RETENTION_DAYS must be a positive integer (got: $BACKUP_RETENTION_DAYS)"
        exit 1
    fi
fi

# Validate S3_ENDPOINT format
if ! [[ "$S3_ENDPOINT" =~ ^https?:// ]]; then
    echo "ERROR: S3_ENDPOINT must start with http:// or https:// (got: $S3_ENDPOINT)"
    exit 1
fi

# Test Docker socket access
if ! docker ps > /dev/null 2>&1; then
    echo "ERROR: Cannot access Docker socket!"
    echo "Make sure to mount /var/run/docker.sock"
    exit 1
fi

echo "Docker socket: OK"
echo ""

# Generate crontab from environment variables
echo "Generating crontab from environment variables..."

# Default schedules - all run once daily at night
CRON_VOLUMES="${CRON_VOLUMES:-0 2 * * *}"
CRON_PG="${CRON_PG:-15 2 * * *}"
CRON_REDIS="${CRON_REDIS:-30 2 * * *}"
CRON_CLEANUP="${CRON_CLEANUP:-45 2 * * *}"

# Function to validate cron expression
validate_cron() {
    local cron_expr="$1"
    local var_name="$2"
    
    # Basic validation: should have 5 fields (minute hour day month weekday)
    local field_count=$(echo "$cron_expr" | awk '{print NF}')
    if [ "$field_count" -ne 5 ]; then
        echo "ERROR: Invalid cron expression for $var_name: '$cron_expr'"
        echo "       Expected format: minute hour day month weekday (5 fields)"
        echo "       Example: 0 2 * * * (daily at 2:00 AM)"
        return 1
    fi
    
    return 0
}

# Validate all cron expressions
echo "Validating cron schedules..."
validate_cron "$CRON_VOLUMES" "CRON_VOLUMES" || exit 1
validate_cron "$CRON_PG" "CRON_PG" || exit 1
validate_cron "$CRON_REDIS" "CRON_REDIS" || exit 1
validate_cron "$CRON_CLEANUP" "CRON_CLEANUP" || exit 1
echo "  ✓ All cron schedules are valid"
echo ""

# Generate crontab
cat > /etc/crontabs/root << EOF
# Backup schedules (generated from environment variables)
# Format: minute hour day month weekday command

# Backup volumes (CRON_VOLUMES)
$CRON_VOLUMES /app/backup-volumes.sh >> /var/log/backups/volumes.log 2>&1

# Backup PostgreSQL databases (CRON_PG)
$CRON_PG /app/backup-pg.sh >> /var/log/backups/pg.log 2>&1

# Backup Redis databases (CRON_REDIS)
$CRON_REDIS /app/backup-redis.sh >> /var/log/backups/redis.log 2>&1

# Cleanup old backups (CRON_CLEANUP)
$CRON_CLEANUP /app/backup-cleanup.sh >> /var/log/backups/cleanup.log 2>&1

# Log rotation marker
0 5 * * * echo "=== \$(date) ===" >> /var/log/backups/cron.log 2>&1
EOF

chmod 0644 /etc/crontabs/root

echo ""
echo "Cron schedule:"
cat /etc/crontabs/root | grep -v "^#" | grep -v "^$"
echo ""

echo "========================================="
echo "Starting cron daemon..."
echo "========================================="
echo ""

# Disable exit on error for crond startup (Alpine crond emits harmless setpgid error)
set +e
crond -b -l 2
CROND_EXIT=$?
set -e

if [ $CROND_EXIT -ne 0 ]; then
    echo "ERROR: Failed to start crond (exit code: $CROND_EXIT)"
    exit 1
fi

# Verify crond is running
sleep 1
if ! pgrep crond > /dev/null; then
    echo "ERROR: crond process not found after startup!"
    exit 1
fi

echo "Cron daemon started successfully!"
echo "Container will keep running. Check logs in /var/log/backups/"
echo ""

# Keep container running
tail -f /dev/null
