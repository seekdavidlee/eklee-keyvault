import type { Configuration, PopupRequest } from '@azure/msal-browser';

/**
 * MSAL configuration for Azure AD authentication.
 * Reads client ID, authority, and redirect URI from Vite environment variables.
 */
export const msalConfig: Configuration = {
  auth: {
    clientId: import.meta.env.VITE_AZURE_AD_CLIENT_ID,
    authority: import.meta.env.VITE_AZURE_AD_AUTHORITY,
    redirectUri: import.meta.env.VITE_AZURE_AD_REDIRECT_URI,
    postLogoutRedirectUri: import.meta.env.VITE_AZURE_AD_REDIRECT_URI,
  },
  cache: {
    cacheLocation: 'sessionStorage',
    storeAuthStateInCookie: false,
  },
};

/**
 * Scopes requested when acquiring tokens for the backend API.
 * When the SPA shares a client ID with the API (single app registration),
 * Azure AD requires the GUID-based scope format instead of the api:// URI.
 */
export const apiScopes: PopupRequest = {
  scopes: [`${import.meta.env.VITE_AZURE_AD_CLIENT_ID}/access_as_user`],
};
