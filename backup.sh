#!/bin/bash
# QFieldCloud Backup Script - Production Version
# Stops immediately on errors
set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
BACKUP_HOST_DIR="/mnt/qfieldcloud_backups"
MAX_BACKUPS_TO_KEEP=7
REQUIRED_SPACE_GB=10
MINIO_INTERNAL_PORT="9000"
QFIELD_DIR="../QFieldCloud"

# =============================================================================
# PARAMETER VALIDATION
# =============================================================================
if [ -z "$1" ] || ( [ "$1" != "full" ] && [ "$1" != "incremental" ] ); then
    echo "ERROR: Please specify the backup type: full or incremental."
    echo ""
    echo "Usage: ./backup.sh [full|incremental] [--hot|--cold]"
    echo ""
    echo "Backup types:"
    echo "  full        - Complete volume-based backup"
    echo "  incremental - Fast backup with mc mirror"
    echo ""
    echo "Backup modes (optional):"
    echo "  --cold      - Stops all services before backup (DEFAULT, maximum safety)"
    echo "  --hot       - Services continue running (faster, but less consistent)"
    echo ""
    echo "Examples:"
    echo "  ./backup.sh full         # Cold backup (services stopped)"
    echo "  ./backup.sh full --hot   # Hot backup (services running)"
    echo "  ./backup.sh incremental  # Always hot (mc mirror)"
    exit 1
fi

BACKUP_TYPE="$1"
BACKUP_MODE="${2:-cold}"  # Default: cold backup

# Validate backup mode
if [ "$BACKUP_MODE" != "--cold" ] && [ "$BACKUP_MODE" != "--hot" ] && [ "$BACKUP_MODE" != "cold" ] && [ "$BACKUP_MODE" != "hot" ]; then
    echo "ERROR: Invalid backup mode: $BACKUP_MODE"
    echo "Use --cold or --hot"
    exit 1
fi

# Remove -- if present
BACKUP_MODE="${BACKUP_MODE#--}"

# Incremental is always hot
if [ "$BACKUP_TYPE" = "incremental" ]; then
    BACKUP_MODE="hot"
fi

# Readable timestamp: 2025-10-14_12-00-00
DATE_SUFFIX=$(date +%Y-%m-%d_%H-%M-%S)

# Backup folder with clear structure: DATE_TIME_TYPE_MODE
BACKUP_DIR="${BACKUP_HOST_DIR}/${DATE_SUFFIX}_${BACKUP_TYPE}_${BACKUP_MODE}"

# =============================================================================
# CHECK QFIELDCLOUD DIRECTORY
# =============================================================================
if [ ! -d "$QFIELD_DIR" ]; then
    echo "ERROR: QFieldCloud directory not found at $QFIELD_DIR"
    echo "Please ensure QFieldCloud is installed in the sibling directory."
    exit 1
fi

# Change to QFieldCloud directory for all operations
cd "$QFIELD_DIR"

# =============================================================================
# LOAD ENVIRONMENT VARIABLES
# =============================================================================
if [ -f .env ]; then
    source .env
else
    echo "ERROR: The .env file was not found."
    exit 1
fi

# CRITICAL: Export COMPOSE_FILE so docker compose loads the correct files
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.override.standalone.yml}"

COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}

# =============================================================================
# INITIALIZE LOGGING
# =============================================================================
mkdir -p "${BACKUP_DIR}/config"
LOG_FILE="${BACKUP_DIR}/backup.log"
touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== QFieldCloud ${BACKUP_TYPE^} Backup (${BACKUP_MODE^^} MODE) started ==="
log "Backup directory: ${BACKUP_DIR}"

if [ "$BACKUP_MODE" = "hot" ]; then
    log "⚠️  HOT BACKUP MODE: Services continue running (faster, but potentially inconsistent)"
else
    log "🔒 COLD BACKUP MODE: Services will be stopped (maximum safety)"
fi

START_TIME=$(date +%s)

# =============================================================================
# DISK SPACE CHECK
# =============================================================================
log "Checking available disk space..."
AVAILABLE_SPACE_GB=$(df -BG "${BACKUP_HOST_DIR}" | awk 'NR==2 {print $4}' | sed 's/G//' 2>/dev/null)

