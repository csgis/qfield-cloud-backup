#!/bin/bash
# QFieldCloud Restore Script - Disaster Recovery Edition
# Version: 3.1 - English & Sibling Directory Support
# Stops immediately on errors
set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
# Enable GeoDB restoration? (true/false)
# Default: false (GeoDB was removed in newer versions)
RESTORE_GEODB=${RESTORE_GEODB:-false}

# QFieldCloud installation directory (sibling directory)
QFIELD_DIR="../QFieldCloud"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
print_header() {
    echo ""
    echo "=============================================================================="
    echo "$1"
    echo "=============================================================================="
    echo ""
}

print_step() {
    echo ""
    echo ">>> $1"
    echo ""
}

print_error() {
    echo "❌ ERROR: $1" >&2
    echo "Restore aborted." >&2
    # Remove temporary backup directory on error
    if [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
        log "Cleaning up temporary backup directory on error..."
        rm -rf "$TEMP_BACKUP_DIR" 2>/dev/null || true
    fi
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTORE_LOG"
}

check_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        print_error "$1 is not installed! Please install: $2"
    fi
}

# =============================================================================
# INTRO & SYSTEM CHECKS
# =============================================================================
print_header "QFieldCloud Disaster Recovery & Restore Script"

RESTORE_LOG="restore_$(date +%Y-%m-%d_%H-%M-%S).log"
log "=== QFieldCloud restoration started ==="

echo "This script performs restoration from a backup."
echo "It is designed for a *new server* after previous code checkout and initialization."
echo ""
echo "Configuration:"
echo "  GeoDB restoration: $RESTORE_GEODB"
echo "  QFieldCloud directory: $QFIELD_DIR"
echo "  Restore log: $RESTORE_LOG"
echo ""

# Check root permissions for critical operations
if [ "$EUID" -ne 0 ]; then
    print_error "This script MUST be run with 'sudo' as it manipulates Docker volumes. Please restart with: sudo $0"
fi
echo "✓ Root privileges detected (required for volume operations)"

# Check Docker
print_step "STEP 1: Checking system prerequisites"
check_command "docker" "sudo apt install docker.io"
echo "✓ Docker found: $(docker --version | head -n1)"

if ! docker compose version > /dev/null 2>&1; then
    print_error "Docker Compose plugin not available! Install with: sudo apt install docker-compose-plugin"
fi
echo "✓ Docker Compose found: $(docker compose version | head -n1)"

# Optional tools
GIT_AVAILABLE=false
RSYNC_AVAILABLE=false

if command -v git > /dev/null 2>&1; then
    GIT_AVAILABLE=true
    echo "✓ Git found: $(git --version | head -n1)"
fi

if command -v rsync > /dev/null 2>&1; then
    RSYNC_AVAILABLE=true
    echo "✓ rsync found: $(rsync --version | head -n1)"
fi

# =============================================================================
# DETERMINE BACKUP SOURCE
# =============================================================================
print_step "STEP 2: Determining backup source"

echo "Where is your backup located?"
echo "  1) Locally on this server (specify path)"
echo "  2) On a remote server (download via rsync)"
echo ""
read -r -p "Your choice (1/2): " BACKUP_SOURCE_TYPE

BACKUP_DIR=""
TEMP_BACKUP_DIR="/tmp/qfieldcloud_restore_$(date +%s)"

if [ "$BACKUP_SOURCE_TYPE" = "2" ]; then
    # Remote backup
    if [ "$RSYNC_AVAILABLE" = false ]; then
        print_error "rsync is required for remote backup transfer! Install with: sudo apt install rsync"
    fi
    
    echo ""
    echo "=== Remote Backup Transfer ==="
    echo ""
    read -r -p "Remote server (user@host): " REMOTE_HOST
    read -r -p "Remote backup path: " REMOTE_BACKUP_PATH
    
    echo ""
    echo "Transferring backup to $TEMP_BACKUP_DIR ..."
    mkdir -p "$TEMP_BACKUP_DIR" || print_error "Could not create temporary directory"
    
    # Use rsync with exclusions for certificates that can't be read due to permissions
    if ! rsync -avz --progress \
        --exclude="*/certbot/conf/archive/*" \
        --exclude="*/certbot/conf/live/*" \
        --exclude="*/certbot/conf/accounts/*" \
        --exclude="*/nginx_certs/*" \
        "${REMOTE_HOST}:${REMOTE_BACKUP_PATH}/" "$TEMP_BACKUP_DIR/"; then
        print_error "rsync failed! Check path and SSH access."
    fi
    
    BACKUP_DIR="$TEMP_BACKUP_DIR"
    echo "✓ Backup successfully transferred (certificates excluded)"
    
