import apiClient from './apiClient';
import type { UserAccess, UserAccessResponse } from '../types';

/** Fetches the current user's access record. Returns 403 if the user is not registered. */
export async function getMe(): Promise<UserAccess> {
  const response = await apiClient.get<UserAccess>('/api/useraccess/me');
  return response.data;
}

/**
 * Fetches the full user access list (admin-only).
 * Returns both the user list and the blob ETag for optimistic concurrency.
 */
export async function getUsers(): Promise<UserAccessResponse> {
  const response = await apiClient.get<UserAccessResponse>('/api/useraccess/users');
  // Prefer the ETag from the response header, fall back to the body field
  const headerEtag = response.headers['etag'] as string | undefined;
  if (headerEtag && response.data) {
    response.data.etag = headerEtag;
  }
  return response.data;
}

/**
 * Replaces the full user access list (admin-only).
 * Sends the ETag via the If-Match header for optimistic concurrency.
 * Returns the new ETag from the response.
 */
export async function updateUsers(
  users: UserAccess[],
  etag: string
): Promise<string> {
  const response = await apiClient.put(
    '/api/useraccess/users',
    { users },
    { headers: { 'If-Match': etag } }
  );
  return (response.headers['etag'] as string) ?? etag;
}
