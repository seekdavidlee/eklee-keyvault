import { type ReactNode } from 'react';
import {
  AppBar,
  Box,
  Toolbar,
  Typography,
  Button,
} from '@mui/material';
import { useMsal } from '@azure/msal-react';

interface AppLayoutProps {
  children: ReactNode;
}

/**
 * Main application layout with AppBar, content area, and footer.
 * Header shows app title + user display name + sign out.
 */
export function AppLayout({ children }: AppLayoutProps) {
  const { instance, accounts } = useMsal();

  const displayName = accounts[0]?.name ?? 'Unknown';
  const username = accounts[0]?.username ?? 'Unknown';

  const header = 'KeyVault Client';
  const footer = 'KeyVault Client 2024';

  const handleSignOut = () => {
    instance.logoutRedirect();
  };

  return (
    <Box sx={{ display: 'flex', minHeight: '100vh' }}>
      {/* Top navigation bar */}
      <AppBar
        position="fixed"
        sx={{ zIndex: (theme) => theme.zIndex.drawer + 1 }}
      >
        <Toolbar>
          <Typography variant="h6" noWrap sx={{ flexGrow: 1 }}>
            {header} - {username}
          </Typography>
          <Typography variant="body2" sx={{ mr: 2 }}>
            {displayName}
          </Typography>
          <Button color="inherit" onClick={handleSignOut}>
            Sign Out
          </Button>
        </Toolbar>
      </AppBar>

      {/* Main content area */}
      <Box
        component="main"
        sx={{
          flexGrow: 1,
          display: 'flex',
          flexDirection: 'column',
        }}
      >
        <Toolbar /> {/* Spacer for AppBar height */}
        <Box sx={{ flexGrow: 1, p: 3 }}>{children}</Box>

        {/* Footer */}
        {footer && (
          <Box
            component="footer"
            sx={{
              py: 2,
              px: 3,
              textAlign: 'center',
              borderTop: 1,
              borderColor: 'divider',
            }}
          >
            <Typography variant="body2" color="text.secondary">
              {footer}
            </Typography>
          </Box>
        )}
      </Box>
    </Box>
  );
}
