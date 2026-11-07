import { test, expect } from './fixtures';

test.describe('Frontend cache policy', () => {
  test('entry pages and runtime configuration retain their revalidation policies', async ({ request }) => {
    for (const [path, policy] of [
      ['/', 'no-cache'],
      ['/index.html', 'no-cache'],
      ['/categories', 'no-cache'],
      ['/config.js', 'no-store'],
    ]) {
      const response = await request.get(path);
      expect(response.status(), path).toBe(200);
      expect(response.headers()['cache-control'], path).toBe(policy);
      const etag = response.headers().etag;
      expect(etag, path).toBeTruthy();

      const revalidated = await request.get(path, {
        headers: { 'If-None-Match': etag },
      });
      expect(revalidated.status(), path).toBe(304);
      expect(revalidated.headers()['cache-control'], path).toBe(policy);
    }
  });

  test('built assets are immutable but missing and unversioned files are not', async ({ page, request }) => {
    await page.goto('/');
    const assetPaths = await page.locator('script[src], link[href]').evaluateAll(elements =>
      elements.map(element => element.getAttribute('src') ?? element.getAttribute('href') ?? '')
        .filter(path => /^\/assets\/.+-[A-Za-z0-9_-]{8}\.[^/]+$/.test(path))
    );
    expect(assetPaths.length).toBeGreaterThan(0);
    expect(assetPaths.some(path => path.endsWith('.js'))).toBe(true);

    for (const path of new Set(assetPaths)) {
      const response = await request.get(path);
      expect(response.status(), path).toBe(200);
      expect(response.headers()['cache-control'], path)
        .toBe('public, max-age=31536000, immutable');
    }

    const config = await request.get('/config.js');
    expect(config.status()).toBe(200);
    expect(config.headers()['cache-control']).not.toContain('immutable');

    const missing = await request.get(`/assets/missing-${crypto.randomUUID()}-12345678.js`);
    expect(missing.status()).toBe(404);
    expect(missing.headers()['cache-control'] ?? '').not.toContain('immutable');
  });

  test('normal reload revalidates entry HTML with the browser cache enabled', async ({ page }) => {
    const original = await page.goto('/');
    expect(original?.status()).toBe(200);
    expect(original?.headers()['cache-control']).toBe('no-cache');
    const originalBundles = await page.locator('script[src^="/assets/"]').evaluateAll(elements =>
      elements.map(element => element.getAttribute('src'))
    );
    expect(originalBundles.length).toBeGreaterThan(0);

    const refreshed = await page.reload();
    expect(refreshed).not.toBeNull();
    expect([200, 304]).toContain(refreshed!.status());
    expect(refreshed!.headers()['cache-control']).toBe('no-cache');
    const refreshedBundles = await page.locator('script[src^="/assets/"]').evaluateAll(elements =>
      elements.map(element => element.getAttribute('src'))
    );
    expect(refreshedBundles).toEqual(originalBundles);
    await expect(page.getByRole('button', { name: /sign in/i })).toBeVisible();
  });
});
