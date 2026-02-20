import axios from 'axios';

/**
 * Axios instance for communicating with the Eklee KeyVault API.
 * The base URL is configured via VITE_API_BASE_URL environment variable.
 * During development, Vite's proxy forwards /api requests to the backend,
 * so an empty base URL works with the proxy configuration.
 */
const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || '',
  headers: {
    'Content-Type': 'application/json',
  },
});

/**
 * Sets the Authorization header with a Bearer token for all subsequent requests.
 * Called after MSAL acquires a token.
 */
export function setAuthToken(token: string) {
  apiClient.defaults.headers.common['Authorization'] = `Bearer ${token}`;
}

export default apiClient;
