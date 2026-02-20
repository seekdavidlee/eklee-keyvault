import { type ReactNode } from 'react';
import {
  MsalProvider,
  AuthenticatedTemplate,
  UnauthenticatedTemplate,
  useMsal,
} from '@azure/msal-react';
import type { IPublicClientApplication } from '@azure/msal-browser';
import { Button, Box, Typography } from '@mui/material';
import { apiScopes } from './msalConfig';

interface AuthProviderProps {
  instance: IPublicClientApplication;
  children: ReactNode;
}

/**
 * Wraps the application in MsalProvider and shows a login prompt for unauthenticated users.
 */
export function AuthProvider({ instance, children }: AuthProviderProps) {
  return (
    <MsalProvider instance={instance}>
      <AuthenticatedTemplate>{children}</AuthenticatedTemplate>
      <UnauthenticatedTemplate>
        <LoginPrompt />
      </UnauthenticatedTemplate>
    </MsalProvider>
  );
}

function LoginPrompt() {
  const { instance } = useMsal();

  const handleLogin = () => {
    instance.loginRedirect(apiScopes);
  };

  return (
    <Box
      display="flex"
      flexDirection="column"
      alignItems="center"
      justifyContent="center"
      minHeight="100vh"
      gap={2}
    >
      <Typography variant="h4">KeyVault Client</Typography>
      <Typography variant="body1" color="text.secondary">
        Please sign in to access Key Vault secrets.
      </Typography>
      <Button variant="contained" onClick={handleLogin} size="large">
        Sign In
      </Button>
    </Box>
  );
}
