import { execFileSync, spawnSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as crypto from 'crypto';

describe('Database Restore Checksum Integrity Verification (#958)', () => {
  const scriptsDir = path.resolve(__dirname, '../../scripts');
  const restoreScript = path.join(scriptsDir, 'restore-db.sh');
  const backupScript = path.join(scriptsDir, 'backup-db.sh');

  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'db-restore-test-'));
  });

  afterEach(() => {
    if (tempDir && fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  function createValidBackup(filename = 'valid_backup.sql'): { backupPath: string; checksumPath: string } {
    const backupPath = path.join(tempDir, filename);
    const checksumPath = path.join(tempDir, `${filename}.sha256`);

    const sqlContent = [
      '-- Database dump fixture',
      'CREATE TABLE test_markets (id SERIAL PRIMARY KEY, title VARCHAR(100));',
      "INSERT INTO test_markets (title) VALUES ('BTC above 100k');",
    ].join('\n');

    fs.writeFileSync(backupPath, sqlContent, 'utf8');

    // SHA-256 hash in sha256sum format (<hash>  <filename>)
    const hash = crypto.createHash('sha256').update(sqlContent).digest('hex');
    fs.writeFileSync(checksumPath, `${hash}  ${filename}\n`, 'utf8');

    return { backupPath, checksumPath };
  }

  it('scripts/restore-db.sh and backup-db.sh should exist and be executable scripts', () => {
    expect(fs.existsSync(restoreScript)).toBe(true);
    expect(fs.existsSync(backupScript)).toBe(true);

    const restoreContent = fs.readFileSync(restoreScript, 'utf8');
    const backupContent = fs.readFileSync(backupScript, 'utf8');

    expect(restoreContent).toContain('sha256sum -c');
    expect(restoreContent).toContain('verify_checksum');
    expect(backupContent).toContain('generate_checksum');
    expect(backupContent).toContain('.sha256');
  });

  it('rejects a corrupted backup file with exit code 7', () => {
    const { backupPath } = createValidBackup('corrupted_backup.sql');

    // Corrupt the backup file
    fs.appendFileSync(backupPath, '\n-- MALICIOUS TAMPERING OR CORRUPTION --\n');

    const result = spawnSync('bash', [restoreScript, '--backup-file', backupPath], {
      encoding: 'utf8',
      env: { ...process.env, LOG_DIR: tempDir },
    });

    // If bash is not in PATH (e.g. bare Windows without bash on PATH), skip or assert on bash if available
    if (result.error) {
      return; // Skip if bash not found in testing environment
    }

    expect(result.status).toBe(7);
    const output = (result.stdout || '') + (result.stderr || '');
    expect(output).toMatch(/Checksum verification FAILED|Integrity check failed/i);
  });

  it('aborts restore with exit code 7 when checksum file is missing', () => {
    const { backupPath, checksumPath } = createValidBackup('missing_chk_backup.sql');

    // Remove the checksum file
    fs.unlinkSync(checksumPath);

    const result = spawnSync('bash', [restoreScript, '--backup-file', backupPath], {
      encoding: 'utf8',
      env: { ...process.env, LOG_DIR: tempDir },
    });

    if (result.error) {
      return;
    }

    expect(result.status).toBe(7);
    const output = (result.stdout || '') + (result.stderr || '');
    expect(output).toMatch(/checksum file not found/i);
  });

  it('aborts restore when explicit --checksum-file hash does not match backup', () => {
    const { backupPath } = createValidBackup('mismatch_backup.sql');
    const wrongChecksumPath = path.join(tempDir, 'wrong.sha256');
    fs.writeFileSync(wrongChecksumPath, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  mismatch_backup.sql\n');

    const result = spawnSync(
      'bash',
      [restoreScript, '--backup-file', backupPath, '--checksum-file', wrongChecksumPath],
      {
        encoding: 'utf8',
        env: { ...process.env, LOG_DIR: tempDir },
      }
    );

    if (result.error) {
      return;
    }

    expect(result.status).toBe(7);
    const output = (result.stdout || '') + (result.stderr || '');
    expect(output).toMatch(/Checksum verification FAILED/i);
  });

  it('valid backup passes SHA-256 integrity validation step', () => {
    const { backupPath } = createValidBackup('valid_intact.sql');

    const result = spawnSync('bash', [restoreScript, '--backup-file', backupPath], {
      encoding: 'utf8',
      env: {
        ...process.env,
        LOG_DIR: tempDir,
        DATABASE_URL: 'postgresql://invalid:invalid@127.0.0.1:54329/nonexistent_db',
      },
    });

    if (result.error) {
      return;
    }

    // It must not fail at checksum verification (exit code 7)
    expect(result.status).not.toBe(7);
    const output = (result.stdout || '') + (result.stderr || '');
    expect(output).toMatch(/Checksum verification PASSED/i);
  });
});
