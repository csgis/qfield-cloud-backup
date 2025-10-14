#!/bin/bash
# QFieldCloud Restore Script - Disaster Recovery Edition
# Stoppt sofort bei Fehlern
set -e

# =============================================================================
# HILFS-FUNKTIONEN
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

check_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "FEHLER: $1 ist nicht installiert!"
        echo "Bitte installieren Sie $1: $2"
        return 1
    fi
    return 0
}

# =============================================================================
# INTRO & SYSTEM-CHECKS
# =============================================================================
print_header "QFieldCloud Disaster Recovery & Restore Script"

echo "Dieses Skript führt Sie durch die vollständige Wiederherstellung einer"
echo "QFieldCloud-Instanz aus einem Backup - auch auf einem komplett neuen Server."
echo ""
echo "Voraussetzungen:"
echo "  ✓ Docker & Docker Compose installiert"
echo "  ○ Git (optional, für Code-Wiederherstellung)"
echo "  ○ rsync (optional, für Remote-Backup-Transfer)"
echo ""

# Prüfe Docker
print_step "SCHRITT 1: System-Voraussetzungen prüfen"

if ! check_command "docker" "sudo apt install docker.io"; then
    exit 1
fi
echo "✓ Docker gefunden: $(docker --version)"

if ! docker compose version > /dev/null 2>&1; then
    echo "FEHLER: Docker Compose Plugin nicht verfügbar!"
    echo "Installation: sudo apt install docker-compose-plugin"
    exit 1
fi
echo "✓ Docker Compose gefunden: $(docker compose version)"

# Optionale Tools
GIT_AVAILABLE=false
RSYNC_AVAILABLE=false

if command -v git > /dev/null 2>&1; then
    GIT_AVAILABLE=true
    echo "✓ Git gefunden: $(git --version | head -n1)"
fi

if command -v rsync > /dev/null 2>&1; then
    RSYNC_AVAILABLE=true
    echo "✓ rsync gefunden: $(rsync --version | head -n1)"
fi

# =============================================================================
# BACKUP-QUELLE BESTIMMEN
# =============================================================================
print_step "SCHRITT 2: Backup-Quelle festlegen"

echo "Wo befindet sich Ihr Backup?"
echo "  1) Lokal auf diesem Server (Pfad angeben)"
echo "  2) Auf einem Remote-Server (via rsync herunterladen)"
echo ""
read -r -p "Ihre Wahl (1/2): " BACKUP_SOURCE_TYPE

BACKUP_DIR=""
TEMP_BACKUP_DIR="/tmp/qfieldcloud_restore_$(date +%s)"

if [ "$BACKUP_SOURCE_TYPE" = "2" ]; then
    # Remote Backup
    if [ "$RSYNC_AVAILABLE" = false ]; then
        echo "FEHLER: rsync wird benötigt für Remote-Backup-Transfer!"
        echo "Installation: sudo apt install rsync"
        exit 1
    fi
    
    echo ""
    echo "=== Remote Backup-Transfer ==="
    echo ""
    read -r -p "Remote Server (user@host): " REMOTE_HOST
    read -r -p "Remote Backup-Pfad: " REMOTE_BACKUP_PATH
    
    echo ""
    echo "Übertrage Backup nach $TEMP_BACKUP_DIR ..."
    mkdir -p "$TEMP_BACKUP_DIR"
    
    if ! rsync -avz --progress "${REMOTE_HOST}:${REMOTE_BACKUP_PATH}/" "$TEMP_BACKUP_DIR/"; then
        echo "FEHLER: rsync fehlgeschlagen!"
        rm -rf "$TEMP_BACKUP_DIR"
        exit 1
    fi
    
    BACKUP_DIR="$TEMP_BACKUP_DIR"
    echo "✓ Backup erfolgreich übertragen"
    
else
    # Lokales Backup
    echo ""
    read -r -p "Lokaler Backup-Pfad: " LOCAL_BACKUP_PATH
    
    if [ ! -d "$LOCAL_BACKUP_PATH" ]; then
        echo "FEHLER: Backup-Verzeichnis existiert nicht: $LOCAL_BACKUP_PATH"
        exit 1
    fi
    
    BACKUP_DIR=$(realpath "$LOCAL_BACKUP_PATH")
    echo "✓ Lokales Backup gefunden"
