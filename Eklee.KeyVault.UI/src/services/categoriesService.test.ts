import { beforeEach, describe, expect, it, vi } from 'vitest';
import apiClient from './apiClient';
import { createCategory, deleteCategory, getCategories, renameCategory } from './categoriesService';
import { getSecrets, setSecret } from './secretsService';

vi.mock('./apiClient', () => ({
  default: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}));

const category = { id: 'category-id', name: 'Finance', isDefault: false };

describe('category transport contracts', () => {
  beforeEach(() => vi.resetAllMocks());

  it('lists shared categories without fetching secret values', async () => {
    vi.mocked(apiClient.get).mockResolvedValue({ data: [category] });
    expect(await getCategories()).toEqual([category]);
    expect(apiClient.get).toHaveBeenCalledExactlyOnceWith('/api/categories');
  });

  it('creates a category with its display name', async () => {
    vi.mocked(apiClient.post).mockResolvedValue({ data: category });
    expect(await createCategory('Finance')).toEqual(category);
    expect(apiClient.post).toHaveBeenCalledExactlyOnceWith('/api/categories', { name: 'Finance' });
  });

  it('encodes stable identifiers when renaming and deleting', async () => {
    vi.mocked(apiClient.put).mockResolvedValue({ data: category });
    await renameCategory('category/id', 'FINANCE');
    await deleteCategory('category/id');
    expect(apiClient.put).toHaveBeenCalledWith('/api/categories/category%2Fid', { name: 'FINANCE' });
    expect(apiClient.delete).toHaveBeenCalledWith('/api/categories/category%2Fid');
  });

  it('preserves actionable server conflicts for the UI', async () => {
    const conflict = new Error('Delete the secrets in this category first.');
    vi.mocked(apiClient.delete).mockRejectedValue(conflict);
    await expect(deleteCategory(category.id)).rejects.toBe(conflict);
  });

  it('restricts secret metadata to the requested category', async () => {
    vi.mocked(apiClient.get).mockResolvedValue({ data: [] });
    expect(await getSecrets(category.id)).toEqual([]);
    expect(apiClient.get).toHaveBeenCalledWith('/api/secrets', { params: { categoryId: category.id } });
  });

  it('sends a category on creation without adding one to existing value updates', async () => {
    vi.mocked(apiClient.put).mockResolvedValue({ data: { name: 'test-secret' } });
    await setSecret('test-secret', 'test-value', category.id);
    await setSecret('test-secret', 'updated-test-value');
    expect(apiClient.put).toHaveBeenNthCalledWith(1, '/api/secrets/test-secret', {
      value: 'test-value', categoryId: category.id,
    });
    expect(apiClient.put).toHaveBeenNthCalledWith(2, '/api/secrets/test-secret', {
      value: 'updated-test-value',
    });
  });
});