if [ -z "$AVAILABLE_SPACE_GB" ]; then
    log "WARNING: Disk space check failed"
elif [ "$AVAILABLE_SPACE_GB" -lt "$REQUIRED_SPACE_GB" ]; then
    log "ERROR: Not enough disk space (${AVAILABLE_SPACE_GB}GB available, ${REQUIRED_SPACE_GB}GB required)"
    exit 1
else
    log "Disk space OK (${AVAILABLE_SPACE_GB}GB available)"
fi

# =============================================================================
# SERVICE MANAGEMENT BASED ON BACKUP MODE
# =============================================================================
if [ "$BACKUP_MODE" = "cold" ]; then
    log "=== COLD BACKUP: Stopping all services ==="
    docker compose down
    log "All services stopped"
    sleep 3
else
    log "=== HOT BACKUP: Services continue running ==="
    log "Ensuring services are running..."
    docker compose up -d --remove-orphans db geodb minio
    
    log "Waiting for database services..."
    until docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; do 
        log "  -> Waiting for main database..."
        sleep 2
    done
    until docker compose exec -T geodb pg_isready -U "${GEODB_USER}" > /dev/null 2>&1; do 
        log "  -> Waiting for geo database..."
        sleep 2
    done
    
    log "Waiting for MinIO..."
    until docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; do
        log "  -> Waiting for MinIO..."
        sleep 2
    done
    log "All services are ready"
fi

# =============================================================================
# DATABASE BACKUP
# =============================================================================
if [ "$BACKUP_MODE" = "cold" ]; then
    log "=== COLD DB BACKUP: Copying DB volumes directly ==="
    
    # PostgreSQL volume backup
    DB_VOLUME="${COMPOSE_PROJECT_NAME}_postgres_data"
    GEODB_VOLUME="${COMPOSE_PROJECT_NAME}_geodb_data"
    
    mkdir -p "${BACKUP_DIR}/db_volumes"
    
    log "Backing up PostgreSQL volume..."
    if docker volume inspect "$DB_VOLUME" > /dev/null 2>&1; then
        if ! docker run --rm \
            -v "${DB_VOLUME}:/source_data:ro" \
            -v "${BACKUP_DIR}/db_volumes:/backup_target" \
            alpine:latest \
            sh -c 'mkdir -p /backup_target/postgres_data && cp -a /source_data/. /backup_target/postgres_data/' >> "$LOG_FILE" 2>&1; then
            log "ERROR: PostgreSQL volume backup failed"
            docker compose up -d  # Restart services on error
            exit 1
        fi
        log "PostgreSQL volume backed up ($(du -sh "${BACKUP_DIR}/db_volumes/postgres_data" | cut -f1))"
    else
        log "WARNING: PostgreSQL volume $DB_VOLUME not found"
    fi
    
    log "Backing up GeoDB volume..."
    if docker volume inspect "$GEODB_VOLUME" > /dev/null 2>&1; then
        if ! docker run --rm \
            -v "${GEODB_VOLUME}:/source_data:ro" \
            -v "${BACKUP_DIR}/db_volumes:/backup_target" \
            alpine:latest \
            sh -c 'mkdir -p /backup_target/geodb_data && cp -a /source_data/. /backup_target/geodb_data/' >> "$LOG_FILE" 2>&1; then
            log "ERROR: GeoDB volume backup failed"
            docker compose up -d  # Restart services on error
            exit 1
        fi
        log "GeoDB volume backed up ($(du -sh "${BACKUP_DIR}/db_volumes/geodb_data" | cut -f1))"
    else
        log "WARNING: GeoDB volume $GEODB_VOLUME not found"
    fi
    
else
    log "=== HOT DB BACKUP: Using pg_dump ==="
    
    log "Backing up main database..."
    if ! docker compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc -Z9 > "${BACKUP_DIR}/db_dump.sqlc" 2>> "$LOG_FILE"; then
        log "ERROR: Main database backup failed"
        exit 1
    fi
    log "Main database backed up ($(du -h "${BACKUP_DIR}/db_dump.sqlc" | cut -f1))"

    log "Backing up geo database..."
    if ! docker compose exec -T geodb pg_dump -U "${GEODB_USER}" -d "${GEODB_DB}" -Fc -Z9 > "${BACKUP_DIR}/geodb_dump.sqlc" 2>> "$LOG_FILE"; then
        log "ERROR: Geo database backup failed"
        exit 1
    fi
    log "Geo database backed up ($(du -h "${BACKUP_DIR}/geodb_dump.sqlc" | cut -f1))"
