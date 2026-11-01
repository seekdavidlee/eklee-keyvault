import type { APIRequestContext, Page } from '@playwright/test';
import { test as base, expect } from './fixtures';
import { seedMsalSession } from './helpers/msal-seed';
import type { CategoryItem } from '../src/types';

const clientId = process.env.E2E_CLIENT_ID ?? '';
const tenantId = process.env.E2E_TENANT_ID ?? '';
const accessToken = process.env.E2E_ACCESS_TOKEN ?? '';
const headers = { Authorization: `Bearer ${accessToken}` };

type CategoryTestData = {
  categoryName: string;
  categoryNames: string[];
  secretNames: string[];
};

const test = base.extend<{ categoryData: CategoryTestData }>({
  categoryData: async ({ request }, provideData) => {
    const categoryName = `e2e-cat-${crypto.randomUUID().slice(0, 18)}`;
    const data: CategoryTestData = { categoryName, categoryNames: [], secretNames: [] };
    try {
      await provideData(data);
    } finally {
      for (const secretName of data.secretNames) {
        const response = await request.delete(`/api/secrets/${encodeURIComponent(secretName)}`, { headers });
        expect([200, 204, 404], 'Temporary secret cleanup must succeed').toContain(response.status());
      }
      if (data.categoryNames.length) {
        const categories = await getCategories(request);
        for (const category of categories.filter((item) => data.categoryNames.includes(item.name))) {
          expect(category.isDefault, 'Never delete the default category').toBe(false);
          const response = await request.delete(`/api/categories/${encodeURIComponent(category.id)}`, { headers });
          expect([200, 204, 404], 'Temporary category cleanup must succeed').toContain(response.status());
        }
      }
    }
  },
});

async function getCategories(request: APIRequestContext): Promise<CategoryItem[]> {
  const response = await request.get('/api/categories', { headers });
  expect(response.status()).toBe(200);
  return response.json();
}