else
    # Local backup
    echo ""
    read -r -p "Local backup path: " LOCAL_BACKUP_PATH
    
    if [ ! -d "$LOCAL_BACKUP_PATH" ]; then
        print_error "Backup directory does not exist: $LOCAL_BACKUP_PATH"
    fi
    
    BACKUP_DIR=$(realpath "$LOCAL_BACKUP_PATH")
    echo "✓ Local backup found"
fi

log "Backup source: $BACKUP_DIR"

# =============================================================================
# BACKUP INFORMATION & CODE CHECK
# =============================================================================
print_step "STEP 3: Reading backup information"

echo "Backup source: $BACKUP_DIR"
echo "Backup name: $(basename "$BACKUP_DIR")"
echo ""

GEODB_IN_BACKUP=false
if [ -f "${BACKUP_DIR}/geodb_dump.sqlc" ] || [ -d "${BACKUP_DIR}/db_volumes/geodb_data" ]; then
    GEODB_IN_BACKUP=true
    log "ℹ GeoDB data found in backup"
    if [ "$RESTORE_GEODB" = false ]; then
        echo "ℹ GeoDB will NOT be restored (RESTORE_GEODB=false)"
    else
        echo "ℹ GeoDB WILL be restored (RESTORE_GEODB=true)"
    fi
fi

# Extract Git commit info
BACKUP_COMMIT=""
BACKUP_REMOTE=""
if [ -f "${BACKUP_DIR}/backup.log" ]; then
    log "Reading Git information from backup.log..."
    BACKUP_COMMIT=$(sed -n '/GIT COMMIT INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep "^commit" | awk '{print $2}' | head -n1)
    BACKUP_REMOTE=$(sed -n '/GIT REMOTE INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep "origin" | awk '{print $2}' | head -n1)
fi

if [ -n "$BACKUP_COMMIT" ]; then
    echo "Backup was created with Git commit: $BACKUP_COMMIT"
else
    echo "WARNING: No Git commit found in backup log - compatibility uncertain!"
fi

# =============================================================================
# CODE CHECK & PREPARATION (FOR NEW SERVERS)
# =============================================================================
print_step "STEP 4: Checking QFieldCloud code & configuration"

# Check if QFieldCloud directory exists
if [ ! -d "$QFIELD_DIR" ]; then
    echo "🚨 PREPARATION REQUIRED 🚨"
    echo "The QFieldCloud directory does not exist at: $QFIELD_DIR"
    echo ""
    echo "Please MANUALLY PERFORM THE FOLLOWING STEPS FIRST:"
    echo "1. **Clone code:**"
    if [ -n "$BACKUP_REMOTE" ]; then
        echo "   -> git clone $BACKUP_REMOTE $(basename "$QFIELD_DIR")"
    else
        echo "   -> git clone [REPO URL] $(basename "$QFIELD_DIR")"
    fi
    echo "   -> cd $(basename "$QFIELD_DIR")"
    echo "2. **Restore configuration:**"
    echo "   -> cp ${BACKUP_DIR}/config/.env ."
    echo "   -> cp ${BACKUP_DIR}/config/*.yml ."
    echo "3. **Adjust code version (IMPORTANT):**"
    if [ -n "$BACKUP_COMMIT" ]; then
        echo "   -> git fetch --all && git reset --hard $BACKUP_COMMIT"
    else
        echo "   -> WARNING: No backup commit found, please checkout the correct version manually."
    fi
    echo "4. **Initialize databases:**"
    echo "   -> docker compose up -d db minio # Just to create volumes/DB files"
    echo "   -> docker compose down"
    echo ""
    read -r -p "Have you performed the above steps? (yes/no): " CODE_MANUAL_READY
    
    if [ "$CODE_MANUAL_READY" != "yes" ]; then
        print_error "Aborted. Please prepare code and restart."
    fi
fi

# Change to QFieldCloud directory
cd "$QFIELD_DIR" || print_error "Cannot change to QFieldCloud directory: $QFIELD_DIR"

# Check for required files
if [ ! -d ".git" ] || [ ! -f "docker-compose.yml" ] || [ ! -f ".env" ]; then
    echo "🚨 INCOMPLETE INSTALLATION 🚨"
    echo "The QFieldCloud directory seems to be incomplete."
    echo ""
    echo "Missing files:"
    [ ! -d ".git" ] && echo "  - .git directory (no Git repository)"
    [ ! -f "docker-compose.yml" ] && echo "  - docker-compose.yml"
    [ ! -f ".env" ] && echo "  - .env"
    echo ""
    echo "Please ensure all files are present, especially:"
    echo "  -> cp ${BACKUP_DIR}/config/.env ."
    echo "  -> cp ${BACKUP_DIR}/config/*.yml ."
    echo ""
    read -r -p "Have you fixed the missing files? (yes/no): " FILES_FIXED
    
    if [ "$FILES_FIXED" != "yes" ] || [ ! -f ".env" ]; then
        print_error "Required files still missing. Please fix and restart."
    fi
fi

echo "✓ QFieldCloud code directory (.git, .env, docker-compose.yml) found."

# =============================================================================
# LOAD CONFIGURATION FILES
# =============================================================================
print_step "STEP 5: Loading configuration"

# Load .env
source .env
# Set defaults if not set in .env
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.override.standalone.yml}"
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}
MINIO_INTERNAL_PORT="${MINIO_API_PORT:-9000}"