fi

# =============================================================================
# BACKUP-INFORMATIONEN ANZEIGEN
# =============================================================================
print_step "SCHRITT 3: Backup-Informationen"

echo "Backup-Quelle: $BACKUP_DIR"
echo "Backup-Name: $(basename "$BACKUP_DIR")"
echo ""

# Zeige Git-Informationen aus dem Backup-Log
if [ -f "${BACKUP_DIR}/backup.log" ]; then
    echo "=== Backup-Details ==="
    
    # Extrahiere Git Commit Info
    if grep -q "GIT COMMIT INFORMATION" "${BACKUP_DIR}/backup.log"; then
        echo ""
        echo "Git Commit im Backup:"
        BACKUP_COMMIT=$(sed -n '/GIT COMMIT INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep "^commit" | awk '{print $2}')
        sed -n '/GIT COMMIT INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep -E "^(commit|Author|Date)" | while read line; do
            echo "  $line"
        done
    fi
    
    # Extrahiere Git Remote Info
    if grep -q "GIT REMOTE INFORMATION" "${BACKUP_DIR}/backup.log"; then
        echo ""
        echo "Git Remote im Backup:"
        BACKUP_REMOTE=$(sed -n '/GIT REMOTE INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep "origin" | awk '{print $2}' | head -n1)
        sed -n '/GIT REMOTE INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep -v "GIT REMOTE INFORMATION" | grep -v "^$" | while read line; do
            echo "  $line"
        done
    fi
    echo ""
fi

# =============================================================================
# CODE-WIEDERHERSTELLUNG (GIT)
# =============================================================================
print_step "SCHRITT 4: QFieldCloud Code wiederherstellen"

WORKING_DIR=$(pwd)
CODE_READY=false

if [ -d ".git" ] && [ -f "docker-compose.yml" ]; then
    echo "✓ QFieldCloud Repository bereits vorhanden im aktuellen Verzeichnis"
    CODE_READY=true
    
    if [ "$GIT_AVAILABLE" = true ] && [ -n "$BACKUP_COMMIT" ]; then
        echo ""
        echo "Backup wurde mit Commit erstellt: $BACKUP_COMMIT"
        echo "Aktueller Commit: $(git rev-parse HEAD)"
        echo ""
        read -r -p "Möchten Sie zum Backup-Commit wechseln? (ja/nein): " CHECKOUT_COMMIT
        
        if [ "$CHECKOUT_COMMIT" = "ja" ]; then
            echo "Führe git fetch und checkout durch..."
            git fetch --all
            if git checkout "$BACKUP_COMMIT" 2>/dev/null; then
                echo "✓ Erfolgreich zu Commit $BACKUP_COMMIT gewechselt"
            else
                echo "WARNUNG: Konnte nicht zu Commit wechseln - verwende aktuellen Stand"
            fi
        fi
    fi
    
elif [ "$GIT_AVAILABLE" = true ] && [ -n "$BACKUP_REMOTE" ]; then
    echo "Kein QFieldCloud Repository gefunden."
    echo "Git Remote aus Backup: $BACKUP_REMOTE"
    echo ""
    read -r -p "Möchten Sie das Repository klonen? (ja/nein): " DO_CLONE
    
    if [ "$DO_CLONE" = "ja" ]; then
        CLONE_DIR="QFieldCloud_$(date +%s)"
        echo "Clone Repository nach $CLONE_DIR ..."
        
        if git clone "$BACKUP_REMOTE" "$CLONE_DIR"; then
            cd "$CLONE_DIR"
            WORKING_DIR=$(pwd)
            
            if [ -n "$BACKUP_COMMIT" ]; then
                echo "Wechsle zu Backup-Commit: $BACKUP_COMMIT"
                if git checkout "$BACKUP_COMMIT" 2>/dev/null; then
                    echo "✓ Erfolgreich zu Commit $BACKUP_COMMIT gewechselt"
                else
                    echo "WARNUNG: Konnte nicht zu Commit wechseln"
                fi
            fi
            
            CODE_READY=true
            echo "✓ Repository geklont"
        else
            echo "FEHLER: Git clone fehlgeschlagen!"
            exit 1
        fi
    fi
else
    echo "⚠ WARNUNG: Code-Wiederherstellung nicht möglich"
    echo ""
    echo "Sie müssen manuell das QFieldCloud Repository bereitstellen:"
    echo "  1. Repository klonen oder entpacken"
    echo "  2. In das Verzeichnis wechseln"
    echo "  3. Dieses Skript erneut ausführen"
    echo ""
    read -r -p "Haben Sie den Code bereits manuell vorbereitet? (ja/nein): " CODE_MANUAL
    
    if [ "$CODE_MANUAL" != "ja" ]; then
        echo "Abbruch. Bitte Code vorbereiten und erneut starten."
        exit 1
    fi
    CODE_READY=true
fi

# =============================================================================
# KONFIGURATIONSDATEIEN VORBEREITEN
# =============================================================================
print_step "SCHRITT 5: Konfigurationsdateien vorbereiten"

if [ ! -f ".env" ] && [ -f "${BACKUP_DIR}/config/.env" ]; then
    echo "Keine .env Datei gefunden - stelle aus Backup wieder her..."
    cp "${BACKUP_DIR}/config/.env" .env
    echo "✓ .env aus Backup wiederhergestellt"
fi

if [ ! -f "docker-compose.yml" ] && [ -f "${BACKUP_DIR}/config/docker-compose.yml" ]; then
    echo "Keine docker-compose.yml gefunden - stelle aus Backup wieder her..."
    cp "${BACKUP_DIR}/config/"*.yml . 2>/dev/null || true
    echo "✓ Docker Compose Dateien aus Backup wiederhergestellt"
fi

# Jetzt .env laden
if [ -f .env ]; then
    source .env
    export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.override.standalone.yml}"
    COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}
    MINIO_INTERNAL_PORT="${MINIO_API_PORT:-9000}"
    echo "✓ .env geladen"
