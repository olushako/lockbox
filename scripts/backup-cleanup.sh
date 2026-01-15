#!/bin/bash

# Script to remove backup files older than specified days
# Cleans up S3 backups for volumes, pg, and redis

# Load environment variables from .env if not already set
if [ -f .env ]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^#.*$ ]] && continue
        [[ -z $key ]] && continue
        # Only set if not already set
        if [ -z "${!key}" ]; then
            export "$key=$value"
        fi
    done < .env
fi

DAYS_TO_KEEP=${1:-${BACKUP_RETENTION_DAYS:-30}}
S3_BUCKET_NAME=${S3_BUCKET_NAME:-lockbox}

# Configure AWS CLI for S3-compatible storage
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-auto}"

echo "Cleanup script for backups older than $DAYS_TO_KEEP days"
echo "S3 Bucket: s3://$S3_BUCKET_NAME/"
echo "Backup types: volumes, pg, redis"
echo ""

# Calculate cutoff date
CUTOFF_DATE=$(date -u -v-${DAYS_TO_KEEP}d +%Y-%m-%d 2>/dev/null || date -u -d "${DAYS_TO_KEEP} days ago" +%Y-%m-%d 2>/dev/null)
echo "Cutoff date: $CUTOFF_DATE (files older than this will be deleted)"
echo ""

TOTAL_DELETED=0
TOTAL_SIZE_FREED=0

# Function to clean up S3 path
cleanup_s3_path() {
    local S3_PATH=$1
    local BACKUP_TYPE=$2
    
    echo "=== Cleaning up $BACKUP_TYPE backups ==="
    echo "S3 Path: s3://$S3_BUCKET_NAME/$S3_PATH/"
    echo ""
    
    # List all files in the path
    FILES=$(aws s3 ls "s3://$S3_BUCKET_NAME/$S3_PATH/" --recursive --endpoint-url "$S3_ENDPOINT" 2>/dev/null | grep ".7z$")
    
    if [ -z "$FILES" ]; then
        echo "No backups found in s3://$S3_BUCKET_NAME/$S3_PATH/"
        echo ""
        return
    fi
    
    LOCAL_DELETED=0
    LOCAL_SIZE=0
    
    while IFS= read -r line; do
        # Parse AWS S3 ls output: date time size filename
        FILE_DATE=$(echo "$line" | awk '{print $1}')
        FILE_SIZE=$(echo "$line" | awk '{print $3}')
        FILE_PATH=$(echo "$line" | awk '{print $4}')
        
        # Compare dates
        if [[ "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
            echo "  Deleting: s3://$S3_BUCKET_NAME/$FILE_PATH (from $FILE_DATE, $FILE_SIZE bytes)"
            
            aws s3 rm "s3://$S3_BUCKET_NAME/$FILE_PATH" --endpoint-url "$S3_ENDPOINT" > /dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                echo "    ✓ Deleted"
                LOCAL_DELETED=$((LOCAL_DELETED + 1))
                LOCAL_SIZE=$((LOCAL_SIZE + FILE_SIZE))
            else
                echo "    ✗ Failed to delete"
            fi
        fi
    done <<< "$FILES"
    
    if [ $LOCAL_DELETED -eq 0 ]; then
        echo "No backups older than $DAYS_TO_KEEP days found."
    else
        echo ""
        echo "Deleted $LOCAL_DELETED file(s) from $BACKUP_TYPE backups"
        
        # Convert size to human readable
        if [ $LOCAL_SIZE -gt 1073741824 ]; then
            SIZE_HR=$(echo "scale=2; $LOCAL_SIZE / 1073741824" | bc)
            echo "Freed up: ${SIZE_HR}GB"
        elif [ $LOCAL_SIZE -gt 1048576 ]; then
            SIZE_HR=$(echo "scale=2; $LOCAL_SIZE / 1048576" | bc)
            echo "Freed up: ${SIZE_HR}MB"
        elif [ $LOCAL_SIZE -gt 1024 ]; then
            SIZE_HR=$(echo "scale=2; $LOCAL_SIZE / 1024" | bc)
            echo "Freed up: ${SIZE_HR}KB"
        else
            echo "Freed up: ${LOCAL_SIZE}B"
        fi
    fi
    
    TOTAL_DELETED=$((TOTAL_DELETED + LOCAL_DELETED))
    TOTAL_SIZE_FREED=$((TOTAL_SIZE_FREED + LOCAL_SIZE))
    
    echo ""
}

# Clean up all three backup types
cleanup_s3_path "volumes" "VOLUMES"
cleanup_s3_path "pg" "POSTGRESQL"
cleanup_s3_path "redis" "REDIS"

echo "========================================="
echo "Cleanup completed!"
echo "Total files deleted: $TOTAL_DELETED"

if [ $TOTAL_SIZE_FREED -gt 1073741824 ]; then
    TOTAL_SIZE_HR=$(echo "scale=2; $TOTAL_SIZE_FREED / 1073741824" | bc)
    echo "Total space freed: ${TOTAL_SIZE_HR}GB"
elif [ $TOTAL_SIZE_FREED -gt 1048576 ]; then
    TOTAL_SIZE_HR=$(echo "scale=2; $TOTAL_SIZE_FREED / 1048576" | bc)
    echo "Total space freed: ${TOTAL_SIZE_HR}MB"
elif [ $TOTAL_SIZE_FREED -gt 1024 ]; then
    TOTAL_SIZE_HR=$(echo "scale=2; $TOTAL_SIZE_FREED / 1024" | bc)
    echo "Total space freed: ${TOTAL_SIZE_HR}KB"
else
    echo "Total space freed: ${TOTAL_SIZE_FREED}B"
fi
