#!/bin/bash

# ============================================================================
# PostgreSQL Database Restore Script with SHA-256 Checksum Integrity Validation
# ============================================================================
#
# Description:
#   Restores PostgreSQL database from backups (S3 or local).
#   Validates SHA-256 integrity checksum using sha256sum -c before restoring.
#   Aborts immediately with non-zero exit code if checksum verification fails.
#   Downloads encrypted backup and checksum from S3 if needed.
#   Decrypts and decompresses backup.
#   Restores data into specified database.
#   Validates schema after restore.
#
# Requirements:
#   - PostgreSQL client tools (psql, pg_restore)
#   - sha256sum for checksum verification
#   - OpenSSL for decryption (for encrypted backups)
#   - AWS CLI v2 configured with credentials (for S3 restores)
#
# Usage:
#   ./scripts/restore-db.sh --backup-file /path/to/backup.sql.gz.enc [--target-db restore_test]
#   ./scripts/restore-db.sh [--backup-timestamp 20240101_020000] [--target-db restore_test]
#   ./scripts/restore-db.sh --list                              # List available backups
#   ./scripts/restore-db.sh --latest [--target-db restore_test] # Restore latest backup
#
# Exit Codes:
#   0 - Success
#   1 - Configuration/argument error
#   2 - S3 download failed
#   3 - Decryption failed
#   4 - Decompression failed
#   5 - Restore failed
#   6 - Validation failed
#   7 - Checksum verification failed
#
# ============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────

