#!/bin/bash

# ============================================================================
# Test Suite: Database Restore SHA-256 Checksum Integrity Verification (#958)
# ============================================================================
#
# Verifies:
# 1. restore-db.sh rejects corrupted backup files where data was altered
# 2. restore-db.sh aborts with exit code 7 on checksum mismatch
# 3. restore-db.sh aborts with non-zero exit code when checksum file is missing
# 4. restore-db.sh validates sha256sum -c successfully on intact backup files
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/restore-db.sh"
BACKUP_SCRIPT="$SCRIPT_DIR/backup-db.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

FAILED_TESTS=0
TOTAL_TESTS=0

pass() {
  echo "  ✓ PASS: $1"
}

fail() {
  echo "  ✗ FAIL: $1"
  FAILED_TESTS=$((FAILED_TESTS + 1))
}

run_test() {
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  echo "[Test $TOTAL_TESTS] $1"
}

echo "════════════════════════════════════════════════════════════"
echo "Running Database Restore Checksum Validation Tests (#958)"
echo "════════════════════════════════════════════════════════════"

# Setup test fixtures
VALID_BACKUP="$TEST_DIR/valid_backup.sql"
VALID_CHECKSUM="$TEST_DIR/valid_backup.sql.sha256"
cat <<'EOF' > "$VALID_BACKUP"
-- Sample valid database dump
CREATE TABLE IF NOT EXISTS test_users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL
);
INSERT INTO test_users (username) VALUES ('alice'), ('bob');
EOF

# Generate valid checksum using sha256sum in test directory
(cd "$TEST_DIR" && sha256sum "valid_backup.sql" > "valid_backup.sql.sha256")

# Test 1: Corrupted backup must be rejected with exit code 7
run_test "Rejects corrupted backup when content is altered"
CORRUPTED_BACKUP="$TEST_DIR/corrupted_backup.sql"
CORRUPTED_CHECKSUM="$TEST_DIR/corrupted_backup.sql.sha256"
cp "$VALID_BACKUP" "$CORRUPTED_BACKUP"
# Generate valid checksum for the uncorrupted file
(cd "$TEST_DIR" && sha256sum "corrupted_backup.sql" > "corrupted_backup.sql.sha256")
# Now tamper with the backup file (simulate corruption or malicious SQL injection dump)
echo "-- MALICIOUS INJECTION: DROP TABLE users;" >> "$CORRUPTED_BACKUP"

set +e
bash "$RESTORE_SCRIPT" --backup-file "$CORRUPTED_BACKUP" > "$TEST_DIR/corrupt.log" 2>&1
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 7 ]]; then
  pass "restore-db.sh exited with code 7 (checksum failure)"
else
  fail "Expected exit code 7 for corrupted backup, got $EXIT_CODE"
fi

if grep -qi "checksum verification failed" "$TEST_DIR/corrupt.log"; then
  pass "Logged checksum verification failure message"
else
  fail "Missing failure log in output"
fi

# Test 2: Missing checksum file must be rejected with exit code 7
run_test "Rejects backup when .sha256 checksum file is missing"
NO_CHECKSUM_BACKUP="$TEST_DIR/no_checksum_backup.sql"
cp "$VALID_BACKUP" "$NO_CHECKSUM_BACKUP"
rm -f "${NO_CHECKSUM_BACKUP}.sha256"

set +e
bash "$RESTORE_SCRIPT" --backup-file "$NO_CHECKSUM_BACKUP" > "$TEST_DIR/missing.log" 2>&1
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 7 ]]; then
  pass "restore-db.sh rejected backup without checksum with exit code 7"
else
  fail "Expected exit code 7 when checksum file missing, got $EXIT_CODE"
fi

if grep -qi "checksum file not found" "$TEST_DIR/missing.log"; then
  pass "Logged missing checksum file message"
else
  fail "Missing 'checksum file not found' log in output"
fi

# Test 3: Checksum mismatch with custom checksum file must be rejected
run_test "Rejects backup when explicit --checksum-file fails verification"
FAKE_CHECKSUM="$TEST_DIR/fake.sha256"
echo "0000000000000000000000000000000000000000000000000000000000000000  valid_backup.sql" > "$FAKE_CHECKSUM"

set +e
bash "$RESTORE_SCRIPT" --backup-file "$VALID_BACKUP" --checksum-file "$FAKE_CHECKSUM" > "$TEST_DIR/fake.log" 2>&1
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 7 ]]; then
  pass "restore-db.sh rejected mismatching custom checksum with exit code 7"
else
  fail "Expected exit code 7 for custom checksum mismatch, got $EXIT_CODE"
fi

# Test 4: Valid backup passes checksum verification
run_test "Valid backup and checksum pass integrity verification"
set +e
# Use dummy/offline database URL so psql connection failure occurs only AFTER checksum validation
DATABASE_URL="postgresql://invalid:invalid@127.0.0.1:54329/nonexistent" \
  bash "$RESTORE_SCRIPT" --backup-file "$VALID_BACKUP" > "$TEST_DIR/valid.log" 2>&1
EXIT_CODE=$?
set -e

# It will fail at database connection (exit code 5) or pass, but NOT fail at checksum (exit code 7)
if [[ $EXIT_CODE -ne 7 ]]; then
  pass "Passed SHA-256 verification (did not exit with checksum error code 7)"
else
  fail "Valid backup incorrectly failed checksum verification"
fi

if grep -qi "checksum verification passed" "$TEST_DIR/valid.log"; then
  pass "Logged 'Checksum verification PASSED'"
else
  fail "Missing 'Checksum verification PASSED' log in output"
fi

echo "════════════════════════════════════════════════════════════"
if [[ $FAILED_TESTS -eq 0 ]]; then
  echo "All $TOTAL_TESTS tests PASSED successfully!"
  exit 0
else
  echo "$FAILED_TESTS of $TOTAL_TESTS tests FAILED"
  exit 1
fi
