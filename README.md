> Work in progess DO NOT USE!

# QFieldCloud Backup & Restore Scripts

Production-ready backup and disaster recovery solution for self-hosted QFieldCloud instances running on Docker.

## Overview

This solution provides two complementary scripts:

- **backup.sh** - Automated backup with flexible strategies (full/incremental, hot/cold)
- **restore.sh** - Interactive disaster recovery with remote backup support

Both scripts are designed for reliable data protection and can handle complete disaster recovery scenarios, including migration to new servers.

## Features

### Backup Script

- **Flexible Backup Modes**
  - Full backups with volume-level copying
  - Incremental backups using MinIO's mc mirror
  - Cold backups (services stopped, maximum consistency)
  - Hot backups (services running, no downtime)

- **Comprehensive Data Protection**
  - PostgreSQL and PostGIS databases
  - MinIO object storage (all 4 volumes)
  - Configuration files (.env, docker-compose.yml)
  - SSL certificates (Certbot, Nginx)
  - Git version information

- **Safety Features**
  - Automatic backup rotation
  - SHA256 checksum generation
  - Disk space validation
  - Service health checks
  - Detailed logging

### Restore Script

- **Disaster Recovery Capabilities**
  - Interactive step-by-step wizard
  - Remote backup transfer via rsync
  - Automatic Git repository cloning
  - Checkout to backup commit version
  - Configuration file management

- **Flexibility**
  - Works on completely new servers
  - Supports both local and remote backups
  - Automatic backup type detection
  - Service health validation
  - Comprehensive restore logging

## Prerequisites

### Backup Server

- Docker and Docker Compose
- Bash shell
- Sufficient disk space for backups
- Optional: Git (for version tracking)

### Restore Server

- Docker and Docker Compose
- Bash shell
- Optional: rsync (for remote backup transfer)
- Optional: Git (for code restoration)

## Installation

1. Download the scripts to your QFieldCloud directory:

```bash
cd /path/to/QFieldCloud
wget https://raw.githubusercontent.com/your-repo/backup.sh
wget https://raw.githubusercontent.com/your-repo/restore.sh
chmod +x backup.sh restore.sh
```

2. Configure backup directory in `backup.sh`:

```bash
BACKUP_HOST_DIR="/mnt/qfieldcloud_backups"  # Adjust as needed
MAX_BACKUPS_TO_KEEP=7                        # Retention policy
REQUIRED_SPACE_GB=10                         # Minimum free space
```

3. Ensure your .env file contains the COMPOSE_FILE variable:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.override.standalone.yml
```

## Usage

### Creating Backups

#### Full Cold Backup (Recommended for Production)

Maximum data consistency, services are stopped during backup:

```bash
./backup.sh full --cold
```

This creates a backup at:
```
/mnt/qfieldcloud_backups/2025-10-14_03-00-00_full_cold/
```

#### Full Hot Backup

Services continue running, faster but less consistent:

```bash
./backup.sh full --hot
```

#### Incremental Backup

Fast backup using MinIO mirror, services running:

```bash
./backup.sh incremental
```

### Restoring from Backup

#### Interactive Disaster Recovery

Simply run the restore script and follow the wizard:

```bash
./restore.sh
```

The wizard will guide you through:

1. System prerequisites check
2. Backup source selection (local or remote)
3. Backup information display
4. Code restoration (Git clone/checkout)
5. Configuration preparation
6. Confirmation and execution

#### Direct Restore (Local Backup)

If you already have the backup locally:

```bash
./restore.sh /mnt/qfieldcloud_backups/2025-10-14_03-00-00_full_cold
```

Note: The interactive wizard is recommended for disaster recovery scenarios.

## Backup Directory Structure

```
/mnt/qfieldcloud_backups/
├── 2025-10-14_03-00-00_full_cold/
│   ├── backup.log                    # Detailed backup log with Git info
│   ├── checksums.sha256              # File integrity checksums
│   ├── config/
│   │   ├── .env                      # Environment configuration
│   │   ├── docker-compose.yml        # Docker Compose files
│   │   ├── docker-compose.override.standalone.yml
│   │   ├── certbot/                  # SSL certificates
│   │   └── nginx_certs/              # Nginx certificates
│   ├── db_volumes/                   # Database volumes (cold backup)
│   │   ├── postgres_data/
│   │   └── geodb_data/
│   └── minio_volumes/                # MinIO data volumes
│       ├── data1/
│       ├── data2/
│       ├── data3/
│       └── data4/
│
└── 2025-10-14_14-00-00_incremental_hot/
    ├── backup.log
    ├── checksums.sha256
    ├── config/
    ├── db_dump.sqlc              # PostgreSQL dump (hot backup)
    ├── geodb_dump.sqlc           # GeoDB dump (hot backup)
    ├── minio_project_files/      # MinIO mirror backup
    ├── minio_storage/
    └── minio_bucket_list.txt
