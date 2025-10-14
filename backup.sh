#!/bin/bash
# QFieldCloud Backup Script - Produktionsversion
# Stoppt sofort bei Fehlern
set -e

# =============================================================================
# KONFIGURATION
# =============================================================================
BACKUP_HOST_DIR="/mnt/qfieldcloud_backups"
MAX_BACKUPS_TO_KEEP=7
REQUIRED_SPACE_GB=10
MINIO_INTERNAL_PORT="9000"

# =============================================================================
# PARAMETER-VALIDIERUNG
# =============================================================================
if [ -z "$1" ] || ( [ "$1" != "full" ] && [ "$1" != "incremental" ] ); then
    echo "FEHLER: Bitte geben Sie den Backup-Typ an: full oder incremental."
    echo ""
    echo "Nutzung: ./backup.sh [full|incremental] [--hot|--cold]"
    echo ""
    echo "Backup-Typen:"
    echo "  full        - Vollständiges Volume-basiertes Backup"
    echo "  incremental - Schnelles Backup mit mc mirror"
    echo ""
    echo "Backup-Modi (optional):"
    echo "  --cold      - Stoppt alle Services vor Backup (DEFAULT, maximal sicher)"
    echo "  --hot       - Services laufen weiter (schneller, aber weniger konsistent)"
    echo ""
    echo "Beispiele:"
    echo "  ./backup.sh full         # Cold Backup (Services gestoppt)"
    echo "  ./backup.sh full --hot   # Hot Backup (Services laufen)"
    echo "  ./backup.sh incremental  # Immer hot (mc mirror)"
    exit 1
fi

BACKUP_TYPE="$1"
BACKUP_MODE="${2:-cold}"  # Default: cold backup

# Validiere Backup-Modus
if [ "$BACKUP_MODE" != "--cold" ] && [ "$BACKUP_MODE" != "--hot" ] && [ "$BACKUP_MODE" != "cold" ] && [ "$BACKUP_MODE" != "hot" ]; then
    echo "FEHLER: Ungültiger Backup-Modus: $BACKUP_MODE"
    echo "Verwenden Sie --cold oder --hot"
    exit 1
fi

# Entferne -- falls vorhanden
BACKUP_MODE="${BACKUP_MODE#--}"

# Incremental ist immer hot
if [ "$BACKUP_TYPE" = "incremental" ]; then
    BACKUP_MODE="hot"
fi

# Lesbarer Timestamp: 2025-10-14_12-00-00
DATE_SUFFIX=$(date +%Y-%m-%d_%H-%M-%S)

# Backup-Ordner mit klarer Struktur: DATUM_ZEIT_TYP_MODUS
BACKUP_DIR="${BACKUP_HOST_DIR}/${DATE_SUFFIX}_${BACKUP_TYPE}_${BACKUP_MODE}"

# =============================================================================
# UMGEBUNGSVARIABLEN LADEN
# =============================================================================
if [ -f .env ]; then
    source .env
else
    echo "FEHLER: Die .env-Datei wurde nicht gefunden."
    exit 1
fi

# KRITISCH: COMPOSE_FILE exportieren, damit docker compose die richtigen Files lädt
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.override.standalone.yml}"

COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}

# =============================================================================
# LOGGING INITIALISIEREN
# =============================================================================
mkdir -p "${BACKUP_DIR}/config"
LOG_FILE="${BACKUP_DIR}/backup.log"
touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== QFieldCloud ${BACKUP_TYPE^} Backup (${BACKUP_MODE^^} MODE) gestartet ==="
log "Backup-Verzeichnis: ${BACKUP_DIR}"

if [ "$BACKUP_MODE" = "hot" ]; then
    log "⚠️  HOT BACKUP MODE: Services laufen weiter (schneller, aber potentiell inkonsistent)"
else
    log "🔒 COLD BACKUP MODE: Services werden gestoppt (maximal sicher)"
fi

START_TIME=$(date +%s)

# =============================================================================
# SPEICHERPLATZ-CHECK
# =============================================================================
log "Prüfe verfügbaren Speicherplatz..."
AVAILABLE_SPACE_GB=$(df -BG "${BACKUP_HOST_DIR}" | awk 'NR==2 {print $4}' | sed 's/G//' 2>/dev/null)

if [ -z "$AVAILABLE_SPACE_GB" ]; then
    log "WARNUNG: Speicherplatzprüfung fehlgeschlagen"
