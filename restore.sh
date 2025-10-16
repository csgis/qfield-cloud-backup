#!/bin/bash
# QFieldCloud Restore Script - Disaster Recovery Edition
# Version: 3.0 - General Refactoring & Pre-Init Logic
# Stoppt sofort bei Fehlern
set -e

# =============================================================================
# KONFIGURATION
# =============================================================================
# GeoDB Wiederherstellung aktivieren? (true/false)
# Standard: false (GeoDB wurde in neueren Versionen entfernt)
RESTORE_GEODB=${RESTORE_GEODB:-false}

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

print_error() {
    echo "❌ FEHLER: $1" >&2
    echo "Restore abgebrochen." >&2
    # Entferne temporäres Backup-Verzeichnis bei Fehler
    if [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
        log "Räume temporäres Backup-Verzeichnis bei Fehler auf..."
        rm -rf "$TEMP_BACKUP_DIR" 2>/dev/null || true
    fi
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTORE_LOG"
}

check_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        print_error "$1 ist nicht installiert! Bitte installieren: $2"
    fi
}

# =============================================================================
# INTRO & SYSTEM-CHECKS
# =============================================================================
print_header "QFieldCloud Disaster Recovery & Restore Script"

RESTORE_LOG="restore_$(date +%Y-%m-%d_%H-%M-%S).log"
log "=== QFieldCloud Wiederherstellung gestartet ==="

echo "Dieses Skript führt die Wiederherstellung aus einem Backup durch."
echo "Es ist konzipiert für einen *neuen Server* nach vorherigem Code-Checkout und Initialisierung."
echo ""
echo "Konfiguration:"
echo "  GeoDB Wiederherstellung: $RESTORE_GEODB"
echo "  Restore-Log: $RESTORE_LOG"
echo ""

# Prüfe Root-Rechte für kritische Operationen
if [ "$EUID" -ne 0 ]; then
    print_error "Dieses Skript MUSS mit 'sudo' ausgeführt werden, da es Docker-Volumes manipuliert. Bitte erneut starten mit: sudo $0"
fi
echo "✓ Root-Rechte erkannt (erforderlich für Volume-Operationen)"

# Prüfe Docker
print_step "SCHRITT 1: System-Voraussetzungen prüfen"
check_command "docker" "sudo apt install docker.io"
echo "✓ Docker gefunden: $(docker --version | head -n1)"

if ! docker compose version > /dev/null 2>&1; then
    print_error "Docker Compose Plugin nicht verfügbar! Installation: sudo apt install docker-compose-plugin"
fi
echo "✓ Docker Compose gefunden: $(docker compose version | head -n1)"

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
        print_error "rsync wird benötigt für Remote-Backup-Transfer! Installation: sudo apt install rsync"
    fi
    
    echo ""
    echo "=== Remote Backup-Transfer ==="
    echo ""
    read -r -p "Remote Server (user@host): " REMOTE_HOST
    read -r -p "Remote Backup-Pfad: " REMOTE_BACKUP_PATH
    
    echo ""
    echo "Übertrage Backup nach $TEMP_BACKUP_DIR ..."
    mkdir -p "$TEMP_BACKUP_DIR" || print_error "Konnte temporäres Verzeichnis nicht erstellen"
    
    if ! rsync -avz --progress "${REMOTE_HOST}:${REMOTE_BACKUP_PATH}/" "$TEMP_BACKUP_DIR/"; then
        print_error "rsync fehlgeschlagen! Überprüfen Sie Pfad und SSH-Zugriff."
    fi
    
    BACKUP_DIR="$TEMP_BACKUP_DIR"
    echo "✓ Backup erfolgreich übertragen"
    
else
    # Lokales Backup
    echo ""
    read -r -p "Lokaler Backup-Pfad: " LOCAL_BACKUP_PATH
    
    if [ ! -d "$LOCAL_BACKUP_PATH" ]; then
        print_error "Backup-Verzeichnis existiert nicht: $LOCAL_BACKUP_PATH"
    fi
    
    BACKUP_DIR=$(realpath "$LOCAL_BACKUP_PATH")
    echo "✓ Lokales Backup gefunden"