```

## Backup Strategies

### Recommended Production Strategy

```bash
# Daily at 2 AM: Incremental (fast, no downtime)
0 2 * * * cd /opt/QFieldCloud && ./backup.sh incremental >> /var/log/qfield-backup.log 2>&1

# Weekly on Sunday at 3 AM: Full Cold (maximum consistency)
0 3 * * 0 cd /opt/QFieldCloud && ./backup.sh full --cold >> /var/log/qfield-backup.log 2>&1
```

### Development Strategy

```bash
# Daily at 2 AM: Full Hot (fast, no downtime needed)
0 2 * * * cd /opt/QFieldCloud && ./backup.sh full --hot >> /var/log/qfield-backup.log 2>&1
```

## Backup Modes Comparison

| Feature | Full Cold | Full Hot | Incremental |
|---------|-----------|----------|-------------|
| **Services** | Stopped | Running | Running |
| **Consistency** | Maximum | Medium | Medium |
| **Database Method** | Volume copy | pg_dump | pg_dump |
| **MinIO Method** | Volume copy | Volume copy | mc mirror |
| **Downtime** | 2-5 minutes | None | None |
| **Speed** | Slow | Medium | Fast |
| **Size** | Large | Large | Small |
| **Best For** | Production weekly | Development | Daily backups |

## Disaster Recovery Scenarios

### Scenario 1: Complete Server Failure

**Situation:** Your server crashed and you need to restore to a new server.

**Steps:**

1. Install Docker on new server
2. Copy restore.sh to new server
3. Run restore script:
   ```bash
   ./restore.sh
   ```
4. Follow wizard:
   - Select "Remote Server" for backup source
   - Enter old server details for rsync
   - Choose "Clone Repository" for code
   - Script will checkout exact backup commit
   - Confirm restore

**Result:** Complete QFieldCloud instance restored with exact code version and data.

### Scenario 2: Data Corruption

**Situation:** Database or MinIO data corrupted, need to restore from backup.

**Steps:**

```bash
# Stop services
docker compose down

# Run restore with local backup
./restore.sh /mnt/qfieldcloud_backups/2025-10-14_03-00-00_full_cold

# Follow prompts, confirm restore
```

### Scenario 3: Migration to New Server

**Situation:** Moving QFieldCloud to a new server with different hostname.

**Steps:**

1. Create backup on old server:
   ```bash
   ./backup.sh full --cold
   ```

2. On new server, run restore:
   ```bash
   ./restore.sh
   ```

3. Select "Remote Server" and provide old server details

4. After restore, update configuration:
   ```bash
   # Edit .env with new hostname
   vim .env
   
   # Update QFIELDCLOUD_HOST
   # Update SSL certificates if needed
   
   # Restart services
   docker compose down
   docker compose up -d
   ```

## Monitoring and Maintenance

### Check Backup Status

```bash
# List all backups sorted by date
ls -lht /mnt/qfieldcloud_backups/

# Check latest backup log
tail -f /mnt/qfieldcloud_backups/2025-10-14_*/backup.log

# Verify backup integrity
cd /mnt/qfieldcloud_backups/2025-10-14_03-00-00_full_cold/
sha256sum -c checksums.sha256
```

### Disk Space Monitoring

```bash
# Check backup directory size
du -sh /mnt/qfieldcloud_backups/

