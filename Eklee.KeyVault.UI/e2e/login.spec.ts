import { test, expect } from '@playwright/test';
import { seedMsalSession } from './helpers/msal-seed';

const clientId = process.env.E2E_CLIENT_ID ?? '';
const tenantId = process.env.E2E_TENANT_ID ?? '';
const accessToken = process.env.E2E_ACCESS_TOKEN ?? '';

test.describe('Authentication', () => {
  test.beforeEach(async ({ page }) => {
    test.skip(
      !accessToken,
      'E2E_ACCESS_TOKEN is required. Run: az account get-access-token --resource <clientId> --query accessToken -o tsv'
    );

    await seedMsalSession(page, { clientId, tenantId, accessToken });

    // Intercept all API requests and inject the Bearer token directly.
    // This avoids relying on MSAL's acquireTokenSilent which may fail
    // when the seeded cache entry doesn't perfectly match the SDK lookup.
    await page.route('**/api/**', async (route) => {
      const headers = {
        ...route.request().headers(),
        authorization: `Bearer ${accessToken}`,
      };
      await route.continue({ headers });
    });
  });

  test('authenticated user can view the application', async ({ page }) => {
    await page.goto('/');

    // MSAL should recognise the seeded session — the login prompt must not appear
    await expect(
      page.getByRole('button', { name: /sign in/i })
    ).not.toBeVisible();

    // The authenticated layout renders with a Sign Out button
    await expect(
      page.getByRole('button', { name: /sign out/i })
    ).toBeVisible({ timeout: 15_000 });

    // The app title is visible in the header
    await expect(page.getByText('KeyVault Client').first()).toBeVisible();
  });
});
