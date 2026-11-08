import { beforeEach, describe, expect, it, vi } from 'vitest';
import apiClient from './apiClient';
import { exportSecrets, importSecrets } from './secretsService';

vi.mock('./apiClient', () => ({ default: { get: vi.fn(), post: vi.fn() } }));

describe('secret transfer transport', () => {
  beforeEach(() => vi.resetAllMocks());

  it('requests an authenticated category-scoped blob', async () => {
    const blob = new Blob(['{}']);
    vi.mocked(apiClient.get).mockResolvedValue({ data: blob });
    expect(await exportSecrets('category')).toBe(blob);
    expect(apiClient.get).toHaveBeenCalledWith('/api/secret-transfers/export', {
      params: { categoryId: 'category' }, responseType: 'blob',
    });
  });

  it('preserves raw JSON including duplicate properties for full server validation', async () => {
    const raw = '{"formatVersion":1,"formatVersion":2,"secrets":[]}';
    const outcome = { results: [], accessDenied: false };
    vi.mocked(apiClient.post).mockResolvedValue({ data: outcome });
    expect(await importSecrets('destination', raw)).toBe(outcome);
    expect(apiClient.post).toHaveBeenCalledWith('/api/secret-transfers/import', raw, {
      params: { categoryId: 'destination' }, headers: { 'Content-Type': 'application/json' },
    });
  });
});