/** User-defined display metadata for a Key Vault secret. */
export interface SecretItemMeta {
  id: string | null;
  displayName: string | null;
}

/** Collection of secret metadata with an items array. */
export interface SecretItemMetaList {
  items: SecretItemMeta[] | null;
}

/** Combined view of a Key Vault secret with display metadata, returned by GET /api/secrets. */
export interface SecretItemView {
  id: string;
  name: string;
  meta: SecretItemMeta;
}

/** Response wrapper for a secret value from GET /api/secrets/{name}/value. */
export interface SecretValueResponse {
  value: string;
}

/** Authorization role for a user in the application. */
export type UserRole = 'Admin' | 'User';

/** A single user's access record from user_access.json. */
export interface UserAccess {
  objectId: string | null;
  email: string | null;
  role: UserRole;
  createdAt: string;
}

/** API response for the full user access list, including the blob ETag for concurrency. */
export interface UserAccessResponse {
  etag: string | null;
  users: UserAccess[];
}
