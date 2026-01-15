#!/bin/bash

# Universal restore script for volumes, PostgreSQL, and Redis backups
# Usage: ./restore.sh <type> <name> <backup-file>
#        ./restore.sh all-volumes
#        ./restore.sh all-pg
#        ./restore.sh all-redis
# Types: volume, pg, redis, all-volumes, all-pg, all-redis
# Examples:
#   ./restore.sh volume vol1 s3://lockbox/volumes/vol1/vol1_20260115_132221.tar.xz.7z
#   ./restore.sh pg postgres-db s3://lockbox/pg/postgres-db/postgres-db_20260115_125716.sql.xz.7z
#   ./restore.sh redis redis-db s3://lockbox/redis/redis-db/redis-db_20260115_131745.rdb.xz.7z
#   ./restore.sh all-volumes
#   ./restore.sh all-pg
#   ./restore.sh all-redis

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

# Configure AWS CLI for S3-compatible storage
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-auto}"
S3_BUCKET_NAME=${S3_BUCKET_NAME:-lockbox}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <type> [name] [backup-file]"
    echo ""
    echo "Types:"
    echo "  volume       - Restore specific Docker volume"
    echo "  pg           - Restore specific PostgreSQL database"
    echo "  redis        - Restore specific Redis database"
    echo "  all-volumes  - Restore all volumes (latest backups)"
    echo "  all-pg       - Restore all PostgreSQL databases (latest backups)"
    echo "  all-redis    - Restore all Redis databases (latest backups)"
    echo ""
    echo "Examples:"
    echo "  $0 volume vol1 s3://lockbox/volumes/vol1/vol1_20260115_132221.tar.xz.7z"
    echo "  $0 pg postgres-db s3://lockbox/pg/postgres-db/postgres-db_20260115_125716.sql.xz.7z"
    echo "  $0 redis redis-db s3://lockbox/redis/redis-db/redis-db_20260115_131745.rdb.xz.7z"
    echo "  $0 all-volumes"
    echo "  $0 all-pg"
    echo "  $0 all-redis"
    exit 1
fi

TYPE=$1

# Handle "all" commands
if [[ "$TYPE" == "all-"* ]]; then
    # Extract the actual type
    RESTORE_TYPE="${TYPE#all-}"
    
    case $RESTORE_TYPE in
        volumes)
            S3_PATH="volumes"
            ;;
        pg)
            S3_PATH="pg"
            ;;
        redis)
            S3_PATH="redis"
            ;;
        *)
            echo "Error: Invalid type '$TYPE'"
            exit 1
            ;;
    esac
    
    echo "========================================="
    echo "Restoring all $RESTORE_TYPE (latest backups)"
    echo "========================================="
    echo ""
    
    # List all items in S3 path
    ITEMS=$(aws s3 ls "s3://$S3_BUCKET_NAME/$S3_PATH/" --endpoint-url "$S3_ENDPOINT" 2>/dev/null | grep "PRE" | awk '{print $2}' | sed 's/\///')
    
    if [ -z "$ITEMS" ]; then
        echo "No backups found in s3://$S3_BUCKET_NAME/$S3_PATH/"
        exit 0
    fi
    
    TOTAL=0
    SUCCESS=0
    FAILED=0
    
    for ITEM in $ITEMS; do
        echo "Processing: $ITEM"
        
        # Get latest backup for this item
        LATEST_BACKUP=$(aws s3 ls "s3://$S3_BUCKET_NAME/$S3_PATH/$ITEM/" --endpoint-url "$S3_ENDPOINT" 2>/dev/null | grep ".7z$" | sort | tail -1 | awk '{print $4}')
        
        if [ -z "$LATEST_BACKUP" ]; then
            echo "  No backups found for $ITEM"
            echo ""
            continue
        fi
        
        BACKUP_PATH="s3://$S3_BUCKET_NAME/$S3_PATH/$ITEM/$LATEST_BACKUP"
        echo "  Latest backup: $LATEST_BACKUP"
        
        TOTAL=$((TOTAL + 1))
        
        # Restore without confirmation for batch mode
        export BATCH_MODE=1
        
        if [ "$RESTORE_TYPE" = "volumes" ]; then
            $0 volume "$ITEM" "$BACKUP_PATH" < /dev/null
        elif [ "$RESTORE_TYPE" = "pg" ]; then
            $0 pg "$ITEM" "$BACKUP_PATH" < /dev/null
        elif [ "$RESTORE_TYPE" = "redis" ]; then
            $0 redis "$ITEM" "$BACKUP_PATH" < /dev/null
        fi
        
        if [ $? -eq 0 ]; then
            SUCCESS=$((SUCCESS + 1))
            echo "  ✓ Successfully restored $ITEM"
        else
            FAILED=$((FAILED + 1))
            echo "  ✗ Failed to restore $ITEM"
        fi
        
        echo ""
    done
    
    echo "========================================="
    echo "Batch Restore Summary"
    echo "========================================="
    echo "Total: $TOTAL"
    echo "Success: $SUCCESS"
    echo "Failed: $FAILED"
    
    exit 0