echo "✓ .env loaded"
echo "  COMPOSE_PROJECT_NAME: $COMPOSE_PROJECT_NAME"
echo "  COMPOSE_FILE: $COMPOSE_FILE"

# Check if GeoDB service exists (use temporary variables for config output)
GEODB_SERVICE_EXISTS=false
if COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" COMPOSE_FILE="$COMPOSE_FILE" docker compose config --services 2>/dev/null | grep -q "^geodb$"; then
    GEODB_SERVICE_EXISTS=true
    echo "✓ GeoDB service found in docker-compose"
else
    echo "ℹ GeoDB service not found in docker-compose"
fi

# Final GeoDB decision
PROCESS_GEODB=false
if [ "$RESTORE_GEODB" = true ] && [ "$GEODB_SERVICE_EXISTS" = true ] && [ "$GEODB_IN_BACKUP" = true ]; then
    PROCESS_GEODB=true
    log "✓ GeoDB will be restored"
elif [ "$RESTORE_GEODB" = true ]; then
    log "⚠ GeoDB will be skipped although requested:"
    [ "$GEODB_SERVICE_EXISTS" = false ] && log "  - Service not defined"
    [ "$GEODB_IN_BACKUP" = false ] && log "  - No data in backup"
else
    log "ℹ GeoDB will be skipped (RESTORE_GEODB=false)"
fi

# =============================================================================
# FINAL CONFIRMATION
# =============================================================================
print_header "READY FOR RESTORE"

echo "Summary:"
echo "  • Backup: $(basename "$BACKUP_DIR")"
echo "  • Working directory: $(pwd)"
echo "  • Docker project: $COMPOSE_PROJECT_NAME"
echo "  • Restore GeoDB: $PROCESS_GEODB"
[ -n "$BACKUP_COMMIT" ] && echo "  • Git commit: $BACKUP_COMMIT"
echo ""
echo "⚠️  WARNING: The restore will OVERWRITE all **Docker volumes** and **databases** of this project."
echo ""

read -r -p "To continue, type 'RESTORE NOW': " FINAL_CONFIRMATION

if [ "$FINAL_CONFIRMATION" != "RESTORE NOW" ]; then
    print_error "Restore cancelled by user."
fi

log "CONFIRMED. Performing restore..."

# =============================================================================
# BACKUP VALIDATION
# =============================================================================
print_step "STEP 6: Validating backup"

DB_BACKUP_TYPE="unknown"
MINIO_BACKUP_TYPE="unknown"

# Database backup type
if [ -d "${BACKUP_DIR}/db_volumes/postgres_data" ]; then
    DB_BACKUP_TYPE="volume"
    log "Database backup type: Volume-based (cold backup)"
elif [ -f "${BACKUP_DIR}/db_dump.sqlc" ]; then
    DB_BACKUP_TYPE="dump"
    log "Database backup type: pg_dump-based (hot backup)"
else
    print_error "No valid main database backups found (neither volume nor dump)."
fi

# MinIO backup type
if [ -d "${BACKUP_DIR}/minio_volumes/data1" ]; then
    MINIO_BACKUP_TYPE="volume"
    log "MinIO backup type: Volume-based (full)"
elif [ -d "${BACKUP_DIR}/minio_project_files" ] || [ -d "${BACKUP_DIR}/minio_storage" ]; then
    MINIO_BACKUP_TYPE="mirror"
    log "MinIO backup type: Mirror-based (incremental)"
