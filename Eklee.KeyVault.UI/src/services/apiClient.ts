import axios from 'axios';
import type { IPublicClientApplication, AccountInfo } from '@azure/msal-browser';

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
 * Configures an axios request interceptor that acquires a Bearer token
 * via MSAL before every API call. This eliminates the race condition where
 * the app renders and fires requests before a one-time token acquisition
 * has completed (e.g. on first login redirect).
 */
export function configureMsalInterceptor(
  msalInstance: IPublicClientApplication,
  scopes: string[]
) {
  apiClient.interceptors.request.use(async (config) => {
    const account: AccountInfo | null = msalInstance.getActiveAccount();
    if (account) {
      const response = await msalInstance.acquireTokenSilent({
        scopes,
        account,
      });
      config.headers.Authorization = `Bearer ${response.accessToken}`;
    }
    return config;
  });
}

export default apiClient;
