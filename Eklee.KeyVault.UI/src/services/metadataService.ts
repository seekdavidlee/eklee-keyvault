import apiClient from './apiClient';
import type { SecretItemMetaList } from '../types';

/** Fetches the secret display-name metadata list from the API. */
export async function getMetadata(): Promise<SecretItemMetaList> {
  const response = await apiClient.get<SecretItemMetaList>('/api/metadata');
  return response.data;
}

/** Replaces the entire metadata list via the API. */
export async function updateMetadata(metaList: SecretItemMetaList): Promise<void> {
  await apiClient.put('/api/metadata', metaList);
}
