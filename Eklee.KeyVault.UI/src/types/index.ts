/** Shared category whose stable ID and default designation survive renaming. */
export interface CategoryItem {
  id: string;
  name: string;
  isDefault: boolean;
}

/** User-defined display metadata and persisted category association for a secret. */
export interface SecretItemMeta {
  id: string | null;
  displayName: string | null;
  /** Null or missing only in legacy metadata awaiting startup migration. */
  categoryId?: string | null;
}

/** Complete shared metadata document; display-name edits must preserve its inventory. */
export interface SecretItemMetaList {
  items: SecretItemMeta[] | null;
  categories?: CategoryItem[];
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

/** Request body for creating or updating a Key Vault secret via PUT /api/secrets/{name}. */
export interface SecretSetRequest {
  value: string;
  /** Required when creating a secret; an existing association cannot be changed. */
  categoryId?: string;
}

/** Response from PUT /api/secrets/{name}. */
export interface SecretSetResponse {
  name: string;
}

/** Policy used to request a generated secret candidate from the API. */
export interface SecretGenerationRequest {
  totalLength: number;
  minimumAlphabeticCharacters: number;
  minimumNumericCharacters: number;
  minimumSpecialCharacters: number;
}

/** Candidate secret value returned by the API without persisting it. */
export interface SecretGenerationResponse {
  value: string;
}

/** Problem-details response returned for a failed API request. */
export interface ApiProblemDetails {
  detail?: string;
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
