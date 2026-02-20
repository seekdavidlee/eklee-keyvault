import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { PublicClientApplication, EventType } from '@azure/msal-browser';
import { msalConfig, apiScopes } from './auth/msalConfig';
import { AuthProvider } from './auth/AuthProvider';
import { setAuthToken } from './services/apiClient';
import { App } from './App';

const msalInstance = new PublicClientApplication(msalConfig);

// Set the active account after redirect login completes
msalInstance.initialize().then(() => {
  const accounts = msalInstance.getAllAccounts();
  if (accounts.length > 0) {
    msalInstance.setActiveAccount(accounts[0]);
  }

  // Listen for login success events to set the active account and auth token
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

  // Acquire token silently on startup and set it on the API client
  const activeAccount = msalInstance.getActiveAccount();
  if (activeAccount) {
    msalInstance
      .acquireTokenSilent({ ...apiScopes, account: activeAccount })
      .then((response) => {
        setAuthToken(response.accessToken);
      })
      .catch(() => {
        // Token acquisition failed — AuthProvider will handle re-login
      });
  }

  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <AuthProvider instance={msalInstance}>
        <App />
      </AuthProvider>
    </StrictMode>
  );
});
