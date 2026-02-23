import type { Configuration, PopupRequest } from '@azure/msal-browser';
import { config } from '../config';

/**
 * MSAL configuration for Azure AD authentication.
 * Reads from runtime config (injected at container startup) with fallback
 * to Vite environment variables for local development.
 */
export const msalConfig: Configuration = {
  auth: {
    clientId: config.AZURE_AD_CLIENT_ID,
    authority: config.AZURE_AD_AUTHORITY,
    redirectUri: config.AZURE_AD_REDIRECT_URI,
    postLogoutRedirectUri: config.AZURE_AD_REDIRECT_URI,
  },
  cache: {
    cacheLocation: 'sessionStorage',
  },
};

/**
 * Scopes requested when acquiring tokens for the backend API.
 * When the SPA shares a client ID with the API (single app registration),
 * Azure AD requires the GUID-based scope format instead of the api:// URI.
 */
export const apiScopes: PopupRequest = {
  scopes: [`${config.AZURE_AD_CLIENT_ID}/access_as_user`],
};