fi

# Single restore mode
if [ $# -lt 3 ]; then
    echo "Usage: $0 <type> <name> <backup-file>"
    echo ""
    echo "For batch restore, use: $0 all-volumes|all-pg|all-redis"
    exit 1
fi
NAME=$2
BACKUP_FILE=$3

# Check if password is set
if [ -z "$BACKUP_PASSWORD" ]; then
    echo "Error: BACKUP_PASSWORD not set in .env file!"
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d)

echo "========================================="
echo "Restore Configuration"
echo "========================================="
echo "Type: $TYPE"
echo "Name: $NAME"
echo "Backup: $BACKUP_FILE"
echo ""

# Download from S3 if needed
if [[ "$BACKUP_FILE" == s3://* ]]; then
    echo "Downloading backup from S3..."
    LOCAL_BACKUP="$TEMP_DIR/backup.7z"
    
    aws s3 cp "$BACKUP_FILE" "$LOCAL_BACKUP" --endpoint-url "$S3_ENDPOINT" --no-progress
    
    if [ $? -ne 0 ]; then
        echo "✗ Failed to download backup from S3"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    BACKUP_FILE="$LOCAL_BACKUP"
    echo "✓ Downloaded"
    echo ""
fi

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Decrypting and decompressing backup..."

# Decrypt with 7z
7z x -p"$BACKUP_PASSWORD" -o"$TEMP_DIR" "$BACKUP_FILE" > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "✗ Failed to decrypt backup file"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Find the compressed file
COMPRESSED_FILE=$(find "$TEMP_DIR" -type f \( -name "*.tar.xz" -o -name "*.sql.xz" -o -name "*.rdb.xz" \) | head -1)

if [ -z "$COMPRESSED_FILE" ]; then
    echo "✗ No compressed file found after decryption"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Decompress with xz
xz -d "$COMPRESSED_FILE"

if [ $? -ne 0 ]; then
    echo "✗ Failed to decompress backup file"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "✓ Decrypted and decompressed"
echo ""

# Restore based on type
case $TYPE in
    volume)
        echo "Restoring volume: $NAME"
        echo ""
        
        # Find the tar file
        TAR_FILE=$(find "$TEMP_DIR" -name "*.tar" | head -1)
        
        if [ -z "$TAR_FILE" ]; then
            echo "✗ No tar file found"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Check if volume exists
        if ! docker volume inspect "$NAME" > /dev/null 2>&1; then
            echo "Creating volume: $NAME"
            docker volume create "$NAME"
        fi
        
        # Skip confirmation in batch mode
        if [ -z "$BATCH_MODE" ]; then
            read -p "This will overwrite volume '$NAME'. Continue? (yes/no): " CONFIRM
            
            if [ "$CONFIRM" != "yes" ]; then
                echo "Restore cancelled."
                rm -rf "$TEMP_DIR"
                exit 0
            fi
        fi
        
        echo ""
        echo "Restoring volume data..."
        
        # Restore volume using a temporary container
        docker run --rm \
            -v "$NAME:/volume" \
            -v "$TEMP_DIR:/backup" \
            alpine \
            sh -c "rm -rf /volume/* /volume/..?* /volume/.[!.]* 2>/dev/null; tar xf /backup/$(basename $TAR_FILE) -C /volume"
        
        if [ $? -eq 0 ]; then
            echo ""
            echo "✓ Successfully restored volume: $NAME"
        else
            echo ""
            echo "✗ Failed to restore volume"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        ;;
        
    pg)
        echo "Restoring PostgreSQL database: $NAME"
        echo ""
        
        # Find the SQL file
        SQL_FILE=$(find "$TEMP_DIR" -name "*.sql" | head -1)
        
        if [ -z "$SQL_FILE" ]; then
            echo "✗ No SQL file found"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Check if container exists and is running
        if ! docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
            echo "Error: Container '$NAME' is not running"
            echo ""
            echo "To restore, you need to create the PostgreSQL container first:"
            echo "  docker run -d --name $NAME --label backup.strategy=pg \\"
            echo "    -e POSTGRES_PASSWORD=<password> \\"
            echo "    -e POSTGRES_USER=postgres \\"
            echo "    -e POSTGRES_DB=<dbname> \\"
            echo "    -v pgdata:/var/lib/postgresql/data \\"
            echo "    postgres:16-alpine"
            echo ""
            echo "Then run this restore command again."
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Get PostgreSQL user
        POSTGRES_USER=$(docker inspect "$NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep POSTGRES_USER | cut -d'=' -f2)
        POSTGRES_USER=${POSTGRES_USER:-postgres}
        
        echo "PostgreSQL user: $POSTGRES_USER"
        echo ""
        
        # Skip confirmation in batch mode
        if [ -z "$BATCH_MODE" ]; then
            read -p "This will overwrite existing data in '$NAME'. Continue? (yes/no): " CONFIRM
            
            if [ "$CONFIRM" != "yes" ]; then
                echo "Restore cancelled."
                rm -rf "$TEMP_DIR"
                exit 0
            fi
        fi
        
        echo ""
        echo "Restoring database..."
        
        # Restore using psql
        docker exec -i "$NAME" psql -U "$POSTGRES_USER" < "$SQL_FILE" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            echo ""
            echo "✓ Successfully restored PostgreSQL database: $NAME"
        else
            echo ""
            echo "✗ Failed to restore database"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        ;;
        
    redis)
        echo "Restoring Redis database: $NAME"
        echo ""
        
        # Find the RDB file
        RDB_FILE=$(find "$TEMP_DIR" -name "*.rdb" | head -1)
        
        if [ -z "$RDB_FILE" ]; then
            echo "✗ No RDB file found"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Check if container exists and is running
        if ! docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
            echo "Error: Container '$NAME' is not running"
            echo ""
            echo "To restore, you need to create the Redis container first:"
            echo "  docker run -d --name $NAME --label backup.strategy=redis \\"
            echo "    -v redis-data:/data \\"
            echo "    redis:7-alpine"
            echo ""
            echo "Then run this restore command again."
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Get Redis data directory
        REDIS_DATA_DIR=$(docker inspect "$NAME" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Destination}}{{end}}{{end}}')
        REDIS_DATA_DIR=${REDIS_DATA_DIR:-/data}
        
        echo "Redis data directory: $REDIS_DATA_DIR"
        echo ""
        
        # Skip confirmation in batch mode
        if [ -z "$BATCH_MODE" ]; then
            read -p "This will overwrite existing data in '$NAME'. Continue? (yes/no): " CONFIRM
            
            if [ "$CONFIRM" != "yes" ]; then
                echo "Restore cancelled."
                rm -rf "$TEMP_DIR"
                exit 0
            fi
        fi
        
        echo ""
        echo "Stopping Redis to restore data..."
        
        # Stop Redis gracefully
        docker exec "$NAME" redis-cli SHUTDOWN NOSAVE > /dev/null 2>&1
        sleep 2
        
        # Copy the RDB file to container
        echo "Copying dump.rdb to container..."
        docker cp "$RDB_FILE" "$NAME:$REDIS_DATA_DIR/dump.rdb"
        
        if [ $? -ne 0 ]; then
            echo "✗ Failed to copy dump.rdb to container"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Restart Redis container to load the data
        echo "Restarting Redis container..."
        docker restart "$NAME" > /dev/null 2>&1
        
        if [ $? -ne 0 ]; then
            echo "✗ Failed to restart container"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Wait for Redis to start
        sleep 3
        
        # Verify data
        KEY_COUNT=$(docker exec "$NAME" redis-cli DBSIZE 2>/dev/null | grep -o '[0-9]*')
        
        if [ -n "$KEY_COUNT" ]; then
            echo ""
            echo "✓ Successfully restored Redis database: $NAME"
            echo "  Keys in database: $KEY_COUNT"
        else
            echo ""
            echo "✗ Failed to verify restored data"
        fi
        ;;
        
    *)
        echo "Error: Invalid type '$TYPE'"
        echo "Valid types: volume, pg, redis"
        rm -rf "$TEMP_DIR"
        exit 1
        ;;
esac

# Clean up
rm -rf "$TEMP_DIR"

echo ""
echo "========================================="
echo "Restore completed!"
echo "========================================="
