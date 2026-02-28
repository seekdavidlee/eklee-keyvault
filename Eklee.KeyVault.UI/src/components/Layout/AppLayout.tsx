import { type ReactNode } from 'react';
import {
  AppBar,
  Box,
  Chip,
  Drawer,
  Toolbar,
  Typography,
  Button,
  useMediaQuery,
  useTheme,
} from '@mui/material';
import { useMsal } from '@azure/msal-react';
import { useUser } from '../../auth/UserContext';
import { Sidebar } from './Sidebar';
import { MobileNav } from './MobileNav';

/** Width of the sidebar navigation drawer in pixels. */
const DRAWER_WIDTH = 220;

interface AppLayoutProps {
  children: ReactNode;
}

/**
 * Main application layout with AppBar, sidebar drawer, content area, and footer.
 * Header shows app title + user display name + role badge + sign out.
 */
export function AppLayout({ children }: AppLayoutProps) {
  const { instance, accounts } = useMsal();
  const { role, accessDenied } = useUser();

  const displayName = accounts[0]?.name ?? 'Unknown';
  const username = accounts[0]?.username ?? 'Unknown';

  const header = 'KeyVault Client';
  const footer = 'KeyVault Client 2024';

  const handleSignOut = () => {
    instance.logoutRedirect();
  };

  const showSidebar = !accessDenied && role !== null;

  const theme = useTheme();
  const isMobile = useMediaQuery(theme.breakpoints.down('md'));

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
          {role && (
            <Chip
              label={role}
              size="small"
              color={role === 'Admin' ? 'warning' : 'default'}
              sx={{ mr: 2 }}
            />
          )}
          <Typography variant="body2" sx={{ mr: 2 }}>
            {displayName}
          </Typography>
          <Button color="inherit" onClick={handleSignOut}>
            Sign Out
          </Button>
        </Toolbar>
      </AppBar>

      {/* Sidebar drawer — only shown on desktop when the user has access */}
      {showSidebar && !isMobile && (
        <Drawer
          variant="permanent"
          sx={{
            width: DRAWER_WIDTH,
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
      )}

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

        {/* Mobile navigation dropdown — shown on small screens */}
        {showSidebar && isMobile && <MobileNav />}

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
