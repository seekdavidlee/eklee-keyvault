import { useMsal } from '@azure/msal-react';
import { InteractionRequiredAuthError } from '@azure/msal-browser';
import { apiScopes } from './msalConfig';

/**
 * Custom hook that acquires an access token silently for the backend API.
 * Falls back to interactive login if silent acquisition fails.
 *
 * @returns A function that returns a Promise resolving to the access token string.
 */
export function useAuthToken() {
  const { instance, accounts } = useMsal();

  const getToken = async (): Promise<string> => {
    const account = accounts[0];
    if (!account) {
      throw new Error('No active account. Please sign in.');
    }

    try {
      const response = await instance.acquireTokenSilent({
        ...apiScopes,
        account,
      });
      return response.accessToken;
    } catch (error) {
      if (error instanceof InteractionRequiredAuthError) {
        await instance.acquireTokenRedirect(apiScopes);
        throw new Error('Redirecting to login...');
      }
      throw error;
    }
  };

  return getToken;
}
