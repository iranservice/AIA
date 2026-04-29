import { Pool, PoolClient } from 'pg';

const pool = new Pool({
  host: '127.0.0.1',
  port: 5432,
  database: 'aia_test',
  user: 'aia_user',
  password: 'aia_pass',
});

/**
 * Get a raw pool connection (service-role — no RLS).
 */
export async function getServiceClient(): Promise<PoolClient> {
  return pool.connect();
}

/**
 * Simulate an authenticated Supabase user by setting JWT claims.
 * All subsequent queries in this transaction will use this identity for RLS.
 */
export async function asUser(
  client: PoolClient,
  userId: string,
  role: string = 'authenticated'
): Promise<void> {
  const claims = JSON.stringify({ sub: userId, role });
  await client.query(`SET LOCAL request.jwt.claims = '${claims}'`);
  await client.query(`SET LOCAL role = '${role}'`);
}

/**
 * Switch to service_role (bypasses RLS).
 */
export async function asServiceRole(client: PoolClient): Promise<void> {
  await client.query(`SET LOCAL role = 'aia_user'`);
  await client.query(`SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000","role":"service_role"}'`);
}

/**
 * Run a callback inside a transaction that auto-rolls back.
 * This keeps tests isolated without modifying the database.
 */
export async function withRollback(
  fn: (client: PoolClient) => Promise<void>
): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await fn(client);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}

/**
 * Create a test user in auth.users.
 * The on_auth_user_created trigger auto-creates the user_profiles row.
 * Returns the user UUID.
 */
export async function createTestUser(
  client: PoolClient,
  email: string
): Promise<string> {
  const res = await client.query(
    `INSERT INTO auth.users (email, raw_user_meta_data)
     VALUES ($1, '{"display_name": "Test User"}')
     RETURNING id`,
    [email]
  );
  return res.rows[0].id;
}

/**
 * Create a test business and return its UUID.
 * Also creates an 'owner' membership for the given user.
 */
export async function createTestBusiness(
  client: PoolClient,
  name: string,
  ownerId: string
): Promise<string> {
  const slug = name.toLowerCase().replace(/\s+/g, '-') + '-' + Date.now();
  const res = await client.query(
    `INSERT INTO businesses (name, slug, business_type)
     VALUES ($1, $2, 'restaurant')
     RETURNING id`,
    [name, slug]
  );
  const bizId = res.rows[0].id;

  // Create owner membership
  await client.query(
    `INSERT INTO business_memberships (business_id, user_id, role, is_active)
     VALUES ($1, $2, 'owner', true)`,
    [bizId, ownerId]
  );

  return bizId;
}

/**
 * Create a business membership.
 */
export async function createMembership(
  client: PoolClient,
  businessId: string,
  userId: string,
  role: string = 'operator',
  isActive: boolean = true
): Promise<string> {
  const res = await client.query(
    `INSERT INTO business_memberships (business_id, user_id, role, is_active)
     VALUES ($1, $2, $3, $4)
     RETURNING id`,
    [businessId, userId, role, isActive]
  );
  return res.rows[0].id;
}

/**
 * Close the pool — call in afterAll.
 */
export async function closePool(): Promise<void> {
  await pool.end();
}