elif [ "$AVAILABLE_SPACE_GB" -lt "$REQUIRED_SPACE_GB" ]; then
    log "FEHLER: Nicht genug Speicherplatz (${AVAILABLE_SPACE_GB}GB verfügbar, ${REQUIRED_SPACE_GB}GB benötigt)"
    exit 1
else
    log "Speicherplatz OK (${AVAILABLE_SPACE_GB}GB verfügbar)"
fi

# =============================================================================
# DIENSTE-MANAGEMENT BASIEREND AUF BACKUP-MODUS
# =============================================================================
if [ "$BACKUP_MODE" = "cold" ]; then
    log "=== COLD BACKUP: Stoppe alle Services ==="
    docker compose down
    log "Alle Services gestoppt"
    sleep 3
else
    log "=== HOT BACKUP: Services laufen weiter ==="
    log "Sicherstelle, dass Services laufen..."
    docker compose up -d --remove-orphans db geodb minio
    
    log "Warte auf Datenbankdienste..."
    until docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; do 
        log "  -> Warte auf Hauptdatenbank..."
        sleep 2
    done
    until docker compose exec -T geodb pg_isready -U "${GEODB_USER}" > /dev/null 2>&1; do 
        log "  -> Warte auf Geo-Datenbank..."
        sleep 2
    done
    
    log "Warte auf MinIO..."
    until docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; do
        log "  -> Warte auf MinIO..."
        sleep 2
    done
    log "Alle Dienste sind bereit"
fi

# =============================================================================
# DATENBANK-BACKUP
# =============================================================================
if [ "$BACKUP_MODE" = "cold" ]; then
    log "=== COLD DB-BACKUP: Kopiere DB-Volumes direkt ==="
    
    # PostgreSQL Volumes sichern
    DB_VOLUME="${COMPOSE_PROJECT_NAME}_postgres_data"
    GEODB_VOLUME="${COMPOSE_PROJECT_NAME}_geodb_data"
    
    mkdir -p "${BACKUP_DIR}/db_volumes"
    
    log "Sichere PostgreSQL Volume..."
    if docker volume inspect "$DB_VOLUME" > /dev/null 2>&1; then
        if ! docker run --rm \
            -v "${DB_VOLUME}:/source_data:ro" \
            -v "${BACKUP_DIR}/db_volumes:/backup_target" \
            alpine:latest \
            sh -c 'mkdir -p /backup_target/postgres_data && cp -a /source_data/. /backup_target/postgres_data/' >> "$LOG_FILE" 2>&1; then
            log "FEHLER: PostgreSQL Volume-Backup fehlgeschlagen"
            docker compose up -d  # Starte Services wieder bei Fehler
            exit 1
        fi
        log "PostgreSQL Volume gesichert ($(du -sh "${BACKUP_DIR}/db_volumes/postgres_data" | cut -f1))"
    else
        log "WARNUNG: PostgreSQL Volume $DB_VOLUME nicht gefunden"
    fi
    
    log "Sichere GeoDB Volume..."
    if docker volume inspect "$GEODB_VOLUME" > /dev/null 2>&1; then
        if ! docker run --rm \
            -v "${GEODB_VOLUME}:/source_data:ro" \
            -v "${BACKUP_DIR}/db_volumes:/backup_target" \
            alpine:latest \
            sh -c 'mkdir -p /backup_target/geodb_data && cp -a /source_data/. /backup_target/geodb_data/' >> "$LOG_FILE" 2>&1; then
            log "FEHLER: GeoDB Volume-Backup fehlgeschlagen"
            docker compose up -d  # Starte Services wieder bei Fehler
            exit 1
        fi
        log "GeoDB Volume gesichert ($(du -sh "${BACKUP_DIR}/db_volumes/geodb_data" | cut -f1))"
    else
        log "WARNUNG: GeoDB Volume $GEODB_VOLUME nicht gefunden"
    fi
    