# Load environment variables if .env file exists
if [[ -f "$(dirname "$0")/../.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/../.env"
fi

# Database configuration
DATABASE_URL="${DATABASE_URL:-postgresql://bankerchanger:bankerchanger@localhost:5432/bankerchanger}"
DB_NAME="${DB_NAME:-bankerchanger}"
TARGET_DB="${DB_NAME}_restore"

# S3 configuration
S3_BUCKET="${AWS_S3_BACKUP_BUCKET:-}"
S3_PREFIX="${S3_BACKUP_PREFIX:-db-backups}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Encryption configuration
ENCRYPTION_CIPHER="aes-256-cbc"
ENCRYPTION_KEY_FILE="${BACKUP_ENCRYPTION_KEY_FILE:-}"

# Temporary directory for restore files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Logging
LOG_DIR="${LOG_DIR:-/var/log/backups}"
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
  LOG_DIR="${TMPDIR:-/tmp}/backups"
  mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="."
fi
LOG_FILE="${LOG_DIR}/restore-$(date +%Y%m%d_%H%M%S).log"

# ── Functions ─────────────────────────────────────────────────────────────

log_info() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

print_usage() {
  cat <<EOF
PostgreSQL Restore Script with Checksum Validation

USAGE:
  $(basename "$0") [OPTIONS]

OPTIONS:
  --backup-file <FILE>, --file <FILE>
                                  Restore from local backup file
  --checksum-file <FILE>          Path to .sha256 checksum file (default: <backup-file>.sha256)
  --backup-timestamp <TIMESTAMP>  Restore specific backup from S3 (format: YYYYMMDD_HHMMSS)
  --latest                        Restore the most recent backup from S3
  --list                          List available backups in S3
  --target-db <DATABASE>          Target database name (default: ${DB_NAME}_restore)
  --help                          Show this help message

EXAMPLES:
  # Restore local backup with automatic checksum verification
  $(basename "$0") --backup-file /backups/bankerchanger_20260101.sql.gz.enc

  # Restore latest backup from S3
  $(basename "$0") --latest

  # Restore specific backup from S3
  $(basename "$0") --backup-timestamp 20260115_020000

  # Restore to custom database
  $(basename "$0") --backup-file backup.sql --target-db my_test_db

EOF
}

validate_config() {
  local backup_file="${1:-}"
  local errors=0

  # Ensure log directory exists (fallback to /tmp if permission denied)
  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOG_DIR="/tmp/backups"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/restore-$(date +%Y%m%d_%H%M%S).log"
  fi

  # Validate required checksum tool
  if ! command -v sha256sum &> /dev/null; then
    log_error "Required tool not found: sha256sum"
    ((errors++))
  fi

  # If restoring from S3, validate S3 configuration
  if [[ -z "$backup_file" ]]; then
    if [[ -z "$S3_BUCKET" ]]; then
      log_error "AWS_S3_BACKUP_BUCKET environment variable not set"
      ((errors++))
    fi

    if ! command -v aws &> /dev/null; then
      log_error "Required tool not found: aws"
      ((errors++))
    fi
  fi

  # Validate encryption key only if encrypted backup is used
  if [[ -z "$backup_file" ]] || [[ "$backup_file" == *.enc ]]; then
    if [[ -z "$ENCRYPTION_KEY_FILE" ]] || [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
      log_error "BACKUP_ENCRYPTION_KEY_FILE not set or file does not exist: $ENCRYPTION_KEY_FILE"
      ((errors++))
    fi

    if ! command -v openssl &> /dev/null; then
      log_error "Required tool not found: openssl"
      ((errors++))
    fi
  fi

  # Validate database client tools
  if ! command -v psql &> /dev/null && ! command -v pg_restore &> /dev/null; then
    log_error "Neither psql nor pg_restore found on PATH"
    ((errors++))
  fi

  if [[ $errors -gt 0 ]]; then
    log_error "Configuration validation failed with $errors error(s)"
    return 1
  fi

  return 0
}

list_backups() {
  log_info "Available backups in S3:"
  log_info "Listing: s3://${S3_BUCKET}/${S3_PREFIX}/"

  aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
    --region "$AWS_REGION" \
    --human-readable \
    --recursive | \
    awk '{print $1 " " $2 " " $3 " " $4}' | \
    tee -a "$LOG_FILE"
}

get_latest_backup() {
  log_info "Finding latest backup..."

  local latest_backup
  latest_backup=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
    --region "$AWS_REGION" \
    --recursive | \
    grep '\.enc$' | \
    sort | \
    tail -1 | \
    awk '{print $4}')

  if [[ -z "$latest_backup" ]]; then
    log_error "No backups found in S3"
    return 1
  fi

  echo "$latest_backup"
}

download_backup() {
  local s3_path="$1"
  local local_file="$2"

  log_info "Downloading from S3: s3://${S3_BUCKET}/${s3_path}"

  if aws s3 cp "s3://${S3_BUCKET}/${s3_path}" "$local_file" \
    --region "$AWS_REGION" 2>> "$LOG_FILE"; then
    log_info "Download completed: $local_file"
    log_info "File size: $(du -h "$local_file" | cut -f1)"
    return 0
  else
    log_error "S3 download failed for s3://${S3_BUCKET}/${s3_path}"
    return 2
  fi
}

verify_checksum() {
  local target_file="$1"
  local checksum_file="${2:-${target_file}.sha256}"

  log_info "Validating SHA-256 integrity checksum for: $target_file"
  log_info "Checksum file: $checksum_file"

  if [[ ! -f "$checksum_file" ]]; then
    log_error "Checksum verification failed: checksum file not found: $checksum_file"
    return 7
  fi

  if [[ ! -f "$target_file" ]]; then
    log_error "Checksum verification failed: backup file not found: $target_file"
    return 7
  fi

  local target_dir checksum_basename target_basename
  target_dir=$(cd "$(dirname "$target_file")" && pwd)
  checksum_basename=$(basename "$checksum_file")
  target_basename=$(basename "$target_file")

  local filename_in_checksum
  filename_in_checksum=$(awk '{print $2}' "$checksum_file" | sed 's/^\*//' | tr -d '\r\n')

  local verified=false

  # If filename in checksum file matches target file, run sha256sum -c on the file
  if [[ -n "$filename_in_checksum" ]] && [[ "$filename_in_checksum" == "$target_basename" || "$filename_in_checksum" == "$target_file" ]]; then
    if (cd "$target_dir" && sha256sum -c "$checksum_basename" >> "$LOG_FILE" 2>&1); then
      verified=true
    fi
  else
    # Verify using sha256sum -c via stdin mapping expected hash to target_basename
    local expected_hash
    expected_hash=$(awk '{print $1}' "$checksum_file" | tr -d '\r\n')
    if [[ -n "$expected_hash" ]]; then
      if (cd "$target_dir" && echo "${expected_hash}  ${target_basename}" | sha256sum -c - >> "$LOG_FILE" 2>&1); then
        verified=true
      fi
    fi
  fi

  if [[ "$verified" == true ]]; then
    log_info "Checksum verification PASSED: SHA-256 integrity confirmed"
    return 0
  else
    log_error "Checksum verification FAILED: backup file is corrupted or has been tampered with!"
    return 7
  fi
}

decrypt_backup() {
  local encrypted_file="$1"
  local decompressed_file="$2"

  log_info "Decrypting and decompressing backup..."

  if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
    log_error "Encryption key file not found: $ENCRYPTION_KEY_FILE"
    return 3
  fi

  local encryption_key
  encryption_key=$(cat "$ENCRYPTION_KEY_FILE")

  # Decompress and decrypt in one pass
  if echo -n "$encryption_key" | openssl enc \
    -"$ENCRYPTION_CIPHER" \
    -d \
    -in "$encrypted_file" \
    -pass stdin 2>> "$LOG_FILE" | gunzip > "$decompressed_file"; then
    
    log_info "Decryption and decompression completed"
    return 0
  else
    log_error "Decryption failed"
    return 3
  fi
}

create_target_database() {
  local target_db="$1"

  log_info "Preparing target database: $target_db"

  if ! command -v psql &> /dev/null; then
    log_warn "psql not available; skipping database recreation step"
    return 0
  fi

  # Drop existing database if it exists
  if psql "$DATABASE_URL" -tc "SELECT 1 FROM pg_database WHERE datname = '$target_db'" 2>/dev/null | grep -q 1; then
    log_warn "Target database already exists: $target_db"
    log_warn "Dropping existing database..."
    psql "$DATABASE_URL" -c "DROP DATABASE IF EXISTS $target_db;" 2>> "$LOG_FILE" || true
  fi

  # Create new database
  if psql "$DATABASE_URL" -c "CREATE DATABASE $target_db;" 2>> "$LOG_FILE"; then
    log_info "Database created successfully: $target_db"
    return 0
  else
    log_error "Failed to create database: $target_db"
    return 5
  fi
}

restore_database() {
  local sql_file="$1"
  local target_db="$2"

  log_info "Restoring database into: $target_db"

  # Build connection string for target database
  local target_url
  target_url=$(echo "$DATABASE_URL" | sed "s|/[^/]*$|/$target_db|")

  # Check if binary pg_restore dump format
  if head -c 5 "$sql_file" 2>/dev/null | grep -q "PGDMP"; then
    log_info "Detected PostgreSQL custom dump format, executing pg_restore..."
    if pg_restore --clean --if-exists --no-owner --no-privileges -d "$target_url" "$sql_file" 2>> "$LOG_FILE"; then
      log_info "Database restore completed successfully via pg_restore"
      return 0
    else
      log_error "pg_restore failed for database $target_db"
      return 5
    fi
  else
    # Plain SQL restore via psql
    log_info "Executing plain SQL dump restore via psql..."
    if psql "$target_url" < "$sql_file" 2>> "$LOG_FILE"; then
      log_info "Database restore completed successfully via psql"
      return 0
    else
      log_error "Database restore failed for database $target_db"
      return 5
    fi
  fi
}

validate_restore() {
  local target_db="$1"

  log_info "Validating restored database: $target_db"

  if ! command -v psql &> /dev/null; then
    log_warn "psql not installed; skipping post-restore schema validation"
    return 0
  fi

  local target_url
  target_url=$(echo "$DATABASE_URL" | sed "s|/[^/]*$|/$target_db|")

  # Check tables exist
  local table_count
  table_count=$(psql "$target_url" -tc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>> "$LOG_FILE" | tr -d ' ' || echo "0")

  if [[ -z "$table_count" ]] || [[ "$table_count" -lt 1 ]]; then
    log_error "Database validation failed: no tables found in database $target_db"
    return 6
  fi

  log_info "Validation passed: $table_count tables found"
  return 0
}

# ── Main Execution ────────────────────────────────────────────────────────

main() {
  local backup_timestamp=""
  local use_latest=false
  local list_only=false
  local backup_file=""
  local checksum_file=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup-file|--file)
        backup_file="$2"
        shift 2
        ;;
      --checksum-file)
        checksum_file="$2"
        shift 2
        ;;
      --backup-timestamp)
        backup_timestamp="$2"
        shift 2
        ;;
      --latest)
        use_latest=true
        shift
        ;;
      --list)
        list_only=true
        shift
        ;;
      --target-db)
        TARGET_DB="$2"
        shift 2
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        print_usage
        exit 1
        ;;
    esac
  done

  log_info "════════════════════════════════════════════════════════════"
  log_info "PostgreSQL Restore Process Started"
  log_info "════════════════════════════════════════════════════════════"

  # Validate configuration
  if ! validate_config "$backup_file"; then
    exit 1
  fi

  # List backups and exit
  if [[ "$list_only" == true ]]; then
    list_backups
    exit 0
  fi

  # ── Restore Flow: Local File ──────────────────────────────────────────────
  if [[ -n "$backup_file" ]]; then
    if [[ ! -f "$backup_file" ]]; then
      log_error "Specified backup file not found: $backup_file"
      exit 1
    fi

    # Mandatory Checksum Validation: Abort immediately on failure
    if ! verify_checksum "$backup_file" "$checksum_file"; then
      log_error "Integrity check failed: refusing to restore corrupted or untrusted backup"
      exit 7
    fi

    local restore_sql=""
    if [[ "$backup_file" == *.enc ]]; then
      restore_sql="$TEMP_DIR/restored.sql"
      if ! decrypt_backup "$backup_file" "$restore_sql"; then
        exit 3
      fi
    elif [[ "$backup_file" == *.gz ]]; then
      restore_sql="$TEMP_DIR/restored.sql"
      gunzip -c "$backup_file" > "$restore_sql"
    else
      restore_sql="$backup_file"
    fi

    # Create target database
    if ! create_target_database "$TARGET_DB"; then
      exit 5
    fi

    # Restore database
    if ! restore_database "$restore_sql" "$TARGET_DB"; then
      exit 5
    fi

    # Validate restore
    if ! validate_restore "$TARGET_DB"; then
      exit 6
    fi

    log_info "════════════════════════════════════════════════════════════"
    log_info "Restore Process Completed Successfully from $backup_file"
    log_info "Database: $TARGET_DB"
    log_info "════════════════════════════════════════════════════════════"
    exit 0
  fi

  # ── Restore Flow: S3 Backup ───────────────────────────────────────────────
  if [[ "$use_latest" == true ]]; then
    local latest_key
    latest_key=$(get_latest_backup || echo "")
    backup_timestamp=$(echo "$latest_key" | grep -oP '\d{8}_\d{6}' || echo "")
    if [[ -z "$backup_timestamp" ]]; then
      log_error "Failed to determine latest backup timestamp"
      exit 1
    fi
    log_info "Using latest backup: $backup_timestamp"
  elif [[ -z "$backup_timestamp" ]]; then
    log_error "No backup specified. Use --backup-file, --latest, or --backup-timestamp"
    print_usage
    exit 1
  fi

  # Prepare file paths
  local backup_path="${S3_PREFIX}/${DB_NAME}_${backup_timestamp}.sql.gz.enc"
  local encrypted_file="$TEMP_DIR/${DB_NAME}_${backup_timestamp}.sql.gz.enc"
  local checksum_s3_path="${backup_path}.sha256"
  local local_checksum_file="${encrypted_file}.sha256"
  local sql_file="$TEMP_DIR/${DB_NAME}_${backup_timestamp}.sql"

  # Download backup
  if ! download_backup "$backup_path" "$encrypted_file"; then
    exit 2
  fi

  # Download checksum
  if ! download_backup "$checksum_s3_path" "$local_checksum_file"; then
    log_error "Failed to download SHA-256 checksum from S3: $checksum_s3_path"
    exit 2
  fi

  # Mandatory Checksum Validation: Abort immediately on failure
  if ! verify_checksum "$encrypted_file" "$local_checksum_file"; then
    log_error "Integrity check failed: downloaded backup is corrupted or tampered"
    exit 7
  fi

  # Decrypt backup
  if ! decrypt_backup "$encrypted_file" "$sql_file"; then
    exit 3
  fi

  # Create target database
  if ! create_target_database "$TARGET_DB"; then
    exit 5
  fi

  # Restore database
  if ! restore_database "$sql_file" "$TARGET_DB"; then
    exit 5
  fi

  # Validate restore
  if ! validate_restore "$TARGET_DB"; then
    exit 6
  fi

  log_info "════════════════════════════════════════════════════════════"
  log_info "Restore Process Completed Successfully"
  log_info "Database: $TARGET_DB"
  log_info "════════════════════════════════════════════════════════════"
  exit 0
}

# Execute main function
main "$@"