fi

log "Backup-Quelle: $BACKUP_DIR"

# =============================================================================
# BACKUP-INFORMATIONEN & CODE-PRÜFUNG
# =============================================================================
print_step "SCHRITT 3: Backup-Informationen auslesen"

echo "Backup-Quelle: $BACKUP_DIR"
echo "Backup-Name: $(basename "$BACKUP_DIR")"
echo ""

GEODB_IN_BACKUP=false
if [ -f "${BACKUP_DIR}/geodb_dump.sqlc" ] || [ -d "${BACKUP_DIR}/db_volumes/geodb_data" ]; then
    GEODB_IN_BACKUP=true
    log "ℹ GeoDB-Daten im Backup gefunden"
    if [ "$RESTORE_GEODB" = false ]; then
        echo "ℹ GeoDB wird NICHT wiederhergestellt (RESTORE_GEODB=false)"
    else
        echo "ℹ GeoDB WIRD wiederhergestellt (RESTORE_GEODB=true)"
    fi
fi

# Extrahiere Git Commit Info
BACKUP_COMMIT=""
BACKUP_REMOTE=""
if [ -f "${BACKUP_DIR}/backup.log" ]; then
    log "Lese Git-Informationen aus backup.log..."
    BACKUP_COMMIT=$(sed -n '/GIT COMMIT INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep "^commit" | awk '{print $2}' | head -n1)
    BACKUP_REMOTE=$(sed -n '/GIT REMOTE INFORMATION/,/^$/p' "${BACKUP_DIR}/backup.log" | grep "origin" | awk '{print $2}' | head -n1)
fi

if [ -n "$BACKUP_COMMIT" ]; then
    echo "Backup wurde mit Git Commit erstellt: $BACKUP_COMMIT"
else
    echo "WARNUNG: Kein Git Commit im Backup-Log gefunden - Kompatibilität unsicher!"
fi

# =============================================================================
# CODE-PRÜFUNG & VORBEREITUNG (FÜR NEUE SERVER)
# =============================================================================
print_step "SCHRITT 4: QFieldCloud Code & Konfiguration prüfen"

if [ ! -d ".git" ] || [ ! -f "docker-compose.yml" ] || [ ! -f ".env" ]; then
    echo "🚨 VORBEREITUNG ERFORDERLICH 🚨"
    echo "Das aktuelle Verzeichnis scheint keine vollständige QFieldCloud-Installation zu sein."
    echo ""
    echo "Bitte FÜHREN SIE VORHER MANUELL FOLGENDE SCHRITTE DURCH:"
    echo "1. **Code Klonen:**"
    if [ -n "$BACKUP_REMOTE" ]; then
        echo "   -> git clone $BACKUP_REMOTE QFieldCloud-Restore"
    else
        echo "   -> git clone [REPO URL] QFieldCloud-Restore"
    fi
    echo "   -> cd QFieldCloud-Restore"
    echo "2. **Konfiguration wiederherstellen:**"
    echo "   -> cp ${BACKUP_DIR}/config/.env ."
    echo "   -> cp ${BACKUP_DIR}/config/*.yml ."
    echo "3. **Code-Version anpassen (WICHTIG):**"
    if [ -n "$BACKUP_COMMIT" ]; then
        echo "   -> git fetch --all && git reset --hard $BACKUP_COMMIT"
    else
        echo "   -> WARNUNG: Kein Backup-Commit gefunden, bitte die korrekte Version manuell auschecken."
    fi
    echo "4. **Datenbanken initialisieren:**"
    echo "   -> docker compose up -d db minio # Nur um Volumes/DB-Dateien anzulegen"
    echo "   -> docker compose down"
    echo ""
    read -r -p "Haben Sie die oben genannten Schritte ausgeführt und sind im Code-Verzeichnis? (ja/nein): " CODE_MANUAL_READY
    
    if [ "$CODE_MANUAL_READY" != "ja" ]; then
        print_error "Abbruch. Bitte Code vorbereiten und erneut starten."
    fi
    
    # Prüfe nach Bestätigung nochmals
    if [ ! -f ".env" ]; then
        print_error "Die .env-Datei fehlt weiterhin im aktuellen Verzeichnis."
    fi
fi

echo "✓ QFieldCloud-Code-Verzeichnis (.git, .env, docker-compose.yml) gefunden."

# =============================================================================
# KONFIGURATIONSDATEIEN LADEN
# =============================================================================
print_step "SCHRITT 5: Konfiguration laden"

# Jetzt .env laden
source .env
# Setze Standardwerte falls in .env nicht gesetzt
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.override.standalone.yml}"
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}
MINIO_INTERNAL_PORT="${MINIO_API_PORT:-9000}"