else
    log "=== HOT DB-BACKUP: Verwende pg_dump ==="
    
    log "Sichere Hauptdatenbank..."
    if ! docker compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc -Z9 > "${BACKUP_DIR}/db_dump.sqlc" 2>> "$LOG_FILE"; then
        log "FEHLER: Hauptdatenbank-Backup fehlgeschlagen"
        exit 1
    fi
    log "Hauptdatenbank gesichert ($(du -h "${BACKUP_DIR}/db_dump.sqlc" | cut -f1))"

    log "Sichere Geo-Datenbank..."
    if ! docker compose exec -T geodb pg_dump -U "${GEODB_USER}" -d "${GEODB_DB}" -Fc -Z9 > "${BACKUP_DIR}/geodb_dump.sqlc" 2>> "$LOG_FILE"; then
        log "FEHLER: Geo-Datenbank-Backup fehlgeschlagen"
        exit 1
    fi
    log "Geo-Datenbank gesichert ($(du -h "${BACKUP_DIR}/geodb_dump.sqlc" | cut -f1))"
fi

# =============================================================================
# MINIO-BACKUP
# =============================================================================
if [ "$BACKUP_TYPE" = "full" ]; then
    # FULL BACKUP: Volume-Backup
    log "=== FULL BACKUP: Sichere MinIO-Volumes ==="
    
    if [ "$BACKUP_MODE" = "hot" ]; then
        log "⚠️  WARNUNG: Hot Volume-Backup kann zu inkonsistenten Daten führen!"
        log "⚠️  Für produktive Backups wird --cold empfohlen."
    fi
    
    MINIO_BACKUP_PATH="${BACKUP_DIR}/minio_volumes"
    mkdir -p "$MINIO_BACKUP_PATH"
    
    for i in 1 2 3 4; do
        VOLUME_NAME="${COMPOSE_PROJECT_NAME}_minio_data${i}"
        TARGET_DIR="${MINIO_BACKUP_PATH}/data${i}"
        mkdir -p "$TARGET_DIR"
        
        log "  -> Sichere Volume ${VOLUME_NAME}..."
        
        # Prüfe ob Volume existiert
        if ! docker volume inspect "$VOLUME_NAME" > /dev/null 2>&1; then
            log "WARNUNG: Volume ${VOLUME_NAME} existiert nicht"
            continue
        fi
        
        # Kopiere Volume-Daten
        if ! docker run --rm \
            -v "${VOLUME_NAME}:/source_data:ro" \
            -v "${TARGET_DIR}:/backup_target" \
            alpine:latest \
            sh -c 'cp -a /source_data/. /backup_target/' >> "$LOG_FILE" 2>&1; then
            log "FEHLER: Volume ${VOLUME_NAME} Backup fehlgeschlagen"
            [ "$BACKUP_MODE" = "cold" ] && docker compose up -d
            exit 1
        fi
        
        VOLUME_SIZE=$(du -sh "$TARGET_DIR" | cut -f1)
        log "  -> Volume ${i} gesichert (${VOLUME_SIZE})"
    done
    
    log "MinIO-Volumes gesichert"
    
else
    # INCREMENTAL BACKUP: mc mirror (immer hot)
    log "=== INCREMENTAL BACKUP: Nutze mc mirror ==="
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
        log "FEHLER: MinIO-Backup fehlgeschlagen"
        exit 1
    fi
    log "MinIO-Daten inkrementell gesichert"
fi

# =============================================================================
# KONFIGURATIONEN SICHERN
# =============================================================================
log "Sichere Konfigurationsdateien..."

# Git-Informationen ins Log schreiben
log "=== Git-Informationen ==="
if command -v git > /dev/null 2>&1 && [ -d .git ]; then
    log "Git Repository gefunden - sichere Version-Informationen..."
    
    echo "" >> "$LOG_FILE"
    echo "=== GIT COMMIT INFORMATION ===" >> "$LOG_FILE"
    git log -1 >> "$LOG_FILE" 2>&1 || echo "Konnte git log nicht ausführen" >> "$LOG_FILE"
    
    echo "" >> "$LOG_FILE"
    echo "=== GIT REMOTE INFORMATION ===" >> "$LOG_FILE"
    git remote -v >> "$LOG_FILE" 2>&1 || echo "Konnte git remote nicht ausführen" >> "$LOG_FILE"
    
    echo "" >> "$LOG_FILE"
    log "Git-Informationen im Log gesichert"
else
    log "Kein Git Repository gefunden - überspringe Git-Informationen"
fi

# Certbot Konfiguration
if [ -d "./conf/certbot/conf" ]; then
    cp -R "./conf/certbot/conf" "${BACKUP_DIR}/config/certbot"
    log "  -> Certbot-Konfiguration gesichert"
fi

