FROM alpine:3.19

# Install required packages
RUN apk add --no-cache \
    bash \
    docker-cli \
    aws-cli \
    xz \
    p7zip \
    tzdata

# Set timezone (can be overridden with TZ env var)
ENV TZ=UTC

# Create app directory
WORKDIR /app

# Copy backup scripts
COPY scripts/backup-volumes.sh /app/
COPY scripts/backup-pg.sh /app/
COPY scripts/backup-redis.sh /app/
COPY scripts/backup-cleanup.sh /app/
COPY restore.sh /app/
COPY scripts/run-backups.sh /app/

# Make scripts executable
RUN chmod +x /app/*.sh

# Create log directory
RUN mkdir -p /var/log/backups

# Copy and install cron configuration
COPY backup-container/crontab /etc/crontabs/root
RUN chmod 0644 /etc/crontabs/root

# Copy entrypoint script
COPY backup-container/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=60s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep -f run-backups.sh || exit 1

ENTRYPOINT ["/entrypoint.sh"]