async function createCategory(page: Page, data: CategoryTestData): Promise<void> {
  data.categoryNames.push(data.categoryName);
  await page.getByRole('button', { name: 'Create Category', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Create Category', exact: true });
  await dialog.getByRole('textbox', { name: 'Category name', exact: true }).fill(data.categoryName);
  await dialog.getByRole('button', { name: 'Create', exact: true }).click();
  await expect(dialog).not.toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('button', { name: `Rename ${data.categoryName}`, exact: true })).toBeVisible();
}

test.describe('Hosted category management', () => {
  test.beforeEach(async ({ page, request }, testInfo) => {
    const baseUrl = testInfo.project.use.baseURL;
    expect(baseUrl, 'Set E2E_BASE_URL to the cloud development HTTPS URL').toBeTruthy();
    const target = new URL(baseUrl!);
    expect(target.protocol, 'Category UI tests require a cloud HTTPS target').toBe('https:');
    expect(['localhost', '127.0.0.1', '[::1]']).not.toContain(target.hostname);
    test.skip(!accessToken, 'A hosted E2E_ACCESS_TOKEN is required.');
    expect(clientId, 'E2E_CLIENT_ID is required').toBeTruthy();
    expect(tenantId, 'E2E_TENANT_ID is required').toBeTruthy();

    await seedMsalSession(page, { clientId, tenantId, accessToken });
    await page.route('**/api/**', async (route) => {
      await route.continue({ headers: { ...route.request().headers(), authorization: `Bearer ${accessToken}` } });
    });
    const response = await request.get('/api/useraccess/me', { headers });
    expect(response.status(), 'The hosted test identity must be registered').toBe(200);
    expect((await response.json()).role, 'Category management requires Admin access').toBe('Admin');

    await page.goto('/');
    await page.getByRole('link', { name: 'Manage Categories', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'Category Management', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Create Category', exact: true })).toBeEnabled();
  });

  test('add a category and persist it after reload', async ({ page, request, categoryData }) => {
    await createCategory(page, categoryData);
    const category = (await getCategories(request)).find((item) => item.name === categoryData.categoryName);
    expect(category).toBeDefined();
    expect(category?.isDefault).toBe(false);
    await page.reload();
    await expect(page.getByRole('button', { name: `Rename ${categoryData.categoryName}`, exact: true }))
      .toBeVisible({ timeout: 15_000 });
    await page.getByRole('link', { name: 'Categories', exact: true }).click();
    await expect(page.getByRole('list', { name: 'Categories', exact: true })
      .getByRole('button', { name: categoryData.categoryName, exact: true })).toBeVisible();
  });

  test('rename a category twice while preserving its ID', async ({ page, request, categoryData }) => {
    await createCategory(page, categoryData);
    const original = (await getCategories(request)).find((item) => item.name === categoryData.categoryName)!;
    let currentName = categoryData.categoryName;
    for (const newName of [`${currentName}-new`, `${currentName}-NEW`]) {
      categoryData.categoryNames.push(newName);
      await page.getByRole('button', { name: `Rename ${currentName}`, exact: true }).click();
      const dialog = page.getByRole('dialog', { name: 'Rename Category', exact: true });
      await dialog.getByRole('textbox', { name: 'Category name', exact: true }).fill(newName);
      await dialog.getByRole('button', { name: 'Save', exact: true }).click();
      await expect(dialog).not.toBeVisible({ timeout: 15_000 });
      await expect(page.getByRole('button', { name: `Rename ${currentName}`, exact: true })).toHaveCount(0);
      await page.reload();
      await expect(page.getByRole('button', { name: `Rename ${newName}`, exact: true }))
        .toBeVisible({ timeout: 15_000 });
      const renamed = (await getCategories(request)).find((item) => item.id === original.id);
      expect(renamed).toEqual({ ...original, name: newName });
      currentName = newName;
    }
  });

  test('reject deletion of a category with secrets without losing data', async ({ page, categoryData }) => {
    await createCategory(page, categoryData);
    await page.getByRole('link', { name: 'Categories', exact: true }).click();
    await page.getByRole('list', { name: 'Categories', exact: true })
      .getByRole('button', { name: categoryData.categoryName, exact: true }).click();

    const secretName = `e2e-category-secret-${crypto.randomUUID()}`;
    categoryData.secretNames.push(secretName);
    await page.getByRole('button', { name: 'Create Secret', exact: true }).click();
    const secretDialog = page.getByRole('dialog');
    await secretDialog.getByLabel(/secret name/i).fill(secretName);
    await secretDialog.getByRole('button', { name: /generate secret/i }).click();
    await expect(secretDialog.getByRole('textbox', { name: /secret value/i }))
      .toHaveValue(/.+/, { timeout: 15_000 });
    await secretDialog.getByRole('button', { name: 'Create', exact: true }).click();
    await expect(page.getByText(`Secret '${secretName}' created successfully.`, { exact: true }))
      .toBeVisible({ timeout: 15_000 });

    await page.goto('/categories');
    await page.getByRole('button', { name: `Delete ${categoryData.categoryName}`, exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Delete Category', exact: true });
    const deletion = page.waitForResponse((response) =>
      new URL(response.url()).pathname.startsWith('/api/categories/') && response.request().method() === 'DELETE');
    await dialog.getByRole('button', { name: 'Delete', exact: true }).click();
    expect((await deletion).status()).toBe(409);
    await expect(dialog.getByRole('alert')).toContainText(/secret/i);
    await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
    await page.reload();
    await expect(page.getByRole('button', { name: `Rename ${categoryData.categoryName}`, exact: true }))
      .toBeVisible({ timeout: 15_000 });
    await page.getByRole('link', { name: 'Categories', exact: true }).click();
    await page.getByRole('list', { name: 'Categories', exact: true })
      .getByRole('button', { name: categoryData.categoryName, exact: true }).click();
    await expect(page.getByRole('gridcell').getByText(secretName, { exact: true }))
      .toBeVisible({ timeout: 15_000 });
  });

  test('delete a category with no secrets and persist its removal', async ({ page, request, categoryData }) => {
    await createCategory(page, categoryData);
    await page.getByRole('button', { name: `Delete ${categoryData.categoryName}`, exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Delete Category', exact: true });
    await dialog.getByRole('button', { name: 'Delete', exact: true }).click();
    await expect(dialog).not.toBeVisible({ timeout: 15_000 });
    await page.reload();
    await expect(page.getByRole('button', { name: 'Create Category', exact: true })).toBeEnabled();
    await expect(page.getByRole('button', { name: `Delete ${categoryData.categoryName}`, exact: true })).toHaveCount(0);
    expect((await getCategories(request)).some((item) => item.name === categoryData.categoryName)).toBe(false);
    await page.getByRole('link', { name: 'Categories', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Reload categories', exact: true })).toBeEnabled();
    await expect(page.getByRole('list', { name: 'Categories', exact: true })
      .getByRole('button', { name: categoryData.categoryName, exact: true })).toHaveCount(0);
  });
});