echo "✓ .env geladen"
echo "  COMPOSE_PROJECT_NAME: $COMPOSE_PROJECT_NAME"
echo "  COMPOSE_FILE: $COMPOSE_FILE"

# Prüfe ob GeoDB Service existiert (benutze temporäre Variablen für config output)
GEODB_SERVICE_EXISTS=false
if COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" COMPOSE_FILE="$COMPOSE_FILE" docker compose config --services 2>/dev/null | grep -q "^geodb$"; then
    GEODB_SERVICE_EXISTS=true
    echo "✓ GeoDB Service in docker-compose gefunden"
else
    echo "ℹ GeoDB Service nicht in docker-compose gefunden"
fi

# Finale GeoDB Entscheidung
PROCESS_GEODB=false
if [ "$RESTORE_GEODB" = true ] && [ "$GEODB_SERVICE_EXISTS" = true ] && [ "$GEODB_IN_BACKUP" = true ]; then
    PROCESS_GEODB=true
    log "✓ GeoDB wird wiederhergestellt"
elif [ "$RESTORE_GEODB" = true ]; then
    log "⚠ GeoDB wird übersprungen, obwohl angefordert:"
    [ "$GEODB_SERVICE_EXISTS" = false ] && log "  - Service nicht definiert"
    [ "$GEODB_IN_BACKUP" = false ] && log "  - Keine Daten im Backup"
else
    log "ℹ GeoDB wird übersprungen (RESTORE_GEODB=false)"
fi

# =============================================================================
# FINALE BESTÄTIGUNG
# =============================================================================
print_header "BEREIT FÜR RESTORE"

echo "Zusammenfassung:"
echo "  • Backup: $(basename "$BACKUP_DIR")"
echo "  • Arbeitsverzeichnis: $(pwd)"
echo "  • Docker Projekt: $COMPOSE_PROJECT_NAME"
echo "  • GeoDB wiederherstellen: $PROCESS_GEODB"
[ -n "$BACKUP_COMMIT" ] && echo "  • Git Commit: $BACKUP_COMMIT"
echo ""
echo "⚠️  WARNUNG: Der Restore wird alle **Docker Volumes** und **Datenbanken** dieses Projekts **ÜBERSCHREIBEN**."
echo ""

read -r -p "Zum Fortfahren tippen Sie 'RESTORE JETZT' ein: " FINAL_CONFIRMATION

if [ "$FINAL_CONFIRMATION" != "RESTORE JETZT" ]; then
    print_error "Restore abgebrochen durch Benutzer."
fi

log "BESTÄTIGT. Führe Restore aus..."

# =============================================================================
# BACKUP-VALIDIERUNG
# =============================================================================
print_step "SCHRITT 6: Backup validieren"

DB_BACKUP_TYPE="unknown"
MINIO_BACKUP_TYPE="unknown"

# Datenbank-Backup-Typ
if [ -d "${BACKUP_DIR}/db_volumes/postgres_data" ]; then
    DB_BACKUP_TYPE="volume"
    log "Datenbank-Backup-Typ: Volume-basiert (cold backup)"
elif [ -f "${BACKUP_DIR}/db_dump.sqlc" ]; then
    DB_BACKUP_TYPE="dump"
    log "Datenbank-Backup-Typ: pg_dump-basiert (hot backup)"
else
    print_error "Keine gültigen Hauptdatenbank-Backups gefunden (weder Volume noch Dump)."
fi

# MinIO-Backup-Typ
if [ -d "${BACKUP_DIR}/minio_volumes/data1" ]; then
    MINIO_BACKUP_TYPE="volume"
    log "MinIO-Backup-Typ: Volume-basiert (full)"
