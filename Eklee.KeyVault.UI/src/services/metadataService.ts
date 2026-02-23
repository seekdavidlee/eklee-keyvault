import apiClient from './apiClient';
import type { SecretItemMetaList } from '../types';

/** Response from getMetadata including the ETag for optimistic concurrency. */
export interface MetadataWithETag {
  metaList: SecretItemMetaList;
  etag: string | null;
}

/** Fetches the secret display-name metadata list from the API, including the blob ETag. */
export async function getMetadata(): Promise<MetadataWithETag> {
  const response = await apiClient.get<SecretItemMetaList>('/api/metadata');
  const etag = (response.headers['etag'] as string | undefined) ?? null;
  return { metaList: response.data, etag };
}

/**
 * Replaces the entire metadata list via the API with optimistic concurrency.
 * Sends the ETag via the If-Match header. Returns the new ETag from the response.
 */
export async function updateMetadata(
  metaList: SecretItemMetaList,
  etag: string | null
): Promise<string | null> {
  const headers: Record<string, string> = {};
  if (etag) {
    headers['If-Match'] = etag;
  }
  const response = await apiClient.put('/api/metadata', metaList, { headers });
  return (response.headers['etag'] as string | undefined) ?? null;
}
