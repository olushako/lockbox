#!/bin/bash

# Backup script for Redis databases in Docker containers
# Backs up databases from containers with backup.strategy=redis
# Uses BGSAVE for consistent snapshots
# Uses maximum compression (xz) and password protection (7z)
# Uploads to S3-compatible storage

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

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
S3_BUCKET_PATH="redis"
S3_BUCKET_NAME=${S3_BUCKET_NAME:-lockbox}
TEMP_BASE_DIR="/tmp/lockbox-backups"

# Check if password is set
if [ -z "$BACKUP_PASSWORD" ]; then
    echo "Error: BACKUP_PASSWORD not set in .env file!"
    exit 1
fi

# Check S3 configuration
if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    echo "Error: S3 configuration incomplete in .env file!"
    echo "Required: S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY"
    exit 1
fi

# Configure AWS CLI for S3-compatible storage
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}"

# Check if aws cli is available
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found. Please install it first."
    echo "Install with: brew install awscli"
    exit 1
fi

echo "Starting Redis backup at $TIMESTAMP..."
echo ""

# Get all containers
CONTAINERS=$(docker ps -a --format '{{.Names}}')

BACKUP_COUNT=0

for CONTAINER in $CONTAINERS; do
    # Check if container has backup.strategy=redis label
    BACKUP_STRATEGY=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "backup.strategy"}}')
    
    if [ "$BACKUP_STRATEGY" != "redis" ]; then
        continue
    fi
    
    echo "Backing up Redis database from container: $CONTAINER"
    
    # Get Redis data directory from volume mounts
    REDIS_DATA_DIR=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Destination}}{{end}}{{end}}')
    
    if [ -z "$REDIS_DATA_DIR" ]; then
        REDIS_DATA_DIR="/data"
    fi
    
    echo "  Redis data directory: $REDIS_DATA_DIR"
    
    # Trigger BGSAVE for consistent snapshot
    echo "  Triggering BGSAVE..."
    docker exec "$CONTAINER" redis-cli BGSAVE > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo "  ✗ Failed to trigger BGSAVE for $CONTAINER"
        continue
    fi
    
    # Wait for BGSAVE to complete (check every second, max 60 seconds)
    echo "  Waiting for BGSAVE to complete..."
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 60 ]; do
        # Check if BGSAVE is in progress
        BGSAVE_STATUS=$(docker exec "$CONTAINER" redis-cli INFO persistence 2>/dev/null | grep "rdb_bgsave_in_progress:0")
        
        if [ -n "$BGSAVE_STATUS" ]; then
            echo "  BGSAVE completed"
            break
        fi
        
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    if [ $WAIT_COUNT -eq 60 ]; then
        echo "  ✗ BGSAVE timeout for $CONTAINER"
        continue
    fi
    
    # Create container-specific directory
    CONTAINER_DIR="$TEMP_BASE_DIR/$CONTAINER"
    mkdir -p "$CONTAINER_DIR"
    
    TEMP_RDB="$CONTAINER_DIR/${CONTAINER}_${TIMESTAMP}.rdb"
    TEMP_XZ="$CONTAINER_DIR/${CONTAINER}_${TIMESTAMP}.rdb.xz"
    BACKUP_FILE="$CONTAINER_DIR/${CONTAINER}_${TIMESTAMP}.rdb.xz.7z"
    echo "  Destination: $BACKUP_FILE"
    
    # Copy dump.rdb from container
    echo "  Copying dump.rdb..."
    docker cp "$CONTAINER:$REDIS_DATA_DIR/dump.rdb" "$TEMP_RDB"
    
    if [ $? -ne 0 ]; then
        echo "  ✗ Failed to copy dump.rdb from $CONTAINER"
        rm -f "$TEMP_RDB"
        continue
    fi
    
    # Compress with xz (maximum compression)
    echo "  Compressing with xz..."
    xz -9 -z "$TEMP_RDB"
    
    if [ $? -ne 0 ]; then
        echo "  ✗ Failed to compress dump for $CONTAINER"
        rm -f "$TEMP_RDB" "$TEMP_XZ"
        continue
    fi
    
    # Encrypt with 7z using AES-256
    echo "  Encrypting with 7z..."
    7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on -mhe=on -p"$BACKUP_PASSWORD" "$BACKUP_FILE" "$TEMP_XZ" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        # Remove temporary files
        rm "$TEMP_XZ"
        SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
        
        # Upload to S3
        echo "  Uploading to S3..."
        S3_PATH="s3://$S3_BUCKET_NAME/$S3_BUCKET_PATH/$CONTAINER/${CONTAINER}_${TIMESTAMP}.rdb.xz.7z"
        
        aws s3 cp "$BACKUP_FILE" "$S3_PATH" \
            --endpoint-url "$S3_ENDPOINT" \
            --storage-class "${S3_STORAGE_CLASS:-STANDARD}" \
            --no-progress 2>&1 | grep -v "Completed"
        
        if [ $? -eq 0 ]; then
            echo "  ✓ Successfully backed up and uploaded $CONTAINER ($SIZE)"
            BACKUP_COUNT=$((BACKUP_COUNT + 1))
            
            # Remove local backup after successful upload
            rm "$BACKUP_FILE"
        else
            echo "  ✗ Failed to upload $CONTAINER to S3"
        fi
    else
        echo "  ✗ Failed to encrypt $CONTAINER with 7z"
        rm -f "$TEMP_XZ"
    fi
    echo ""
done

echo "========================================="
echo "Backup completed!"
echo "Total databases backed up and uploaded: $BACKUP_COUNT"
echo "S3 Location: s3://$S3_BUCKET_NAME/$S3_BUCKET_PATH/"
echo ""
echo "S3 backup structure:"
aws s3 ls "s3://$S3_BUCKET_NAME/$S3_BUCKET_PATH/" --recursive --endpoint-url "$S3_ENDPOINT" 2>/dev/null | grep ".7z$" | awk '{print "  s3://'$S3_BUCKET_NAME'/'$S3_BUCKET_PATH'/"$4" ("$3")"}' || echo "  (Unable to list S3 contents - check S3 credentials and permissions)"