fi

# =============================================================================
# MINIO BACKUP
# =============================================================================
if [ "$BACKUP_TYPE" = "full" ]; then
    # FULL BACKUP: Volume backup
    log "=== FULL BACKUP: Backing up MinIO volumes ==="
    
    if [ "$BACKUP_MODE" = "hot" ]; then
        log "⚠️  WARNING: Hot volume backup may lead to inconsistent data!"
        log "⚠️  For production backups, --cold is recommended."
    fi
    
    MINIO_BACKUP_PATH="${BACKUP_DIR}/minio_volumes"
    mkdir -p "$MINIO_BACKUP_PATH"
    
    for i in 1 2 3 4; do
        VOLUME_NAME="${COMPOSE_PROJECT_NAME}_minio_data${i}"
        TARGET_DIR="${MINIO_BACKUP_PATH}/data${i}"
        mkdir -p "$TARGET_DIR"
        
        log "  -> Backing up volume ${VOLUME_NAME}..."
        
        # Check if volume exists
        if ! docker volume inspect "$VOLUME_NAME" > /dev/null 2>&1; then
            log "WARNING: Volume ${VOLUME_NAME} does not exist"
            continue
        fi
        
        # Copy volume data
        if ! docker run --rm \
            -v "${VOLUME_NAME}:/source_data:ro" \
            -v "${TARGET_DIR}:/backup_target" \
            alpine:latest \
            sh -c 'cp -a /source_data/. /backup_target/' >> "$LOG_FILE" 2>&1; then
            log "ERROR: Volume ${VOLUME_NAME} backup failed"
            [ "$BACKUP_MODE" = "cold" ] && docker compose up -d
            exit 1
        fi
        
        VOLUME_SIZE=$(du -sh "$TARGET_DIR" | cut -f1)
        log "  -> Volume ${i} backed up (${VOLUME_SIZE})"
    done
    
    log "MinIO volumes backed up"
    
else
    # INCREMENTAL BACKUP: mc mirror (always hot)
    log "=== INCREMENTAL BACKUP: Using mc mirror ==="
    MINIO_HOST="minio:${MINIO_INTERNAL_PORT}"
    MINIO_ALIAS="qfieldcloudminio"
    
    if ! docker run --rm \
        --network "${COMPOSE_PROJECT_NAME}_default" \
        -v "${BACKUP_DIR}:/backup" \
        minio/mc \
        /bin/sh -c "
            mc alias set ${MINIO_ALIAS} http://${MINIO_HOST} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
            mc mirror --overwrite --preserve ${MINIO_ALIAS}/qfieldcloud-project-files /backup/minio_project_files && \
            mc mirror --overwrite --preserve ${MINIO_ALIAS}/qfieldcloud-storage /backup/minio_storage && \
            mc ls -r ${MINIO_ALIAS} > /backup/minio_bucket_list.txt
        " >> "$LOG_FILE" 2>&1; then
        log "ERROR: MinIO backup failed"
        exit 1
    fi
    log "MinIO data incrementally backed up"
fi

# =============================================================================
# BACKUP CONFIGURATIONS
# =============================================================================
log "Backing up configuration files..."

# Git information in log
log "=== Git Information ==="
if command -v git > /dev/null 2>&1 && [ -d .git ]; then
    log "Git repository found - saving version information..."
    
    echo "" >> "$LOG_FILE"
    echo "=== GIT COMMIT INFORMATION ===" >> "$LOG_FILE"
    git log -1 >> "$LOG_FILE" 2>&1 || echo "Could not execute git log" >> "$LOG_FILE"
    
    echo "" >> "$LOG_FILE"
    echo "=== GIT REMOTE INFORMATION ===" >> "$LOG_FILE"
    git remote -v >> "$LOG_FILE" 2>&1 || echo "Could not execute git remote" >> "$LOG_FILE"
    
    echo "" >> "$LOG_FILE"
    log "Git information saved in log"