# Check available space
df -h /mnt/qfieldcloud_backups/
```

### Test Restore Procedure

Regularly test your backups:

```bash
# Create test environment
mkdir /tmp/qfield-restore-test
cd /tmp/qfield-restore-test

# Run restore to test environment
/path/to/restore.sh /mnt/qfieldcloud_backups/latest-backup/

# Verify services start correctly
docker compose ps
docker compose logs
```

## Troubleshooting

### Backup Fails with "Out of Space"

**Solution:** Increase `REQUIRED_SPACE_GB` or free up disk space before backup.

```bash
# Clean old backups manually
rm -rf /mnt/qfieldcloud_backups/oldest-backup-folder/

# Or reduce retention
# Edit backup.sh: MAX_BACKUPS_TO_KEEP=5
```

### Restore Fails at Database Step

**Problem:** Database restore reports errors.

**Solution:**

```bash
# Check if databases are running
docker compose ps

# Check database logs
docker compose logs db
docker compose logs geodb

# Retry restore from clean state
docker compose down -v  # WARNING: Deletes all volumes
./restore.sh /path/to/backup/
```

### MinIO Data Incomplete After Restore

**Problem:** Some MinIO files missing after restore.

**Solution:** Ensure backup type matches restore expectations:

- For volume-based backups: Check all 4 volumes exist in backup
- For mirror-based backups: Verify minio_project_files and minio_storage folders exist

### Git Checkout Fails During Restore

**Problem:** Cannot checkout to backup commit.

**Solution:**

```bash
# Clone repository manually
git clone https://github.com/opengisch/QFieldCloud.git
cd QFieldCloud

# Checkout to commit from backup log
git checkout <commit-hash>

# Run restore again
./restore.sh /path/to/backup/
```

## Security Considerations

### Backup Storage

- Store backups on separate physical storage
- Use encrypted filesystems for sensitive data
- Implement access controls on backup directory
- Consider off-site backup replication

### Sensitive Information

Backups contain:
- Database credentials (.env file)
- API keys and secrets
- SSL private keys
- User data

Ensure appropriate security measures:

```bash
# Restrict backup directory access
chmod 700 /mnt/qfieldcloud_backups
chown root:root /mnt/qfieldcloud_backups

# Encrypt backups for transfer
tar czf - backup-folder/ | gpg -c > backup.tar.gz.gpg

# Use SSH keys for rsync (no password in scripts)
ssh-keygen -t ed25519
ssh-copy-id backup@remote-server
```

## Performance Optimization

### Large Deployments

For QFieldCloud instances with large amounts of data:

1. **Use incremental backups daily:**
   ```bash
   ./backup.sh incremental
   ```

2. **Schedule full backups during low-usage periods:**
   ```bash
   # Sunday 3 AM when traffic is low
   0 3 * * 0 ./backup.sh full --cold
   ```

3. **Consider backup compression:**
   ```bash
   # Add to cron after backup
   0 4 * * 0 tar czf backup.tar.gz /mnt/qfieldcloud_backups/latest/ && rm -rf /mnt/qfieldcloud_backups/latest/
   ```

### Network Transfer

For remote restores over slow networks:

```bash
# Use compression with rsync
rsync -avz --compress-level=9 user@host:/backup/ ./local-backup/

# Or use bandwidth limiting
rsync -avz --bwlimit=1000 user@host:/backup/ ./local-backup/
```

## Contributing

Contributions are welcome! Please ensure:

- Scripts remain POSIX-compliant
- Error handling is comprehensive
- User prompts are clear and informative
- Changes are documented in README

## License

MIT License - see LICENSE file for details

## Support

For issues, questions, or contributions:
- GitHub Issues: [your-repo/issues]
- QFieldCloud Docs: https://docs.qfield.org/

## Changelog

### Version 1.0.0 (2025-10-14)

- Initial release
- Full and incremental backup modes
- Hot and cold backup options
- Interactive disaster recovery wizard
- Remote backup transfer support
- Git version tracking and restoration
- Automatic service health checks
- SHA256 checksum verification
- Comprehensive logging
