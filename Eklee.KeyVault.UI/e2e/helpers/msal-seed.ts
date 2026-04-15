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
  };

  // addInitScript runs in the browser context BEFORE any page JavaScript,
  // so the MSAL cache is populated before PublicClientApplication.initialize()
  // reads sessionStorage.
  //
  // MSAL Browser v5 uses schema version 2 with pipe-separated, lowercased
  // cache keys and a "msal.2." prefix for registry keys.
  await page.addInitScript((data) => {
    const now = Math.floor(Date.now() / 1000);
    const SEP = '|';
    const homeTenantId = data.homeAccountId.split('.')[1] || data.tenantId;

    // Account entity key: msal.2|<homeAccountId>|<environment>|<tenantId>
    const accountKey = [
      'msal.2',
      data.homeAccountId,
      data.environment,
      homeTenantId,
    ]
      .join(SEP)
      .toLowerCase();

    const accountEntity = {
      homeAccountId: data.homeAccountId,
      environment: data.environment,
      realm: data.tenantId,
      localAccountId: data.oid,
      username: data.upn,
      name: data.name,
      authorityType: 'MSSTS',
      lastUpdatedAt: String(Date.now()),
    };

    // Access token entity key:
    //   msal.2|<homeAccountId>|<environment>|accesstoken|<clientId>|<realm>|<target>||
    const scopes = `${data.clientId}/access_as_user openid profile offline_access`;
    const tokenKey = [
      'msal.2',
      data.homeAccountId,
      data.environment,
      'accesstoken',
      data.clientId,
      data.tenantId,
      scopes,
      '', // claims hash (empty)
    ]
      .join(SEP)
      .toLowerCase();

    // Use a synthetic expiry far in the future so MSAL always considers the
    // cached token valid. MSAL's acquireTokenSilent applies a ~5 min clock-skew
    // buffer; if the real JWT exp is near the current time (common in CI where
    // the token is obtained early in the pipeline), MSAL considers it expired,
    // throws before the request reaches the network layer, and Playwright's
    // route handler never gets to inject the Bearer token.
    const syntheticExp = now + 3600;

    const tokenEntity = {
      homeAccountId: data.homeAccountId,
      environment: data.environment,
      credentialType: 'AccessToken',
      clientId: data.clientId,
      realm: data.tenantId,
      secret: data.accessToken,
      target: scopes,
      tokenType: 'Bearer',
      expiresOn: String(syntheticExp),
      extendedExpiresOn: String(syntheticExp + 3600),
      cachedAt: String(now),
    };

    // Key registries — MSAL v5 uses "msal.2.account.keys" / "msal.2.token.keys.<clientId>"
    sessionStorage.setItem(
      'msal.2.account.keys',
      JSON.stringify([accountKey])
    );
    sessionStorage.setItem(
      `msal.2.token.keys.${data.clientId}`,
      JSON.stringify({
        idToken: [],
        accessToken: [tokenKey],
        refreshToken: [],
      })
    );

    // Store the entities themselves
    sessionStorage.setItem(accountKey, JSON.stringify(accountEntity));
    sessionStorage.setItem(tokenKey, JSON.stringify(tokenEntity));

    // Active account — MSAL v5 uses "active-account-filters" with a JSON object
    sessionStorage.setItem(
      `msal.${data.clientId}.active-account-filters`,
      JSON.stringify({
        homeAccountId: data.homeAccountId,
        localAccountId: data.oid,
        tenantId: data.tenantId,
      })
    );
  }, seedData);
}
