import apiClient from './apiClient';
import type { SecretItemView, SecretValueResponse } from '../types';

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
