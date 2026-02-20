import { useState, type ReactNode } from 'react';
import {
  AppBar,
  Box,
  Drawer,
  IconButton,
  Toolbar,
  Typography,
  Button,
} from '@mui/material';
import { Menu as MenuIcon } from '@mui/icons-material';
import { useMsal } from '@azure/msal-react';
import { Sidebar } from './Sidebar';

const DRAWER_WIDTH = 240;

interface AppLayoutProps {
  children: ReactNode;
}

/**
 * Main application layout with AppBar, collapsible sidebar drawer, content area, and footer.
 * Mirrors the original Blazor MainLayout: header shows app title + user display name + sign out,
 * sidebar shows navigation, and footer shows configurable text.
 */
export function AppLayout({ children }: AppLayoutProps) {
  const { instance, accounts } = useMsal();
  const [drawerOpen, setDrawerOpen] = useState(true);

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
          <IconButton
            color="inherit"
            edge="start"
            onClick={() => setDrawerOpen(!drawerOpen)}
            sx={{ mr: 2 }}
          >
            <MenuIcon />
          </IconButton>
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

      {/* Sidebar drawer */}
      <Drawer
        variant="persistent"
        open={drawerOpen}
        sx={{
          width: drawerOpen ? DRAWER_WIDTH : 0,
          flexShrink: 0,
          '& .MuiDrawer-paper': {
            width: DRAWER_WIDTH,
            boxSizing: 'border-box',
          },
        }}
      >
        <Toolbar /> {/* Spacer for AppBar height */}
        <Sidebar />
      </Drawer>

      {/* Main content area */}
      <Box
        component="main"
        sx={{
          flexGrow: 1,
          display: 'flex',
          flexDirection: 'column',
          ml: drawerOpen ? 0 : `-${DRAWER_WIDTH}px`,
          transition: 'margin 225ms cubic-bezier(0.4, 0, 0.6, 1)',
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