else
    print_error "No MinIO data found in backup (neither volume nor mirror)."
fi

# Checksum validation
if [ -f "${BACKUP_DIR}/checksums.sha256" ]; then
    log "Validating checksums..."
    # Important: sha256sum must be executed in the backup directory
    if (cd "${BACKUP_DIR}" && sha256sum -c checksums.sha256 > /dev/null 2>&1); then
        log "✓ Checksums successfully validated"
    else
        echo ""
        log "WARNING: Checksum validation failed! (Details in log)"
        read -r -p "Continue anyway? (yes/no) " RESPONSE
        [[ "$RESPONSE" != "yes" ]] && print_error "Restore aborted due to failed checksum."
    fi
else
    log "WARNING: No checksums found - integrity cannot be verified."
fi

# =============================================================================
# SHUTDOWN SERVICES
# =============================================================================
print_step "STEP 7: Shutting down services"
log "Shutting down all QFieldCloud services..."
# Use -v to remove volumes we want to overwrite (only if not in use)
docker compose down || true 2>&1 | tee -a "$RESTORE_LOG"
sleep 3
log "✓ Services stopped"

# =============================================================================
# MINIO RESTORATION
# =============================================================================
print_step "STEP 8: Restoring MinIO data"
log "=== MinIO Restoration ==="