else
    log "No Git repository found - skipping Git information"
fi

# Certbot configuration
if [ -d "./conf/certbot/conf" ]; then
    cp -R "./conf/certbot/conf" "${BACKUP_DIR}/config/certbot"
    log "  -> Certbot configuration backed up"
fi

# Nginx certificates
if [ -d "./conf/nginx/certs" ]; then
    cp -R "./conf/nginx/certs" "${BACKUP_DIR}/config/nginx_certs"
    log "  -> Nginx certificates backed up"
fi

# .env file
if [ -f .env ]; then
    cp .env "${BACKUP_DIR}/config/.env"
    log "  -> .env file backed up"
fi

# All Docker Compose YAML files
log "Backing up Docker Compose configurations..."
COMPOSE_FILES_FOUND=0
for yml_file in *.yml *.yaml; do
    if [ -f "$yml_file" ]; then
        cp "$yml_file" "${BACKUP_DIR}/config/"
        log "  -> $yml_file backed up"
        COMPOSE_FILES_FOUND=$((COMPOSE_FILES_FOUND + 1))
    fi
done

if [ $COMPOSE_FILES_FOUND -eq 0 ]; then
    log "WARNING: No Docker Compose YAML files found"
else
    log "  -> $COMPOSE_FILES_FOUND Docker Compose file(s) backed up"
fi

log "Configurations backed up"

# =============================================================================
# CREATE CHECKSUMS
# =============================================================================
log "Creating SHA256 checksums..."
(
    cd "${BACKUP_DIR}"
    find . -type f ! -name "checksums.sha256" -exec sha256sum {} \; > checksums.sha256
) || {
    log "ERROR: Checksum creation failed"
    exit 1
}
log "Checksums created"

# =============================================================================
# BACKUP ROTATION
# =============================================================================
if [ "$MAX_BACKUPS_TO_KEEP" -gt 0 ]; then
    log "Performing backup rotation (max. ${MAX_BACKUPS_TO_KEEP} backups)..."
    
    # Count existing backups (excluding current)
    BACKUP_COUNT=$(find "${BACKUP_HOST_DIR}" -maxdepth 1 -type d -name "*_*" ! -path "$BACKUP_DIR" | wc -l)
    
    if [ "$BACKUP_COUNT" -ge "$MAX_BACKUPS_TO_KEEP" ]; then
        find "${BACKUP_HOST_DIR}" -maxdepth 1 -type d -name "*_*" ! -path "$BACKUP_DIR" | \
            sort | head -n -$((MAX_BACKUPS_TO_KEEP - 1)) | while read OLD_BACKUP; do
                log "  -> Deleting old backup: $(basename "$OLD_BACKUP")"
                rm -rf "$OLD_BACKUP"
            done
        log "Rotation completed"
    else
        log "No rotation needed (only ${BACKUP_COUNT} backups present)"
    fi
fi

# =============================================================================
# RESTORE SERVICES (FOR COLD BACKUP)
# =============================================================================
if [ "$BACKUP_MODE" = "cold" ]; then
    log "Restarting all services..."
    docker compose up -d
    
    # Wait for critical services
    log "Waiting for service restart..."
    sleep 5
    
    TIMEOUT=60
    ELAPSED=0
    
    # Check if services are running again
    until docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            log "WARNING: Database restart taking longer than expected"
            break
        fi
        log "  -> Waiting for database..."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    
    ELAPSED=0
    until docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            log "WARNING: MinIO restart taking longer than expected"
            break
        fi
        log "  -> Waiting for MinIO..."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    
    log "Services successfully restarted"
fi

# =============================================================================
# COMPLETION
# =============================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
BACKUP_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)

log "=== Backup SUCCESSFULLY completed ==="
log "Type: ${BACKUP_TYPE^} (${BACKUP_MODE^^} MODE)"
log "Duration: ${DURATION} seconds"
log "Size: ${BACKUP_SIZE}"
log "Path: ${BACKUP_DIR}"

if [ "$BACKUP_MODE" = "hot" ] && [ "$BACKUP_TYPE" = "full" ]; then
    log ""
    log "⚠️  NOTE: Hot full backup performed."
    log "⚠️  For maximum consistency use: ./backup.sh full --cold"
fi

exit 0
