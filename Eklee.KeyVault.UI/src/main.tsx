import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { PublicClientApplication, EventType } from '@azure/msal-browser';
import { msalConfig, apiScopes } from './auth/msalConfig';
import { AuthProvider } from './auth/AuthProvider';
import { configureMsalInterceptor } from './services/apiClient';
import { App } from './App';

const msalInstance = new PublicClientApplication(msalConfig);

// Set the active account after redirect login completes
msalInstance.initialize().then(() => {
  const accounts = msalInstance.getAllAccounts();
  if (accounts.length > 0) {
    msalInstance.setActiveAccount(accounts[0]);
  }

  // Listen for login success events to set the active account
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
  // This avoids the race condition on first login where the app renders
  // before a one-shot token acquisition completes.
  configureMsalInterceptor(msalInstance, apiScopes.scopes);

  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <AuthProvider instance={msalInstance}>
        <App />
      </AuthProvider>
    </StrictMode>
  );
});
