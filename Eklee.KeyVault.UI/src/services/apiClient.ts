import axios from 'axios';
import type { IPublicClientApplication } from '@azure/msal-browser';
import { InteractionRequiredAuthError } from '@azure/msal-browser';

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
 * components fire requests before a one-time token acquisition has completed.
 *
 * If no active account exists, the user is redirected to login.
 * If silent token acquisition fails due to interaction being required
 * (e.g. expired refresh token, revoked consent), the user is also redirected.
 */
export function configureMsalInterceptor(
  msalInstance: IPublicClientApplication,
  scopes: string[]
) {
  apiClient.interceptors.request.use(async (config) => {
    const account = msalInstance.getActiveAccount();
    if (!account) {
      // No cached account — force interactive login so the user
      // doesn't receive silent 401 failures.
      await msalInstance.acquireTokenRedirect({ scopes });
      // acquireTokenRedirect navigates away; this line is not reached.
      return config;
    }

    try {
      const response = await msalInstance.acquireTokenSilent({
        scopes,
        account,
      });
      config.headers.Authorization = `Bearer ${response.accessToken}`;
    } catch (error) {
      if (error instanceof InteractionRequiredAuthError) {
        // Redirect the user to re-authenticate; the page will reload and
        // handleRedirectPromise() in main.tsx will pick up the new tokens.
        await msalInstance.acquireTokenRedirect({ scopes });
      }
      throw error;
    }
    return config;
  });
}

export default apiClient;
