import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { CssBaseline, ThemeProvider, createTheme } from '@mui/material';
import { AppLayout } from './components/Layout/AppLayout';
import { Dashboard } from './pages/Dashboard';

const theme = createTheme({
  palette: {
    mode: 'light',
  },
});

/**
 * Root application component.
 * Sets up MUI theme, routing, and the main layout.
 * All routes are protected — AuthProvider in main.tsx handles unauthenticated users.
 */
export function App() {
  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <BrowserRouter>
        <AppLayout>
          <Routes>
            <Route path="/" element={<Dashboard />} />
          </Routes>
        </AppLayout>
      </BrowserRouter>
    </ThemeProvider>
  );
}
