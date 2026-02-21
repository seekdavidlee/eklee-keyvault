import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { CssBaseline, ThemeProvider, createTheme, CircularProgress, Box } from '@mui/material';
import { AppLayout } from './components/Layout/AppLayout';
import { UserProvider, useUser } from './auth/UserContext';
import { Dashboard } from './pages/Dashboard';
import { UserManagement } from './pages/UserManagement';
import { AccessDenied } from './pages/AccessDenied';

const theme = createTheme({
  palette: {
    mode: 'light',
  },
});

/**
 * Inner routing component that reads user context to handle access-denied
 * redirects and role-gated routes.
 */
function AppRoutes() {
  const { loading, accessDenied, isAdmin } = useUser();

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" mt={4}>
        <CircularProgress />
      </Box>
    );
  }

  if (accessDenied) {
    return (
      <Routes>
        <Route path="*" element={<AccessDenied />} />
      </Routes>
    );
  }

  return (
    <Routes>
      <Route path="/" element={<Dashboard />} />
      {isAdmin && <Route path="/users" element={<UserManagement />} />}
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}

/**
 * Root application component.
 * Sets up MUI theme, routing, user context, and the main layout.
 * All routes are protected — AuthProvider in main.tsx handles unauthenticated users.
 */
export function App() {
  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <BrowserRouter>
        <UserProvider>
          <AppLayout>
            <AppRoutes />
          </AppLayout>
        </UserProvider>
      </BrowserRouter>
    </ThemeProvider>
  );
}