elif [ -d "${BACKUP_DIR}/minio_project_files" ] || [ -d "${BACKUP_DIR}/minio_storage" ]; then
    MINIO_BACKUP_TYPE="mirror"
    log "MinIO-Backup-Typ: Mirror-basiert (incremental)"
else
    print_error "Keine MinIO-Daten im Backup gefunden (weder Volume noch Mirror)."
fi

# Checksum-Validierung
if [ -f "${BACKUP_DIR}/checksums.sha256" ]; then
    log "Validiere Checksums..."
    # Wichtig: sha256sum muss im Backup-Verzeichnis ausgeführt werden
    if (cd "${BACKUP_DIR}" && sha256sum -c checksums.sha256 > /dev/null 2>&1); then
        log "✓ Checksums erfolgreich validiert"
    else
        echo ""
        log "WARNUNG: Checksum-Validierung fehlgeschlagen! (Detail-Fehler im Log)"
        read -r -p "Trotzdem fortfahren? (ja/nein) " RESPONSE
        [[ "$RESPONSE" != "ja" ]] && print_error "Restore wegen fehlerhafter Checksum abgebrochen."
    fi
else
    log "WARNUNG: Keine Checksums gefunden - Integrität kann nicht geprüft werden."
fi

# =============================================================================
# DIENSTE HERUNTERFAHREN
# =============================================================================
print_step "SCHRITT 7: Services herunterfahren"
log "Fahre alle QFieldCloud-Dienste herunter..."
# Verwende -v um Volumes zu entfernen, die wir überschreiben wollen (nur wenn sie nicht in use sind)
docker compose down || true 2>&1 | tee -a "$RESTORE_LOG"
sleep 3
log "✓ Dienste gestoppt"

# =============================================================================
# MINIO-WIEDERHERSTELLUNG
# =============================================================================
print_step "SCHRITT 8: MinIO-Daten wiederherstellen"
log "=== MinIO-Wiederherstellung ==="

