import { test, expect } from '@playwright/test';
import { seedMsalSession } from './helpers/msal-seed';

const clientId = process.env.E2E_CLIENT_ID ?? '';
const tenantId = process.env.E2E_TENANT_ID ?? '';
const accessToken = process.env.E2E_ACCESS_TOKEN ?? '';

test.describe('Secrets CRUD', () => {
  const secretName = `e2e-test-secret-${Date.now()}`;
  const secretValue = 'initial-secret-value';
  const updatedSecretValue = 'updated-secret-value';

  test.beforeEach(async ({ page, request }) => {
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

    // Ensure the test user is registered (auto-registers as Admin if first user)
    const meResponse = await request.get('/api/useraccess/me', {
      headers: { Authorization: `Bearer ${accessToken}` },
    });

    test.skip(
      meResponse.status() === 403,
      'E2E test user is not registered for access. Use a fresh environment or register the user as Admin.'
    );

    if (meResponse.ok()) {
      const me = await meResponse.json();
      test.skip(
        me.role !== 'Admin',
        'E2E test user must have the Admin role for secrets CRUD operations.'
      );
    }
  });

  test('create, read, update, and delete a secret', async ({ page }) => {
    await page.goto('/');

    // Wait for the authenticated layout to render
    await expect(
      page.getByRole('button', { name: /sign out/i })
    ).toBeVisible({ timeout: 15_000 });

    // --- CREATE ---
    await page.getByRole('button', { name: /create secret/i }).click();

    // Fill out the create dialog
    await page.getByLabel(/secret name/i).fill(secretName);
    await page.getByRole('textbox', { name: /secret value/i }).fill(secretValue);
    await page.getByRole('button', { name: /^create$/i }).click();

    // Wait for the success snackbar
    await expect(
      page.getByText(`Secret '${secretName}' created successfully.`)
    ).toBeVisible({ timeout: 15_000 });

    // Filter the grid so the new secret is visible (grid is paginated at 25 rows)
    await page.getByRole('textbox', { name: /search secrets/i }).fill(secretName);

    // The secret should appear in the data grid
    await expect(page.getByRole('gridcell', { name: secretName })).toBeVisible({ timeout: 15_000 });

    // --- READ ---
    // Find the row containing our secret and click the "Show secret" button
    const secretRow = page.getByRole('row').filter({ hasText: secretName });
    await secretRow.getByRole('button', { name: /show secret/i }).click();

    // The revealed value should appear in the row
    await expect(secretRow.getByText(secretValue)).toBeVisible({ timeout: 10_000 });

    // --- UPDATE ---
    await secretRow.getByRole('button', { name: /update secret value/i }).click();

    // The update dialog should show the secret name as disabled
    await expect(page.getByLabel(/secret name/i)).toBeDisabled();

    // Fill in the new value and save
    await page.getByRole('textbox', { name: /secret value/i }).fill(updatedSecretValue);
    await page.getByRole('button', { name: /^update$/i }).click();

    // Wait for the success snackbar
    await expect(
      page.getByText(`Secret '${secretName}' updated successfully.`)
    ).toBeVisible({ timeout: 15_000 });

    // Reveal the secret again to verify the updated value
    const updatedRow = page.getByRole('row').filter({ hasText: secretName });
    await updatedRow.getByRole('button', { name: /show secret/i }).click();
    await expect(updatedRow.getByText(updatedSecretValue)).toBeVisible({ timeout: 10_000 });

    // --- DELETE ---
    await updatedRow.getByRole('button', { name: /delete secret/i }).click();

    // Confirm deletion in the dialog
    await expect(page.getByText(`Are you sure you want to delete the secret`)).toBeVisible();
    await page.getByRole('button', { name: /^delete$/i }).click();

    // Wait for the success snackbar
    await expect(
      page.getByText(`Secret '${secretName}' deleted successfully.`)
    ).toBeVisible({ timeout: 15_000 });

    // The secret should no longer be in the grid
    await expect(
      page.getByRole('gridcell', { name: secretName })
    ).not.toBeVisible();
  });
});