else
    echo "FEHLER: Keine .env Datei gefunden!"
    echo "Bitte erstellen Sie eine .env Datei oder stellen Sie sie aus dem Backup wieder her:"
    echo "  cp ${BACKUP_DIR}/config/.env .env"
    exit 1
fi

# =============================================================================
# FINALE BESTÄTIGUNG
# =============================================================================
print_header "BEREIT FÜR RESTORE"

echo "Zusammenfassung:"
echo "  • Backup: $(basename "$BACKUP_DIR")"
echo "  • Arbeitsverzeichnis: $WORKING_DIR"
echo "  • Docker Compose Projekt: $COMPOSE_PROJECT_NAME"
if [ -n "$BACKUP_COMMIT" ]; then
    echo "  • Git Commit: $BACKUP_COMMIT"
fi
echo ""
echo "⚠️  WARNUNG: Der Restore wird:"
echo "  1. Alle Container stoppen"
echo "  2. Alle Volumes überschreiben"
echo "  3. Alle Datenbanken überschreiben"
echo "  4. MinIO-Daten überschreiben"
echo ""

echo ""
read -r -p "Zum Fortfahren tippen Sie 'RESTORE JETZT' ein: " FINAL_CONFIRMATION

if [ "$FINAL_CONFIRMATION" != "RESTORE JETZT" ]; then
    echo "Restore abgebrochen."
    [ -d "$TEMP_BACKUP_DIR" ] && rm -rf "$TEMP_BACKUP_DIR"
    exit 0
fi

# =============================================================================
# LOGGING-FUNKTION
# =============================================================================
RESTORE_LOG="restore_$(date +%Y-%m-%d_%H-%M-%S).log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTORE_LOG"
}

print_header "RESTORE WIRD AUSGEFÜHRT"
log "=== QFieldCloud Wiederherstellung gestartet ==="
log "Backup-Quelle: $BACKUP_DIR"
log "Arbeitsverzeichnis: $WORKING_DIR"

# =============================================================================
# BACKUP-VALIDIERUNG
# =============================================================================
print_step "SCHRITT 6: Backup validieren"

# Erkenne Backup-Typ anhand vorhandener Dateien/Ordner
DB_BACKUP_TYPE="unknown"
MINIO_BACKUP_TYPE="unknown"

