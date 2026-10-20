import fs from 'fs';
import path from 'path';
import Redis from 'ioredis';

describe('Staging Redis Password & Environment Secrets Security (#956)', () => {
  const rootDir = path.resolve(__dirname, '../../../');
  const stagingComposePath = path.join(rootDir, 'docker-compose.staging.yml');
  const stagingEnvExamplePath = path.join(rootDir, '.env.staging.example');
  const backendStagingEnvPath = path.join(rootDir, 'backend/.env.staging');
  const indexerStagingEnvPath = path.join(rootDir, 'indexer/.env.staging');

  describe('docker-compose.staging.yml configuration', () => {
    let composeContent: string;

    beforeAll(() => {
      expect(fs.existsSync(stagingComposePath)).toBe(true);
      composeContent = fs.readFileSync(stagingComposePath, 'utf8');
    });

    it('enforces requirepass on the redis service in staging', () => {
      expect(composeContent).toMatch(/command:\s*redis-server\s+--requirepass\s+\$\{REDIS_PASSWORD\}/);
    });

    it('configures authenticated healthcheck for redis using REDISCLI_AUTH or -a', () => {
      // Must not use unauthenticated `redis-cli ping` which fails with NOAUTH
      expect(composeContent).not.toMatch(/test:\s*\['CMD',\s*'redis-cli',\s*'ping'\]/);
      expect(composeContent).toMatch(/REDISCLI_AUTH|redis-cli\s+-a/);
    });

    it('injects REDIS_PASSWORD and authenticated REDIS_URL into backend service', () => {
      const backendSection = composeContent.slice(composeContent.indexOf('backend:'));
      expect(backendSection).toMatch(/REDIS_PASSWORD=\$\{REDIS_PASSWORD\}/);
      expect(backendSection).toMatch(/REDIS_URL=redis:\/\/:\$\{REDIS_PASSWORD\}@redis:6379/);
    });

    it('injects REDIS_PASSWORD and authenticated REDIS_URL into indexer service', () => {
      const indexerSection = composeContent.slice(
        composeContent.indexOf('indexer:'),
        composeContent.indexOf('backend:')
      );
      expect(indexerSection).toMatch(/REDIS_PASSWORD=\$\{REDIS_PASSWORD\}/);
      expect(indexerSection).toMatch(/REDIS_URL=redis:\/\/:\$\{REDIS_PASSWORD\}@redis:6379/);
    });

    it('configures service dependencies on healthy redis', () => {
      expect(composeContent).toMatch(/redis:\s*\r?\n\s+condition:\s*service_healthy/);
    });
  });

  describe('.env.staging.example security requirements', () => {
    let envContent: string;

    beforeAll(() => {
      expect(fs.existsSync(stagingEnvExamplePath)).toBe(true);
      envContent = fs.readFileSync(stagingEnvExamplePath, 'utf8');
    });

    it('defines REDIS_PASSWORD with strong placeholder requirement (>=32 chars)', () => {
      const match = envContent.match(/REDIS_PASSWORD=([^\r\n]+)/);
      expect(match).not.toBeNull();
      const passwordPlaceholder = match![1].trim();
      expect(passwordPlaceholder.length).toBeGreaterThanOrEqual(32);
      expect(passwordPlaceholder).toMatch(/CHANGE_ME|STRONG|PASSWORD/i);
    });

    it('defines REDIS_URL with authenticated user/pass placeholder', () => {
      expect(envContent).toMatch(/REDIS_URL=redis:\/\/:\$\{REDIS_PASSWORD\}@redis:6379/);
    });
  });

  describe('Service environment files (.env.staging)', () => {
    it('provides REDIS_PASSWORD and authenticated REDIS_URL in backend/.env.staging', () => {
      expect(fs.existsSync(backendStagingEnvPath)).toBe(true);
      const content = fs.readFileSync(backendStagingEnvPath, 'utf8');
      expect(content).toMatch(/REDIS_PASSWORD=[^\r\n]+/);
      expect(content).toMatch(/REDIS_URL=redis:\/\/:[^\r\n]+@redis:6379/);
    });

    it('provides REDIS_PASSWORD and authenticated REDIS_URL in indexer/.env.staging', () => {
      expect(fs.existsSync(indexerStagingEnvPath)).toBe(true);
      const content = fs.readFileSync(indexerStagingEnvPath, 'utf8');
      expect(content).toMatch(/REDIS_PASSWORD=[^\r\n]+/);
      expect(content).toMatch(/REDIS_URL=redis:\/\/:[^\r\n]+@redis:6379/);
    });
  });

  describe('Redis client authentication behavior', () => {
    it('correctly sets up ioredis client options with password authentication', () => {
      const originalEnv = process.env.REDIS_PASSWORD;
      try {
        process.env.REDIS_PASSWORD = 'test_staging_secure_secret_123';
        const client = new Redis('redis://localhost:6379', {
          lazyConnect: true,
          password: process.env.REDIS_PASSWORD,
        });

        expect(client.options.password).toBe('test_staging_secure_secret_123');
        expect(client.options.lazyConnect).toBe(true);
        client.disconnect();
      } finally {
        if (originalEnv !== undefined) {
          process.env.REDIS_PASSWORD = originalEnv;
        } else {
          delete process.env.REDIS_PASSWORD;
        }
      }
    });

    it('parses password from authenticated redis URL', () => {
      const authenticatedUrl = 'redis://:test_staging_secure_secret_123@redis.staging:6379';
      const client = new Redis(authenticatedUrl, { lazyConnect: true });

      expect(client.options.password).toBe('test_staging_secure_secret_123');
      expect(client.options.host).toBe('redis.staging');
      expect(client.options.port).toBe(6379);
      client.disconnect();
    });
  });
});
