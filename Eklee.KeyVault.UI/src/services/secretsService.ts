import apiClient from './apiClient';
import type { SecretItemView, SecretValueResponse, SecretSetRequest, SecretSetResponse } from '../types';

/** Fetches all secrets combined with their display metadata. */
export async function getSecrets(): Promise<SecretItemView[]> {
  const response = await apiClient.get<SecretItemView[]>('/api/secrets');
  return response.data;
}

/** Retrieves the actual value of a single secret by name. */
export async function getSecretValue(name: string): Promise<string> {
  const response = await apiClient.get<SecretValueResponse>(
    `/api/secrets/${encodeURIComponent(name)}/value`
  );
  return response.data.value;
}

/** Creates or updates a Key Vault secret. Admin-only. */
export async function setSecret(name: string, value: string): Promise<string> {
  const body: SecretSetRequest = { value };
  const response = await apiClient.put<SecretSetResponse>(
    `/api/secrets/${encodeURIComponent(name)}`,
    body
  );
  return response.data.name;
}

/** Deletes a Key Vault secret by name. Admin-only. */
export async function deleteSecret(name: string): Promise<void> {
  await apiClient.delete(`/api/secrets/${encodeURIComponent(name)}`);
}
