# Lockbox - Docker Backup System

Automated backup solution for Docker volumes, PostgreSQL, and Redis with AES-256 encryption and S3-compatible storage.

[![Build and Push Docker Image](https://github.com/olushako/lockbox/actions/workflows/docker-build.yml/badge.svg)](https://github.com/olushako/lockbox/actions/workflows/docker-build.yml)

## Quick Start

### Option 1: Use Pre-built Image

```bash
# Pull the image
docker pull ghcr.io/olushako/lockbox:latest

# Or use in docker-compose.yml
services:
  lockbox-backup:
    image: ghcr.io/olushako/lockbox:latest
    # ... rest of configuration
```

### Option 2: Build from Source

### 1. Configure Environment

```bash
cp .env.example .env
# Edit .env with your credentials
```

Required variables:
```bash
BACKUP_PASSWORD=your-secure-password
S3_ENDPOINT=https://your-endpoint.r2.cloudflarestorage.com
S3_ACCESS_KEY=your-access-key
S3_SECRET_KEY=your-secret-key
```

### 2. Label Your Containers

```bash
# Volume backups
docker run -d --label backup.strategy=volume ...

# PostgreSQL backups
docker run -d --label backup.strategy=pg ...

# Redis backups
docker run -d --label backup.strategy=redis ...
```

### 3. Deploy

```bash
# Using pre-built image
docker-compose -f docker-compose.prebuilt.yml up -d

# Or build from source
docker-compose up -d
```

Backups run daily at 2:00 AM (volumes), 2:15 AM (PostgreSQL), 2:30 AM (Redis), 2:45 AM (cleanup).

## Restore Commands

```bash
# Restore specific volume
./restore.sh volume vol1 vol1_20260115_120000.tar.xz.7z

# Restore all volumes
./restore.sh all-volumes

# Restore PostgreSQL database
./restore.sh pg postgres-db postgres-db_20260115_120000.sql.7z

# Restore all PostgreSQL databases
./restore.sh all-pg

# Restore Redis instance
./restore.sh redis redis-db redis-db_20260115_120000.rdb.7z

# Restore all Redis instances
./restore.sh all-redis
```

## Manual Backups

```bash
docker exec lockbox-backup /app/backup-volumes.sh
docker exec lockbox-backup /app/backup-pg.sh
docker exec lockbox-backup /app/backup-redis.sh
```

## Configuration

### Optional Environment Variables

```bash
# S3 Configuration
S3_REGION=auto                    # Default: auto
S3_STORAGE_CLASS=STANDARD         # Default: STANDARD
S3_BUCKET_NAME=lockbox            # Default: lockbox

# Backup Settings
BACKUP_RETENTION_DAYS=30          # Default: 30
TZ=UTC                            # Default: UTC

# Backup Exclusions (space-separated patterns)
# Excludes common development folders from volume backups
# Default: node_modules .venv venv __pycache__ .git .cache .npm
BACKUP_EXCLUDE_PATTERNS=node_modules .venv venv __pycache__ .git .cache .npm

# Examples:
# Exclude only node_modules and .git:
# BACKUP_EXCLUDE_PATTERNS=node_modules .git
#
# No exclusions (backup everything):
# BACKUP_EXCLUDE_PATTERNS=""

# Cron Schedules (minute hour day month weekday)
CRON_VOLUMES=0 2 * * *            # Default: Daily at 2:00 AM
CRON_PG=15 2 * * *                # Default: Daily at 2:15 AM
CRON_REDIS=30 2 * * *             # Default: Daily at 2:30 AM
CRON_CLEANUP=45 2 * * *           # Default: Daily at 2:45 AM
```

### Custom Schedule Example

```bash
# Backup every 6 hours
CRON_VOLUMES="0 */6 * * *" docker-compose up -d
```

## S3 Backup Structure

```
s3://lockbox/
├── volumes/
│   ├── vol1/vol1_20260115_120000.tar.xz.7z
│   └── vol2/vol2_20260115_120000.tar.xz.7z
├── pg/
│   └── postgres-db/postgres-db_20260115_120000.sql.7z
└── redis/
    └── redis-db/redis-db_20260115_120000.rdb.7z
```

## Monitoring

```bash
# Check status
docker ps | grep lockbox-backup
docker logs lockbox-backup

# View logs (inside container)
docker exec lockbox-backup cat /var/log/backups/volumes.log
docker exec lockbox-backup cat /var/log/backups/pg.log
docker exec lockbox-backup cat /var/log/backups/redis.log
docker exec lockbox-backup cat /var/log/backups/cleanup.log
```

## Advanced Configuration

### Backup Exclusions

By default, volume backups exclude common development folders to reduce backup size:
- `node_modules` - Node.js dependencies
- `.venv`, `venv` - Python virtual environments
- `__pycache__` - Python cache files
- `.git` - Git repository data
- `.cache` - Cache directories
- `.npm` - NPM cache

**Customize exclusions:**
```bash
# Exclude only specific folders
BACKUP_EXCLUDE_PATTERNS="node_modules .git" docker-compose up -d

# Backup everything (no exclusions)
BACKUP_EXCLUDE_PATTERNS="" docker-compose up -d

# Add custom exclusions
BACKUP_EXCLUDE_PATTERNS="node_modules .venv build dist" docker-compose up -d
```

## Features

- **Automated Backups**: Scheduled via cron (customizable)
- **Maximum Compression**: XZ compression for smallest size
- **AES-256 Encryption**: Password-protected 7z archives
- **Smart Exclusions**: Skip node_modules, .venv, .git, etc. (customizable)
- **S3-Compatible**: Works with Cloudflare R2, AWS S3, MinIO, etc.
- **Automatic Cleanup**: Configurable retention period
- **Easy Restore**: Single script for all operations
- **Validation**: Environment and cron schedule validation
- **Connection Test**: S3 credentials validated on startup
- **Multi-arch**: Pre-built images for amd64 and arm64

## Project Structure

```
lockbox/
├── .env.example              # Configuration template
├── .env                      # Your configuration
├── README.md                 # This file
├── docker-compose.yml        # Deployment file
├── restore.sh                # Restore script
├── backup-container/         # Container configuration
└── scripts/                  # Backup scripts
```

## Troubleshooting

**Container keeps restarting:**
- Check logs: `docker logs lockbox-backup`
- Verify required environment variables are set

**Backups not running:**
- Verify cron: `docker exec lockbox-backup cat /etc/crontabs/root`
- Check logs: `docker exec lockbox-backup cat /var/log/backups/volumes.log`

**S3 upload failures:**
- Verify S3 credentials and endpoint
- Check network connectivity
- Ensure bucket exists

**Restore failures:**
- Verify BACKUP_PASSWORD matches
- Ensure backup file exists in S3
- Check container permissions

## Security

- Keep `BACKUP_PASSWORD` secure
- Never commit `.env` to version control
- Use strong S3 credentials with minimal permissions
- Regularly test restore procedures

## License

MIT
