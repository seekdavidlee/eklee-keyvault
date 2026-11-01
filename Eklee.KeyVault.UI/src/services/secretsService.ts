import apiClient from './apiClient';
import type {
  SecretGenerationRequest,
  SecretGenerationResponse,
  SecretItemView,
  SecretSetRequest,
  SecretSetResponse,
  SecretValueResponse,
} from '../types';

/** Fetches secret metadata, optionally restricted to a persisted category ID. */
export async function getSecrets(categoryId?: string): Promise<SecretItemView[]> {
  const response = await apiClient.get<SecretItemView[]>('/api/secrets', {
    params: categoryId === undefined ? undefined : { categoryId },
  });
  return response.data;
}

/** Retrieves the actual value of a single secret by name. */
export async function getSecretValue(name: string): Promise<string> {
  const response = await apiClient.get<SecretValueResponse>(
    `/api/secrets/${encodeURIComponent(name)}/value`
  );
  return response.data.value;
}

/** Creates or updates a secret. Creation requires a category; updates cannot move it. Admin-only. */
export async function setSecret(name: string, value: string, categoryId?: string): Promise<string> {
  const body: SecretSetRequest = { value, ...(categoryId === undefined ? {} : { categoryId }) };
  const response = await apiClient.put<SecretSetResponse>(
    `/api/secrets/${encodeURIComponent(name)}`,
    body
  );
  return response.data.name;
}

/** Generates a candidate secret value without persisting it. Admin-only. */
export async function generateSecret(request: SecretGenerationRequest): Promise<string> {
  const response = await apiClient.post<SecretGenerationResponse>(
    '/api/secrets/generate',
    request
  );
  return response.data.value;
}

/** Deletes a Key Vault secret by name. Admin-only. */
export async function deleteSecret(name: string): Promise<void> {
  await apiClient.delete(`/api/secrets/${encodeURIComponent(name)}`);
}
