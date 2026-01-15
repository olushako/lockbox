#!/bin/bash

# Backup script for Docker named volumes based on container labels
# Backs up volumes from containers with backup.strategy=volume
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
S3_BUCKET_PATH="volumes"
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
echo "Starting labeled volume backup at $TIMESTAMP..."
echo ""

# Get all containers
CONTAINERS=$(docker ps -a --format '{{.Names}}')

BACKUP_COUNT=0

for CONTAINER in $CONTAINERS; do
    # Check if container has backup.strategy=volume label
    BACKUP_STRATEGY=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "backup.strategy"}}')
    
    if [ "$BACKUP_STRATEGY" != "volume" ]; then
        continue
    fi
    
    # Get named volumes for this container
    VOLUMES=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}')
    
    if [ -z "$VOLUMES" ]; then
        echo "Container $CONTAINER has backup.strategy=volume but no named volumes"
        continue
    fi
    
    echo "Backing up volumes for container: $CONTAINER"
    
    for VOLUME in $VOLUMES; do
        # Create volume-specific directory
        VOLUME_DIR="$TEMP_BASE_DIR/$VOLUME"
        mkdir -p "$VOLUME_DIR"
        
        BACKUP_FILE="$VOLUME_DIR/${VOLUME}_${TIMESTAMP}.tar.xz.7z"
        echo "  - Backing up volume: $VOLUME"
        echo "    Destination: $BACKUP_FILE"
        
        # Create a temporary tar.xz file first (maximum compression)
        TEMP_TAR="$VOLUME_DIR/${VOLUME}_${TIMESTAMP}.tar.xz"
        
        docker run --rm \
            -v "$VOLUME:/volume" \
            -v "$VOLUME_DIR:/backup" \
            alpine \
            sh -c "apk add --no-cache xz > /dev/null 2>&1 && tar cJf /backup/${VOLUME}_${TIMESTAMP}.tar.xz -C /volume ."
        
        if [ $? -ne 0 ]; then
            echo "    ✗ Failed to create tar.xz for $VOLUME"
            continue
        fi
        
        # Encrypt with 7z using AES-256
        7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on -mhe=on -p"$BACKUP_PASSWORD" "$BACKUP_FILE" "$TEMP_TAR" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            # Remove temporary tar.xz file
            rm "$TEMP_TAR"
            SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
            
            # Upload to S3
            echo "    Uploading to S3..."
            S3_PATH="s3://$S3_BUCKET_NAME/$S3_BUCKET_PATH/$VOLUME/${VOLUME}_${TIMESTAMP}.tar.xz.7z"
            
            aws s3 cp "$BACKUP_FILE" "$S3_PATH" \
                --endpoint-url "$S3_ENDPOINT" \
                --storage-class "${S3_STORAGE_CLASS:-STANDARD}" \
                --no-progress 2>&1 | grep -v "Completed"
            
            if [ $? -eq 0 ]; then
                echo "    ✓ Successfully backed up and uploaded $VOLUME ($SIZE)"
                BACKUP_COUNT=$((BACKUP_COUNT + 1))
                
                # Remove local backup after successful upload
                rm "$BACKUP_FILE"
            else
                echo "    ✗ Failed to upload $VOLUME to S3"
            fi
        else
            echo "    ✗ Failed to encrypt $VOLUME with 7z"
            rm -f "$TEMP_TAR"
        fi
    done
    echo ""
done

echo "========================================="
echo "Backup completed!"
echo "Total volumes backed up and uploaded: $BACKUP_COUNT"
echo "S3 Location: s3://$S3_BUCKET_NAME/$S3_BUCKET_PATH/"
echo ""
echo "S3 backup structure:"
aws s3 ls "s3://$S3_BUCKET_NAME/$S3_BUCKET_PATH/" --recursive --endpoint-url "$S3_ENDPOINT" 2>/dev/null | grep ".7z$" | awk '{print "  s3://'$S3_BUCKET_NAME'/'$S3_BUCKET_PATH'/"$4" ("$3")"}' || echo "  (Unable to list S3 contents - check S3 credentials and permissions)"