# Die Volume-Namen werden von docker compose automatisch erzeugt
# WICHTIG: Die Compose-Files müssen die Volumes definieren!
if [ "$MINIO_BACKUP_TYPE" = "volume" ]; then
    # VOLUME-BASIERTE WIEDERHERSTELLUNG
    log "Stelle MinIO-Volumes wieder her (volume-basiert)..."
    
    for i in 1 2 3 4; do
        VOLUME_NAME="${COMPOSE_PROJECT_NAME}_minio_data${i}"
        SOURCE_DIR="${BACKUP_DIR}/minio_volumes/data${i}"
        
        if [ ! -d "$SOURCE_DIR" ]; then
            log "WARNUNG: Überspringe data${i} (nicht im Backup: $SOURCE_DIR)"
            continue
        fi
        
        log "  -> Volume ${VOLUME_NAME} wiederherstellen..."
        
        # Sicherer Volume-Restore mit alpine-Container
        if ! docker run --rm \
            -v "${SOURCE_DIR}:/source_data:ro" \
            -v "${VOLUME_NAME}:/target_data" \
            alpine:latest \
            sh -c '
                # Lösche alte Daten (alle Dateien inklusive versteckte)
                rm -rf /target_data/* /target_data/.[!.]* 2>/dev/null || true
                # Kopiere neue Daten
                cp -a /source_data/. /target_data/
                if [ ! "$(ls -A /target_data)" ]; then
                    echo "ERROR: Ziel-Volume ist leer nach Kopie"
                    exit 1
                fi
            '; then
            print_error "MinIO Volume ${i} Wiederherstellung fehlgeschlagen"
        fi
        log "  -> Volume ${i} wiederhergestellt"
    done
    
else
    # MIRROR-BASIERTE WIEDERHERSTELLUNG
    log "Stelle MinIO-Daten wieder her (mirror-basiert via mc)..."
    log "Starte MinIO temporär für die Wiederherstellung..."
    
    # MinIO starten, um mc darauf zugreifen zu lassen
    if ! docker compose up -d minio 2>&1 | tee -a "$RESTORE_LOG"; then
        print_error "MinIO konnte nicht gestartet werden für Mirror-Restore"
    fi
    
    # Warte auf MinIO
    until docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1; do
        log "  -> Warte auf MinIO ($MINIO_INTERNAL_PORT)..."
        sleep 2
    done
    
    MINIO_HOST="minio:${MINIO_INTERNAL_PORT}"
    MINIO_ALIAS="qfieldcloudminio"
    
    # Nutze mc zum Spiegeln der Daten
    if ! docker run --rm \
        --network "${COMPOSE_PROJECT_NAME}_default" \
        -v "${BACKUP_DIR}:/backup:ro" \
        minio/mc \
        /bin/sh -c "
            mc alias set ${MINIO_ALIAS} http://${MINIO_HOST} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
            mc mirror --overwrite --remove /backup/minio_project_files ${MINIO_ALIAS}/qfieldcloud-project-files && \
            mc mirror --overwrite --remove /backup/minio_storage ${MINIO_ALIAS}/qfieldcloud-storage
        " 2>&1 | tee -a "$RESTORE_LOG" | grep -v "WARNING"; then
        print_error "MinIO Mirror-Wiederherstellung fehlgeschlagen (mc error)"
    fi
    
    log "Stoppe MinIO nach Mirror-Restore..."
    docker compose stop minio 2>&1 | tee -a "$RESTORE_LOG"
fi

log "MinIO-Wiederherstellung abgeschlossen"

# =============================================================================
# DATENBANK-WIEDERHERSTELLUNG
# =============================================================================
print_step "SCHRITT 9: Datenbanken wiederherstellen"
log "=== Datenbank-Wiederherstellung ==="

# Funktion: Datenbank-Restore mit pg_dump/pg_restore (nur für Dump-basierte Backups)
restore_database() {
    local SERVICE_NAME=$1
    local USER=$2
    local DB_NAME=$3
    local DUMP_FILE=$4
    
    if [ ! -f "$DUMP_FILE" ]; then
        log "WARNUNG: Dump-Datei fehlt für $DB_NAME ($DUMP_FILE). Überspringe."
        return 0
    fi
    
    log "Stelle Datenbank ${DB_NAME} aus Dump wieder her..."
    
    # Lösche/Erstelle Datenbank neu
    log "  -> Lösche alte Datenbank..."
    docker compose exec -T "$SERVICE_NAME" dropdb -U "$USER" "$DB_NAME" --if-exists 2>/dev/null || true
    log "  -> Erstelle neue Datenbank..."
    if ! docker compose exec -T "$SERVICE_NAME" createdb -U "$USER" "$DB_NAME"; then
        log "FEHLER: Datenbank-Erstellung fehlgeschlagen: $DB_NAME"
        return 1
    fi
    
    # Restore über STDIN
    log "  -> Importiere Daten..."
    if ! cat "$DUMP_FILE" | docker compose exec -i "$SERVICE_NAME" pg_restore -U "$USER" -d "$DB_NAME" --no-owner --no-acl 2>&1 | tee -a "$RESTORE_LOG" | grep -v "WARNING"; then
         log "WARNUNG: Einige Restore-Warnings aufgetreten (meist harmlos, siehe Log)"
    fi
    
    # Validiere Restore
    TABLE_COUNT=$(docker compose exec -T "$SERVICE_NAME" psql -U "$USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d ' ')
    
    if [ -z "$TABLE_COUNT" ] || [ "$TABLE_COUNT" -lt 5 ]; then # Mindestanzahl Tabellen prüfen
        log "FEHLER: Datenbank ${DB_NAME} scheint leer oder unvollständig zu sein (${TABLE_COUNT} Tabellen)"
        return 1
    fi
    
    log "  -> Datenbank ${DB_NAME} erfolgreich wiederhergestellt (${TABLE_COUNT} Tabellen)"
    return 0
}

# Starte benötigte DB-Services (immer, da Volume-Restore/Dump-Restore sie braucht)
log "Starte/prüfe Datenbankdienste..."
if [ "$PROCESS_GEODB" = true ]; then
    docker compose up -d db geodb 2>&1 | tee -a "$RESTORE_LOG" || print_error "DB-Dienste konnten nicht gestartet werden."
else
    docker compose up -d db 2>&1 | tee -a "$RESTORE_LOG" || print_error "Haupt-DB-Dienst konnte nicht gestartet werden."
fi

# Warte auf Datenbanken mit Timeout
TIMEOUT=120
ELAPSED=0

# Warte-Funktion
wait_for_db() {
    local SERVICE_NAME=$1
    local USER=$2
    local DB_TITLE=$3
    
    log "Warte auf ${DB_TITLE} ($SERVICE_NAME)..."
    ELAPSED=0
    while ! docker compose exec -T "$SERVICE_NAME" pg_isready -U "$USER" > /dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            print_error "${DB_TITLE}-Timeout nach ${TIMEOUT}s. Überprüfen Sie die Logs!"
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    log "✓ ${DB_TITLE} ist bereit"
}

wait_for_db "db" "$POSTGRES_USER" "Hauptdatenbank"
[ "$PROCESS_GEODB" = true ] && wait_for_db "geodb" "$GEODB_USER" "Geo-Datenbank"


if [ "$DB_BACKUP_TYPE" = "volume" ]; then
    # VOLUME-BASIERTE WIEDERHERSTELLUNG (von Cold Backup)
    log "Stelle DB-Volumes wieder her (Volume-Overwrite)..."
    
    # PostgreSQL Volume
    DB_VOLUME="${COMPOSE_PROJECT_NAME}_postgres_data"
    SOURCE_DIR="${BACKUP_DIR}/db_volumes/postgres_data"
    
    if [ -d "$SOURCE_DIR" ]; then
        log "  -> Stoppe Haupt-DB für Volume-Restore..."
        docker compose stop db 2>&1 | tee -a "$RESTORE_LOG"
        
        log "  -> Stelle PostgreSQL Volume wieder her..."
        if ! docker run --rm \
            -v "${SOURCE_DIR}:/source_data:ro" \
            -v "${DB_VOLUME}:/target_data" \
            alpine:latest \
            sh -c '
                rm -rf /target_data/* /target_data/.[!.]* 2>/dev/null || true
                cp -a /source_data/. /target_data/
                if [ ! "$(ls -A /target_data)" ]; then echo "ERROR: Ziel-Volume ist leer"; exit 1; fi
            '; then
            print_error "PostgreSQL Volume-Wiederherstellung fehlgeschlagen"
        fi
        
        log "  -> Starte Haupt-DB neu..."
        docker compose start db 2>&1 | tee -a "$RESTORE_LOG"
        wait_for_db "db" "$POSTGRES_USER" "Hauptdatenbank (Neustart)"
    else
        log "WARNUNG: PostgreSQL Volume nicht im Backup gefunden - überspringe."
    fi
    
    # GeoDB Volume (nur wenn aktiviert)
    if [ "$PROCESS_GEODB" = true ]; then
        GEODB_VOLUME="${COMPOSE_PROJECT_NAME}_geodb_data"
        SOURCE_DIR="${BACKUP_DIR}/db_volumes/geodb_data"
        
        if [ -d "$SOURCE_DIR" ]; then
            log "  -> Stoppe GeoDB für Volume-Restore..."
            docker compose stop geodb 2>&1 | tee -a "$RESTORE_LOG"
            
            log "  -> Stelle GeoDB Volume wieder her..."
            if ! docker run --rm \
                -v "${SOURCE_DIR}:/source_data:ro" \
                -v "${GEODB_VOLUME}:/target_data" \
                alpine:latest \
                sh -c '
                    rm -rf /target_data/* /target_data/.[!.]* 2>/dev/null || true
                    cp -a /source_data/. /target_data/
                    if [ ! "$(ls -A /target_data)" ]; then echo "ERROR: Ziel-Volume ist leer"; exit 1; fi
                '; then
                print_error "GeoDB Volume-Wiederherstellung fehlgeschlagen"
            fi
            
            log "  -> Starte GeoDB neu..."
            docker compose start geodb 2>&1 | tee -a "$RESTORE_LOG"
            wait_for_db "geodb" "$GEODB_USER" "Geo-Datenbank (Neustart)"
        else
            log "WARNUNG: GeoDB Volume nicht im Backup gefunden - überspringe."
        fi
    fi
    
else
    # DUMP-BASIERTE WIEDERHERSTELLUNG (von Hot Backup)
    log "Führe pg_restore aus (Dump-basiert)..."
    
    # Hauptdatenbank wiederherstellen
    if ! restore_database "db" "$POSTGRES_USER" "$POSTGRES_DB" "${BACKUP_DIR}/db_dump.sqlc"; then
        print_error "Hauptdatenbank-Wiederherstellung aus Dump fehlgeschlagen"
    fi
    
    # Geo-Datenbank wiederherstellen (nur wenn aktiviert)
    if [ "$PROCESS_GEODB" = true ]; then
        if ! restore_database "geodb" "$GEODB_USER" "$GEODB_DB" "${BACKUP_DIR}/geodb_dump.sqlc"; then
            print_error "Geo-Datenbank-Wiederherstellung aus Dump fehlgeschlagen"
        fi
    fi
fi

log "Datenbank-Wiederherstellung abgeschlossen"

# =============================================================================
# ALLE DIENSTE STARTEN
# =============================================================================
print_step "SCHRITT 10: Alle Services starten"
log "Starte alle QFieldCloud-Dienste..."
if ! docker compose up -d 2>&1 | tee -a "$RESTORE_LOG"; then
    log "FEHLER: Konnte nicht alle Dienste starten. Prüfen Sie Logs!"
fi

# Finaler Health-Check
log "Führe finalen Health-Check durch..."
sleep 5

HEALTHY=true

# DB Check
docker compose exec -T db pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1 || { log "WARNUNG: Hauptdatenbank antwortet nicht"; HEALTHY=false; }
[ "$PROCESS_GEODB" = true ] && docker compose exec -T geodb pg_isready -U "${GEODB_USER}" > /dev/null 2>&1 || { log "WARNUNG: Geo-Datenbank antwortet nicht"; HEALTHY=false; }

# MinIO Check
docker compose exec minio curl -sf http://localhost:${MINIO_INTERNAL_PORT}/minio/health/live > /dev/null 2>&1 || { log "WARNUNG: MinIO antwortet nicht"; HEALTHY=false; }

# =============================================================================
# ABSCHLUSS & CLEANUP
# =============================================================================
print_header "RESTORE ABGESCHLOSSEN"

# Cleanup temporäres Backup-Verzeichnis
if [ -n "$TEMP_BACKUP_DIR" ] && [ -d "$TEMP_BACKUP_DIR" ]; then
    log "Räume temporäres Backup-Verzeichnis auf: $TEMP_BACKUP_DIR"
    rm -rf "$TEMP_BACKUP_DIR"
    log "✓ Temporäre Dateien gelöscht"
fi

log ""
log "=== Wiederherstellung abgeschlossen ==="
log "Restore-Log: $RESTORE_LOG"

if [ "$HEALTHY" = true ]; then
    log "✅ ALLE DIENSTE SIND ERFOLGREICH GESTARTET UND ANTWORTEN KORREKT."
else
    log "⚠️ WARNUNG: Einige Dienste antworten nicht korrekt. Prüfen Sie die Logs!"
fi

echo ""
echo "=============================================================================="
echo "NÄCHSTE SCHRITTE"
echo "=============================================================================="
echo ""
echo "1. Überprüfen Sie die Services:"
echo "   ▶ docker compose ps"
echo ""
echo "2. Prüfen Sie die Logs auf Fehler:"
echo "   ▶ docker compose logs -f"
echo ""
echo "3. **Wichtig:** Führen Sie **Django-Datenbank-Migrationen** aus, falls Sie auf eine neuere Code-Version upgegradet haben:"
echo "   ▶ docker compose exec server python manage.py migrate"
echo ""
echo "4. Testen Sie die Anwendung gründlich:"
echo "   - Webinterface erreichbar?"
echo "   - Login und Datenzugriff funktioniert?"
echo ""

echo "Restore-Log gespeichert in: $RESTORE_LOG"
echo "=============================================================================="
echo ""

exit 0