# Prüfe Datenbank-Backup-Typ
if [ -d "${BACKUP_DIR}/db_volumes" ]; then
    DB_BACKUP_TYPE="volume"
    log "Datenbank-Backup-Typ: Volume-basiert (cold backup)"
    
    if [ ! -d "${BACKUP_DIR}/db_volumes/postgres_data" ]; then
        log "WARNUNG: PostgreSQL Volume fehlt"
    fi
    if [ ! -d "${BACKUP_DIR}/db_volumes/geodb_data" ]; then
        log "WARNUNG: GeoDB Volume fehlt"
    fi
elif [ -f "${BACKUP_DIR}/db_dump.sqlc" ] && [ -f "${BACKUP_DIR}/geodb_dump.sqlc" ]; then
    DB_BACKUP_TYPE="dump"
    log "Datenbank-Backup-Typ: pg_dump-basiert (hot backup)"
else
    log "FEHLER: Keine gültigen Datenbank-Backups gefunden"
    exit 1
fi

# Erkenne MinIO-Backup-Typ
if [ -d "${BACKUP_DIR}/minio_volumes" ]; then
    MINIO_BACKUP_TYPE="volume"
    log "MinIO-Backup-Typ: Volume-basiert (full)"
    
    # Prüfe alle 4 MinIO-Volumes
    for i in 1 2 3 4; do
        if [ ! -d "${BACKUP_DIR}/minio_volumes/data${i}" ]; then
            log "WARNUNG: MinIO Volume data${i} fehlt im Backup"
        fi
    done
elif [ -d "${BACKUP_DIR}/minio_project_files" ] || [ -d "${BACKUP_DIR}/minio_storage" ]; then
    MINIO_BACKUP_TYPE="mirror"
    log "MinIO-Backup-Typ: Mirror-basiert (incremental)"
    
    if [ ! -d "${BACKUP_DIR}/minio_project_files" ]; then
        log "WARNUNG: minio_project_files fehlt"
    fi
    if [ ! -d "${BACKUP_DIR}/minio_storage" ]; then
        log "WARNUNG: minio_storage fehlt"
    fi
else
    log "FEHLER: Keine MinIO-Daten im Backup gefunden"
    exit 1
fi

# Checksum-Validierung
if [ -f "${BACKUP_DIR}/checksums.sha256" ]; then
    log "Validiere Checksums..."
    if (cd "${BACKUP_DIR}" && sha256sum -c checksums.sha256 > /dev/null 2>&1); then
        log "✓ Checksums erfolgreich validiert"
    else
        log "WARNUNG: Checksum-Validierung fehlgeschlagen!"
        echo ""
        read -r -p "Trotzdem fortfahren? (ja/nein) " RESPONSE
        [[ "$RESPONSE" != "ja" ]] && exit 1
    fi
else
    log "WARNUNG: Keine Checksums gefunden - Integrität kann nicht geprüft werden"
fi

# =============================================================================
# SICHERHEITS-WARNUNG
# =============================================================================
log ""
log "!!! LETZTE WARNUNG !!!"
log "Alle aktuellen Daten werden überschrieben!"
log ""

# =============================================================================
# DIENSTE HERUNTERFAHREN
# =============================================================================
print_step "SCHRITT 7: Services herunterfahren"
log "Fahre alle QFieldCloud-Dienste herunter..."
docker compose down 2>&1 | tee -a "$RESTORE_LOG" || true
sleep 3
log "✓ Dienste gestoppt"

# =============================================================================
# MINIO-WIEDERHERSTELLUNG
# =============================================================================
print_step "SCHRITT 8: MinIO-Daten wiederherstellen"
log "=== MinIO-Wiederherstellung ==="

