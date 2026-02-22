import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { PublicClientApplication, EventType } from '@azure/msal-browser';
import { msalConfig, apiScopes } from './auth/msalConfig';
import { AuthProvider } from './auth/AuthProvider';
import { configureMsalInterceptor } from './services/apiClient';
import { App } from './App';

const msalInstance = new PublicClientApplication(msalConfig);

// Initialize MSAL and process any redirect response BEFORE rendering.
// This guarantees the account and tokens are available on the very first
// render cycle, preventing the 401 that occurred on first-time login.
msalInstance.initialize().then(async () => {
  // handleRedirectPromise() must be awaited so that any login redirect
  // response is fully processed (tokens cached, account available) before
  // the React tree mounts and components start making API calls.
  const redirectResponse = await msalInstance.handleRedirectPromise();
  if (redirectResponse?.account) {
    msalInstance.setActiveAccount(redirectResponse.account);
  }

  // For non-redirect scenarios (page refresh), pick the first cached account.
  if (!msalInstance.getActiveAccount()) {
    const accounts = msalInstance.getAllAccounts();
    if (accounts.length > 0) {
      msalInstance.setActiveAccount(accounts[0]);
    }
  }

  // Listen for login success events (e.g. popup login) to keep the active account current.
  msalInstance.addEventCallback((event) => {
    if (
      event.eventType === EventType.LOGIN_SUCCESS &&
      event.payload &&
      'account' in event.payload
    ) {
      const account = event.payload.account;
      if (account) {
        msalInstance.setActiveAccount(account);
      }
    }
  });

  // Install an axios interceptor that acquires a token before every API call.
  configureMsalInterceptor(msalInstance, apiScopes.scopes);

  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <AuthProvider instance={msalInstance}>
        <App />
      </AuthProvider>
    </StrictMode>
  );
});
