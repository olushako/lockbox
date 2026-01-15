#!/bin/bash

# Simple cron-like scheduler without using crond
# Runs backup scripts on schedule

while true; do
    CURRENT_HOUR=$(date +%H)
    CURRENT_MINUTE=$(date +%M)
    CURRENT_DAY=$(date +%u)  # 1=Monday, 7=Sunday
    
    # Backup volumes daily at 2:00 AM
    if [ "$CURRENT_HOUR" = "02" ] && [ "$CURRENT_MINUTE" = "00" ]; then
        echo "$(date): Running volume backup..."
        /app/backup-volumes.sh >> /var/log/backups/volumes.log 2>&1
        sleep 60  # Sleep to avoid running multiple times in the same minute
    fi
    
    # Backup PostgreSQL daily at 2:30 AM
    if [ "$CURRENT_HOUR" = "02" ] && [ "$CURRENT_MINUTE" = "30" ]; then
        echo "$(date): Running PostgreSQL backup..."
        /app/backup-pg.sh >> /var/log/backups/pg.log 2>&1
        sleep 60
    fi
    
    # Backup Redis daily at 3:00 AM
    if [ "$CURRENT_HOUR" = "03" ] && [ "$CURRENT_MINUTE" = "00" ]; then
        echo "$(date): Running Redis backup..."
        /app/backup-redis.sh >> /var/log/backups/redis.log 2>&1
        sleep 60
    fi
    
    # Cleanup old backups weekly on Sunday at 4:00 AM
    if [ "$CURRENT_DAY" = "7" ] && [ "$CURRENT_HOUR" = "04" ] && [ "$CURRENT_MINUTE" = "00" ]; then
        echo "$(date): Running backup cleanup..."
        /app/backup-cleanup.sh >> /var/log/backups/cleanup.log 2>&1
        sleep 60
    fi
    
    # Check every 30 seconds
    sleep 30
done