# Nginx Zertifikate
if [ -d "./conf/nginx/certs" ]; then
    cp -R "./conf/nginx/certs" "${BACKUP_DIR}/config/nginx_certs"
    log "  -> Nginx-Zertifikate gesichert"
fi

# .env Datei
if [ -f .env ]; then
    cp .env "${BACKUP_DIR}/config/.env"
    log "  -> .env Datei gesichert"
fi

# Alle Docker Compose YAML-Dateien
log "Sichere Docker Compose Konfigurationen..."
COMPOSE_FILES_FOUND=0
for yml_file in *.yml *.yaml; do
    if [ -f "$yml_file" ]; then
        cp "$yml_file" "${BACKUP_DIR}/config/"
        log "  -> $yml_file gesichert"
        COMPOSE_FILES_FOUND=$((COMPOSE_FILES_FOUND + 1))
    fi
done

if [ $COMPOSE_FILES_FOUND -eq 0 ]; then
    log "WARNUNG: Keine Docker Compose YAML-Dateien gefunden"
else
    log "  -> $COMPOSE_FILES_FOUND Docker Compose Datei(en) gesichert"
fi

log "Konfigurationen gesichert"

# =============================================================================
# CHECKSUMS ERSTELLEN
# =============================================================================
log "Erstelle SHA256 Checksums..."
(
    cd "${BACKUP_DIR}"
    find . -type f ! -name "checksums.sha256" -exec sha256sum {} \; > checksums.sha256
) || {
    log "FEHLER: Checksum-Erstellung fehlgeschlagen"
    exit 1
}
log "Checksums erstellt"

# =============================================================================
# BACKUP-ROTATION
# =============================================================================
if [ "$MAX_BACKUPS_TO_KEEP" -gt 0 ]; then
    log "Führe Backup-Rotation durch (max. ${MAX_BACKUPS_TO_KEEP} Backups)..."
    
    # Zähle existierende Backups (ohne das aktuelle)
    BACKUP_COUNT=$(find "${BACKUP_HOST_DIR}" -maxdepth 1 -type d -name "*_*" ! -path "$BACKUP_DIR" | wc -l)
    
    if [ "$BACKUP_COUNT" -ge "$MAX_BACKUPS_TO_KEEP" ]; then
        find "${BACKUP_HOST_DIR}" -maxdepth 1 -type d -name "*_*" ! -path "$BACKUP_DIR" | \
            sort | head -n -$((MAX_BACKUPS_TO_KEEP - 1)) | while read OLD_BACKUP; do
                log "  -> Lösche altes Backup: $(basename "$OLD_BACKUP")"
                rm -rf "$OLD_BACKUP"
            done
        log "Rotation abgeschlossen"
    else
        log "Keine Rotation nötig (nur ${BACKUP_COUNT} Backups vorhanden)"
    fi
fi

# =============================================================================
# SERVICES WIEDERHERSTELLEN (BEI COLD BACKUP)
# =============================================================================
if [ "$BACKUP_MODE" = "cold" ]; then
    log "Starte alle Services wieder..."
    docker compose up -d
    
    # Warte auf kritische Services
    log "Warte auf Service-Neustart..."
    sleep 5
    
    TIMEOUT=60
    ELAPSED=0
    
    # Prüfe ob Services wieder laufen
    until docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            log "WARNUNG: Datenbank-Neustart dauert länger als erwartet"
            break
        fi
        log "  -> Warte auf Datenbank..."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    
    ELAPSED=0
    until docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            log "WARNUNG: MinIO-Neustart dauert länger als erwartet"
            break
        fi
        log "  -> Warte auf MinIO..."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    
    log "Services erfolgreich neugestartet"
fi

# =============================================================================
# ABSCHLUSS
# =============================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
BACKUP_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)

log "=== Backup ERFOLGREICH abgeschlossen ==="
log "Typ: ${BACKUP_TYPE^} (${BACKUP_MODE^^} MODE)"
log "Dauer: ${DURATION} Sekunden"
log "Größe: ${BACKUP_SIZE}"
log "Pfad: ${BACKUP_DIR}"

if [ "$BACKUP_MODE" = "hot" ] && [ "$BACKUP_TYPE" = "full" ]; then
    log ""
    log "⚠️  HINWEIS: Hot Full Backup durchgeführt."
    log "⚠️  Für maximale Konsistenz verwenden Sie: ./backup.sh full --cold"
fi

exit 0