if [ "$MINIO_BACKUP_TYPE" = "volume" ]; then
    # VOLUME-BASIERTE WIEDERHERSTELLUNG
    log "Stelle MinIO-Volumes wieder her (volume-basiert)..."
    
    for i in 1 2 3 4; do
        VOLUME_NAME="${COMPOSE_PROJECT_NAME}_minio_data${i}"
        SOURCE_DIR="${BACKUP_DIR}/minio_volumes/data${i}"
        
        if [ ! -d "$SOURCE_DIR" ]; then
            log "WARNUNG: Überspringe data${i} (nicht im Backup)"
            continue
        fi
        
        log "  -> Stelle Volume ${VOLUME_NAME} wieder her..."
        
        # Erstelle Volume falls nicht vorhanden
        docker volume create "$VOLUME_NAME" > /dev/null 2>&1 || true
        
        # SICHERE Volume-Wiederherstellung mit Validierung
        if ! docker run --rm \
            -v "${SOURCE_DIR}:/source_data:ro" \
            -v "${VOLUME_NAME}:/target_data" \
            alpine:latest \
            sh -c '
                # Prüfe ob Volumes korrekt gemountet sind
                if [ ! -d /target_data ] || [ ! -d /source_data ]; then
                    echo "ERROR: Volumes nicht korrekt gemountet"
                    exit 1
                fi
                
                # Lösche alte Daten (alle Dateien inklusive versteckte)
                rm -rf /target_data/* /target_data/.[!.]* /target_data/..?* 2>/dev/null || true
                
                # Kopiere neue Daten
                cp -a /source_data/. /target_data/
                
                # Validiere
                if [ ! "$(ls -A /target_data)" ]; then
                    echo "ERROR: Ziel-Volume ist leer nach Kopie"
                    exit 1
                fi
            '; then
            log "FEHLER: Volume ${i} Wiederherstellung fehlgeschlagen"
            exit 1
        fi
        
        log "  -> Volume ${i} wiederhergestellt"
    done
    
else
    # MIRROR-BASIERTE WIEDERHERSTELLUNG
    log "Stelle MinIO-Daten wieder her (mirror-basiert)..."
    log "Starte MinIO temporär für die Wiederherstellung..."
    
    docker compose up -d minio
    
    # Warte auf MinIO
    until docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; do
        log "  -> Warte auf MinIO..."
        sleep 2
    done
    
    MINIO_HOST="minio:${MINIO_INTERNAL_PORT}"
    MINIO_ALIAS="qfieldcloudminio"
    
    if ! docker run --rm \
        --network "${COMPOSE_PROJECT_NAME}_default" \
        -v "${BACKUP_DIR}:/backup:ro" \
        minio/mc \
        /bin/sh -c "
            mc alias set ${MINIO_ALIAS} http://${MINIO_HOST} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
            mc mirror --overwrite --remove /backup/minio_project_files ${MINIO_ALIAS}/qfieldcloud-project-files && \
            mc mirror --overwrite --remove /backup/minio_storage ${MINIO_ALIAS}/qfieldcloud-storage
        "; then
        log "FEHLER: MinIO-Wiederherstellung fehlgeschlagen"
        exit 1
    fi
    
    log "Stoppe MinIO..."
    docker compose stop minio
fi

log "MinIO-Wiederherstellung abgeschlossen"

# =============================================================================
# DATENBANK-WIEDERHERSTELLUNG
# =============================================================================
print_step "SCHRITT 9: Datenbanken wiederherstellen"
log "=== Datenbank-Wiederherstellung ==="

if [ "$DB_BACKUP_TYPE" = "volume" ]; then
    # VOLUME-BASIERTE WIEDERHERSTELLUNG (von Cold Backup)
    log "Stelle DB-Volumes wieder her (volume-basiert, von cold backup)..."
    
    DB_VOLUME="${COMPOSE_PROJECT_NAME}_postgres_data"
    GEODB_VOLUME="${COMPOSE_PROJECT_NAME}_geodb_data"
    
    # PostgreSQL Volume
    if [ -d "${BACKUP_DIR}/db_volumes/postgres_data" ]; then
        log "  -> Stelle PostgreSQL Volume wieder her..."
        docker volume create "$DB_VOLUME" > /dev/null 2>&1 || true
        
        if ! docker run --rm \
            -v "${BACKUP_DIR}/db_volumes/postgres_data:/source_data:ro" \
            -v "${DB_VOLUME}:/target_data" \
            alpine:latest \
            sh -c '
                if [ ! -d /target_data ] || [ ! -d /source_data ]; then
                    echo "ERROR: Volumes nicht korrekt gemountet"
                    exit 1
                fi
                rm -rf /target_data/* /target_data/.[!.]* /target_data/..?* 2>/dev/null || true
                cp -a /source_data/. /target_data/
                if [ ! "$(ls -A /target_data)" ]; then
                    echo "ERROR: Ziel-Volume ist leer"
                    exit 1
                fi
            '; then
            log "FEHLER: PostgreSQL Volume-Wiederherstellung fehlgeschlagen"
            exit 1
        fi
        log "  -> PostgreSQL Volume wiederhergestellt"
    fi
    
    # GeoDB Volume
    if [ -d "${BACKUP_DIR}/db_volumes/geodb_data" ]; then
        log "  -> Stelle GeoDB Volume wieder her..."
        docker volume create "$GEODB_VOLUME" > /dev/null 2>&1 || true
        
        if ! docker run --rm \
            -v "${BACKUP_DIR}/db_volumes/geodb_data:/source_data:ro" \
            -v "${GEODB_VOLUME}:/target_data" \
            alpine:latest \
            sh -c '
                if [ ! -d /target_data ] || [ ! -d /source_data ]; then
                    echo "ERROR: Volumes nicht korrekt gemountet"
                    exit 1
                fi
                rm -rf /target_data/* /target_data/.[!.]* /target_data/..?* 2>/dev/null || true
                cp -a /source_data/. /target_data/
                if [ ! "$(ls -A /target_data)" ]; then
                    echo "ERROR: Ziel-Volume ist leer"
                    exit 1
                fi
            '; then
            log "FEHLER: GeoDB Volume-Wiederherstellung fehlgeschlagen"
            exit 1
        fi
        log "  -> GeoDB Volume wiederhergestellt"
    fi
    
    log "Starte Datenbankdienste nach Volume-Restore..."
    docker compose up -d db geodb
    
else
    # DUMP-BASIERTE WIEDERHERSTELLUNG (von Hot Backup)
    log "Stelle Datenbanken wieder her (pg_dump-basiert, von hot backup)..."
    log "Starte Datenbankdienste..."
    docker compose up -d db geodb
fi

# Warte auf Datenbanken mit Timeout (für beide Backup-Typen)
log "Warte auf Datenbankdienste..."
TIMEOUT=60
ELAPSED=0

while ! docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "FEHLER: Hauptdatenbank-Timeout nach ${TIMEOUT}s"
        exit 1
    fi
    log "  -> Warte auf Hauptdatenbank..."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

ELAPSED=0
while ! docker compose exec -T geodb pg_isready -U "${GEODB_USER}" > /dev/null 2>&1; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "FEHLER: Geo-Datenbank-Timeout nach ${TIMEOUT}s"
        exit 1
    fi
    log "  -> Warte auf Geo-Datenbank..."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

log "Datenbanken sind bereit"

# Funktion: Datenbank wiederherstellen (nur für Dump-basierte Backups)
restore_database() {
    local SERVICE_NAME=$1
    local USER=$2
    local DB_NAME=$3
    local DUMP_FILE=$4
    
    log "Stelle Datenbank ${DB_NAME} wieder her..."
    
    # Lösche alte Datenbank
    log "  -> Lösche alte Datenbank..."
    docker compose exec -T "$SERVICE_NAME" dropdb -U "$USER" "$DB_NAME" --if-exists 2>/dev/null || true
    
    # Erstelle neue Datenbank
    log "  -> Erstelle neue Datenbank..."
    if ! docker compose exec -T "$SERVICE_NAME" createdb -U "$USER" "$DB_NAME"; then
        log "FEHLER: Datenbank-Erstellung fehlgeschlagen: $DB_NAME"
        return 1
    fi
    
    # Restore über STDIN (sicher und zuverlässig)
    log "  -> Importiere Daten..."
    if ! cat "$DUMP_FILE" | docker compose exec -i "$SERVICE_NAME" pg_restore -U "$USER" -d "$DB_NAME" --no-owner --no-acl 2>&1 | grep -v "WARNING"; then
        # pg_restore gibt oft harmlose Warnings aus - wir filtern sie
        log "WARNUNG: Einige Restore-Warnings aufgetreten (meist harmlos)"
    fi
    
    # Validiere Restore
    TABLE_COUNT=$(docker compose exec -T "$SERVICE_NAME" psql -U "$USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d ' ')
    
    if [ -z "$TABLE_COUNT" ] || [ "$TABLE_COUNT" -eq 0 ]; then
        log "FEHLER: Datenbank ${DB_NAME} scheint leer zu sein"
        return 1
    fi
    
    log "  -> Datenbank ${DB_NAME} wiederhergestellt (${TABLE_COUNT} Tabellen)"
    return 0
}

# Führe Restore nur bei Dump-basierten Backups durch
if [ "$DB_BACKUP_TYPE" = "dump" ]; then
    # Hauptdatenbank wiederherstellen
    if ! restore_database "db" "$POSTGRES_USER" "$POSTGRES_DB" "${BACKUP_DIR}/db_dump.sqlc"; then
        log "FEHLER: Hauptdatenbank-Wiederherstellung fehlgeschlagen"
        exit 1
    fi

    # Geo-Datenbank wiederherstellen
    if ! restore_database "geodb" "$GEODB_USER" "$GEODB_DB" "${BACKUP_DIR}/geodb_dump.sqlc"; then
        log "FEHLER: Geo-Datenbank-Wiederherstellung fehlgeschlagen"
        exit 1
    fi
else
    log "Volume-basierte Wiederherstellung - keine pg_restore nötig"
    log "Datenbanken wurden direkt aus Volumes wiederhergestellt"
fi

log "Datenbank-Wiederherstellung abgeschlossen"

# =============================================================================
# ALLE DIENSTE STARTEN
# =============================================================================
print_step "SCHRITT 10: Services starten"
log "Starte alle QFieldCloud-Dienste..."
docker compose up -d 2>&1 | tee -a "$RESTORE_LOG"

# Finaler Health-Check
log "Führe finalen Health-Check durch..."
sleep 5

HEALTHY=true

if ! docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; then
    log "WARNUNG: Hauptdatenbank antwortet nicht"
    HEALTHY=false
fi

if ! docker compose exec -T geodb pg_isready -U "${GEODB_USER}" > /dev/null 2>&1; then
    log "WARNUNG: Geo-Datenbank antwortet nicht"
    HEALTHY=false
fi

if ! docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; then
    log "WARNUNG: MinIO antwortet nicht"
    HEALTHY=false
fi

# =============================================================================
# ABSCHLUSS & CLEANUP
# =============================================================================
print_header "RESTORE ABGESCHLOSSEN"

# Cleanup temporäres Backup-Verzeichnis
if [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
    log "Räume temporäres Backup-Verzeichnis auf..."
    rm -rf "$TEMP_BACKUP_DIR"
    log "✓ Temporäre Dateien gelöscht"
fi

log ""
log "=== Wiederherstellung abgeschlossen ==="
log "Restore-Log: $RESTORE_LOG"

if [ "$HEALTHY" = true ]; then
    log "✓ Alle Dienste sind erfolgreich gestartet"
else
    log "⚠ WARNUNG: Einige Dienste antworten nicht korrekt"
    log "Prüfen Sie die Logs mit: docker compose logs"
fi

echo ""
echo "=============================================================================="
echo "NÄCHSTE SCHRITTE"
echo "=============================================================================="
echo ""
echo "1. Überprüfen Sie die Services:"
echo "   docker compose ps"
echo ""
echo "2. Prüfen Sie die Logs:"
echo "   docker compose logs -f"
echo ""
echo "3. Testen Sie die Anwendung:"
echo "   - Webinterface erreichbar?"
echo "   - Login funktioniert?"
echo "   - Daten vorhanden?"
echo ""
echo "4. Überprüfen Sie die Konfiguration:"
echo "   - Hostnamen korrekt?"
echo "   - SSL-Zertifikate gültig?"
echo "   - Ports erreichbar?"
echo ""
if [ -n "$BACKUP_COMMIT" ]; then
    echo "5. Git Status prüfen:"
    echo "   git status"
    echo "   git log -1"
    echo ""
fi
echo "Restore-Log gespeichert in: $RESTORE_LOG"
echo "=============================================================================="
echo ""

exit 0
