import apiClient from './apiClient';
import type { CategoryItem } from '../types';

/** Fetches shared categories without reading secret values. Admin and User access. */
export async function getCategories(): Promise<CategoryItem[]> {
  const response = await apiClient.get<CategoryItem[]>('/api/categories');
  return response.data;
}

/** Creates a category with a unique, case-insensitive name of 1 to 30 characters. Admin-only. */
export async function createCategory(name: string): Promise<CategoryItem> {
  const response = await apiClient.post<CategoryItem>('/api/categories', { name });
  return response.data;
}

/** Changes the display name while preserving the category's ID and default designation. Admin-only. */
export async function renameCategory(id: string, name: string): Promise<CategoryItem> {
  const response = await apiClient.put<CategoryItem>(
    `/api/categories/${encodeURIComponent(id)}`, { name }
  );
  return response.data;
}

/** Deletes only an empty, nondefault category; server conflicts reject the promise. Admin-only. */
export async function deleteCategory(id: string): Promise<void> {
  await apiClient.delete(`/api/categories/${encodeURIComponent(id)}`);
}