# Volume names are automatically created by docker compose
# IMPORTANT: The Compose files must define the volumes!
if [ "$MINIO_BACKUP_TYPE" = "volume" ]; then
    # VOLUME-BASED RESTORATION
    log "Restoring MinIO volumes (volume-based)..."
    
    for i in 1 2 3 4; do
        VOLUME_NAME="${COMPOSE_PROJECT_NAME}_minio_data${i}"
        SOURCE_DIR="${BACKUP_DIR}/minio_volumes/data${i}"
        
        if [ ! -d "$SOURCE_DIR" ]; then
            log "WARNING: Skipping data${i} (not in backup: $SOURCE_DIR)"
            continue
        fi
        
        log "  -> Restoring volume ${VOLUME_NAME}..."
        
        # Safe volume restore with alpine container
        if ! docker run --rm \
            -v "${SOURCE_DIR}:/source_data:ro" \
            -v "${VOLUME_NAME}:/target_data" \
            alpine:latest \
            sh -c '
                # Delete old data (all files including hidden)
                rm -rf /target_data/* /target_data/.[!.]* 2>/dev/null || true
                # Copy new data
                cp -a /source_data/. /target_data/
                if [ ! "$(ls -A /target_data)" ]; then
                    echo "ERROR: Target volume is empty after copy"
                    exit 1
                fi
            '; then
            print_error "MinIO volume ${i} restoration failed"
        fi
        log "  -> Volume ${i} restored"
    done
    
else
    # MIRROR-BASED RESTORATION
    log "Restoring MinIO data (mirror-based via mc)..."
    log "Starting MinIO temporarily for restoration..."
    
    # Start MinIO to allow mc access
    if ! docker compose up -d minio 2>&1 | tee -a "$RESTORE_LOG"; then
        print_error "MinIO could not be started for mirror restore"
    fi
    
    # Wait for MinIO
    until docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; do
        log "  -> Waiting for MinIO ($MINIO_INTERNAL_PORT)..."
        sleep 2
    done
    
    MINIO_HOST="minio:${MINIO_INTERNAL_PORT}"
    MINIO_ALIAS="qfieldcloudminio"
    
    # Use mc to mirror the data
    if ! docker run --rm \
        --network "${COMPOSE_PROJECT_NAME}_default" \
        -v "${BACKUP_DIR}:/backup:ro" \
        minio/mc \
        /bin/sh -c "
            mc alias set ${MINIO_ALIAS} http://${MINIO_HOST} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
            mc mirror --overwrite --remove /backup/minio_project_files ${MINIO_ALIAS}/qfieldcloud-project-files && \
            mc mirror --overwrite --remove /backup/minio_storage ${MINIO_ALIAS}/qfieldcloud-storage
        " 2>&1 | tee -a "$RESTORE_LOG" | grep -v "WARNING"; then
        print_error "MinIO mirror restoration failed (mc error)"
    fi
    
    log "Stopping MinIO after mirror restore..."
    docker compose stop minio 2>&1 | tee -a "$RESTORE_LOG"
fi

log "MinIO restoration completed"

# =============================================================================
# DATABASE RESTORATION
# =============================================================================
print_step "STEP 9: Restoring databases"
log "=== Database Restoration ==="

# Function: Database restore with pg_dump/pg_restore (only for dump-based backups)
restore_database() {
    local SERVICE_NAME=$1
    local USER=$2
    local DB_NAME=$3
    local DUMP_FILE=$4
    
    if [ ! -f "$DUMP_FILE" ]; then
        log "WARNING: Dump file missing for $DB_NAME ($DUMP_FILE). Skipping."
        return 0
    fi
    
    log "Restoring database ${DB_NAME} from dump..."
    
    # Drop/Create database fresh
    log "  -> Dropping old database..."
    docker compose exec -T "$SERVICE_NAME" dropdb -U "$USER" "$DB_NAME" --if-exists 2>/dev/null || true
    log "  -> Creating new database..."
    if ! docker compose exec -T "$SERVICE_NAME" createdb -U "$USER" "$DB_NAME"; then
        log "ERROR: Database creation failed: $DB_NAME"
        return 1
    fi
    
    # Restore via STDIN
    log "  -> Importing data..."
    if ! cat "$DUMP_FILE" | docker compose exec -i "$SERVICE_NAME" pg_restore -U "$USER" -d "$DB_NAME" --no-owner --no-acl 2>&1 | tee -a "$RESTORE_LOG" | grep -v "WARNING"; then
         log "WARNING: Some restore warnings occurred (usually harmless, see log)"
    fi
    
    # Validate restore
    TABLE_COUNT=$(docker compose exec -T "$SERVICE_NAME" psql -U "$USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d ' ')
    
    if [ -z "$TABLE_COUNT" ] || [ "$TABLE_COUNT" -lt 5 ]; then # Check minimum table count
        log "ERROR: Database ${DB_NAME} appears empty or incomplete (${TABLE_COUNT} tables)"
        return 1
    fi
    
    log "  -> Database ${DB_NAME} successfully restored (${TABLE_COUNT} tables)"
    return 0
}

# Start required DB services (always, as volume restore/dump restore needs them)
log "Starting/checking database services..."
if [ "$PROCESS_GEODB" = true ]; then
    docker compose up -d db geodb 2>&1 | tee -a "$RESTORE_LOG" || print_error "DB services could not be started."
else
    docker compose up -d db 2>&1 | tee -a "$RESTORE_LOG" || print_error "Main DB service could not be started."
fi

# Wait for databases with timeout
TIMEOUT=120
ELAPSED=0

# Wait function
wait_for_db() {
    local SERVICE_NAME=$1
    local USER=$2
    local DB_TITLE=$3
    
    log "Waiting for ${DB_TITLE} ($SERVICE_NAME)..."
    ELAPSED=0
    while ! docker compose exec -T "$SERVICE_NAME" pg_isready -U "$USER" > /dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            print_error "${DB_TITLE} timeout after ${TIMEOUT}s. Check the logs!"
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    log "✓ ${DB_TITLE} is ready"
}

wait_for_db "db" "$POSTGRES_USER" "Main database"
[ "$PROCESS_GEODB" = true ] && wait_for_db "geodb" "$GEODB_USER" "Geo database"


if [ "$DB_BACKUP_TYPE" = "volume" ]; then
    # VOLUME-BASED RESTORATION (from cold backup)
    log "Restoring DB volumes (volume overwrite)..."
    
    # PostgreSQL volume
    DB_VOLUME="${COMPOSE_PROJECT_NAME}_postgres_data"
    SOURCE_DIR="${BACKUP_DIR}/db_volumes/postgres_data"
    
    if [ -d "$SOURCE_DIR" ]; then
        log "  -> Stopping main DB for volume restore..."
        docker compose stop db 2>&1 | tee -a "$RESTORE_LOG"
        
        log "  -> Restoring PostgreSQL volume..."
        if ! docker run --rm \
            -v "${SOURCE_DIR}:/source_data:ro" \
            -v "${DB_VOLUME}:/target_data" \
            alpine:latest \
            sh -c '
                rm -rf /target_data/* /target_data/.[!.]* 2>/dev/null || true
                cp -a /source_data/. /target_data/
                if [ ! "$(ls -A /target_data)" ]; then echo "ERROR: Target volume is empty"; exit 1; fi
            '; then
            print_error "PostgreSQL volume restoration failed"
        fi
        
        log "  -> Restarting main DB..."
        docker compose start db 2>&1 | tee -a "$RESTORE_LOG"
        wait_for_db "db" "$POSTGRES_USER" "Main database (restart)"
    else
        log "WARNING: PostgreSQL volume not found in backup - skipping."
    fi
    
    # GeoDB volume (only if enabled)
    if [ "$PROCESS_GEODB" = true ]; then
        GEODB_VOLUME="${COMPOSE_PROJECT_NAME}_geodb_data"
        SOURCE_DIR="${BACKUP_DIR}/db_volumes/geodb_data"
        
        if [ -d "$SOURCE_DIR" ]; then
            log "  -> Stopping GeoDB for volume restore..."
            docker compose stop geodb 2>&1 | tee -a "$RESTORE_LOG"
            
            log "  -> Restoring GeoDB volume..."
            if ! docker run --rm \
                -v "${SOURCE_DIR}:/source_data:ro" \
                -v "${GEODB_VOLUME}:/target_data" \
                alpine:latest \
                sh -c '
                    rm -rf /target_data/* /target_data/.[!.]* 2>/dev/null || true
                    cp -a /source_data/. /target_data/
                    if [ ! "$(ls -A /target_data)" ]; then echo "ERROR: Target volume is empty"; exit 1; fi
                '; then
                print_error "GeoDB volume restoration failed"
            fi
            
            log "  -> Restarting GeoDB..."
            docker compose start geodb 2>&1 | tee -a "$RESTORE_LOG"
            wait_for_db "geodb" "$GEODB_USER" "Geo database (restart)"
        else
            log "WARNING: GeoDB volume not found in backup - skipping."
        fi
    fi
    
else
    # DUMP-BASED RESTORATION (from hot backup)
    log "Performing pg_restore (dump-based)..."
    
    # Restore main database
    if ! restore_database "db" "$POSTGRES_USER" "$POSTGRES_DB" "${BACKUP_DIR}/db_dump.sqlc"; then
        print_error "Main database restoration from dump failed"
    fi
    
    # Restore geo database (only if enabled)
    if [ "$PROCESS_GEODB" = true ]; then
        if ! restore_database "geodb" "$GEODB_USER" "$GEODB_DB" "${BACKUP_DIR}/geodb_dump.sqlc"; then
            print_error "Geo database restoration from dump failed"
        fi
    fi
fi

log "Database restoration completed"

# =============================================================================
# START ALL SERVICES
# =============================================================================
print_step "STEP 10: Starting all services"
log "Starting all QFieldCloud services..."
if ! docker compose up -d 2>&1 | tee -a "$RESTORE_LOG"; then
    log "ERROR: Could not start all services. Check logs!"
fi

# Final health check
log "Performing final health check..."
sleep 5

HEALTHY=true

# DB check
docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1 || { log "WARNING: Main database not responding"; HEALTHY=false; }
[ "$PROCESS_GEODB" = true ] && docker compose exec -T geodb pg_isready -U "${GEODB_USER}" > /dev/null 2>&1 || { log "WARNING: Geo database not responding"; HEALTHY=false; }

# MinIO check
docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1 || { log "WARNING: MinIO not responding"; HEALTHY=false; }

# =============================================================================
# COMPLETION & CLEANUP
# =============================================================================
print_header "RESTORE COMPLETED"

# Cleanup temporary backup directory
if [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
    log "Cleaning up temporary backup directory: $TEMP_BACKUP_DIR"
    rm -rf "$TEMP_BACKUP_DIR"
    log "✓ Temporary files deleted"
fi

log ""
log "=== Restoration completed ==="
log "Restore log: $RESTORE_LOG"

if [ "$HEALTHY" = true ]; then
    log "✅ ALL SERVICES SUCCESSFULLY STARTED AND RESPONDING CORRECTLY."
else
    log "⚠️ WARNING: Some services not responding correctly. Check the logs!"
fi

echo ""
echo "=============================================================================="
echo "NEXT STEPS"
echo "=============================================================================="
echo ""
echo "1. Check the services:"
echo "   ▶ docker compose ps"
echo ""
echo "2. Check logs for errors:"
echo "   ▶ docker compose logs -f"
echo ""
echo "3. **Important:** Run **Django database migrations** if you upgraded to a newer code version:"
echo "   ▶ docker compose exec app python manage.py migrate"
echo ""
echo "4. Thoroughly test the application:"
echo "   - Web interface accessible?"
echo "   - Login and data access working?"
echo ""

echo "Restore log saved in: $RESTORE_LOG"
echo "=============================================================================="
echo ""

exit 0
