import { describe, it, expect, afterAll } from 'vitest';
import { withRollback, closePool } from './setup';

describe('02 — Identity Foundation', () => {
  afterAll(async () => { await closePool(); });

  it('should auto-create user profile via trigger on auth.users INSERT', async () => {
    await withRollback(async (client) => {
      // Insert into auth.users — trigger should auto-create profile
      const authRes = await client.query(
        `INSERT INTO auth.users (email, raw_user_meta_data)
         VALUES ('test@identity.com', '{"display_name":"Identity Test"}')
         RETURNING id`
      );
      const userId = authRes.rows[0].id;

      // Profile should be auto-created by on_auth_user_created trigger
      const profileRes = await client.query(
        `SELECT * FROM user_profiles WHERE id = $1`, [userId]
      );
      expect(profileRes.rows.length).toBe(1);
      expect(profileRes.rows[0].is_active).toBe(true);
    });
  });

  it('should enforce unique email on auth.users', async () => {
    await withRollback(async (client) => {
      await client.query(
        `INSERT INTO auth.users (email) VALUES ('dupe@test.com')`
      );

      await expect(
        client.query(
          `INSERT INTO auth.users (email) VALUES ('dupe@test.com')`
        )
      ).rejects.toThrow();
    });
  });
});
