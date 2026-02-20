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
 * Uses the API's Application ID URI for the default scope.
 */
export const apiScopes: PopupRequest = {
  scopes: [`api://${import.meta.env.VITE_AZURE_AD_CLIENT_ID}/.default`],
};
