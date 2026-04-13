import type { Page } from '@playwright/test';

interface MsalSeedConfig {
  clientId: string;
  tenantId: string;
  accessToken: string;
}

/**
 * Decodes a JWT payload without verifying the signature.
 * Used to extract claims (oid, tid, name, etc.) from the access token
 * so we can construct MSAL cache entries.
 */
function decodeJwtPayload(token: string): Record<string, unknown> {
  const payload = token.split('.')[1];
  return JSON.parse(Buffer.from(payload, 'base64url').toString());
}

/**
 * Registers an init script that seeds MSAL's sessionStorage cache
 * before any page scripts run. This makes the SPA see a pre-authenticated
 * session without going through the interactive Entra login redirect.
 *
 * The access token is obtained externally (e.g. via `az account get-access-token`)
 * and injected into the MSAL cache format that `@azure/msal-browser` expects.
 *
 * Call this BEFORE `page.goto()`.
 */
export async function seedMsalSession(
  page: Page,
  config: MsalSeedConfig
): Promise<void> {
  const { clientId, tenantId, accessToken } = config;
  const claims = decodeJwtPayload(accessToken);

  const oid = claims.oid as string;
  const tid = (claims.tid as string) || tenantId;
  const upn = (claims.upn ||
    claims.preferred_username ||
    'e2e-test@test.com') as string;
  const name = (claims.name || 'E2E Test User') as string;
  const exp = claims.exp as number;

  const homeAccountId = `${oid}.${tid}`;
  const environment = 'login.microsoftonline.com';

  const seedData = {
    homeAccountId,
    environment,
    tenantId: tid,
    clientId,
    upn,
    name,
    oid,
    accessToken,
    exp,
  };

  // addInitScript runs in the browser context BEFORE any page JavaScript,
  // so the MSAL cache is populated before PublicClientApplication.initialize()
  // reads sessionStorage.
  await page.addInitScript((data) => {
    const now = Math.floor(Date.now() / 1000);

    // Account entity — MSAL uses this to identify the signed-in user
    const accountKey = `${data.homeAccountId}-${data.environment}-${data.tenantId}`;
    const accountEntity = {
      homeAccountId: data.homeAccountId,
      environment: data.environment,
      realm: data.tenantId,
      localAccountId: data.oid,
      username: data.upn,
      name: data.name,
      authorityType: 'MSSTS',
    };

    // Access token entity — acquireTokenSilent returns this without a network call
    const scopes = `${data.clientId}/access_as_user openid profile offline_access`;
    const tokenKey = `${data.homeAccountId}-${data.environment}-accesstoken-${data.clientId}-${data.tenantId}-${scopes}`;
    const tokenEntity = {
      homeAccountId: data.homeAccountId,
      environment: data.environment,
      credentialType: 'AccessToken',
      clientId: data.clientId,
      realm: data.tenantId,
      secret: data.accessToken,
      target: scopes,
      tokenType: 'Bearer',
      expiresOn: String(data.exp),
      extendedExpiresOn: String(data.exp),
      cachedAt: String(now),
    };

    // Key registries — MSAL iterates these to discover cached entries
    sessionStorage.setItem(
      'msal.account.keys',
      JSON.stringify([accountKey])
    );
    sessionStorage.setItem(
      `msal.token.keys.${data.clientId}`,
      JSON.stringify({
        idToken: [],
        accessToken: [tokenKey],
        refreshToken: [],
      })
    );

    // Store the entities themselves
    sessionStorage.setItem(accountKey, JSON.stringify(accountEntity));
    sessionStorage.setItem(tokenKey, JSON.stringify(tokenEntity));

    // Active account hint so MSAL skips account selection
    sessionStorage.setItem(
      `msal.${data.clientId}.active-account`,
      data.homeAccountId
    );
  }, seedData);
}
