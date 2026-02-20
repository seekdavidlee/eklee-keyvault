import { Box, Typography, Alert } from '@mui/material';

/**
 * Displayed when the user is authenticated via Entra ID but is not registered
 * in the user access list. Instructs the user to contact an administrator.
 */
export function AccessDenied() {
  return (
    <Box sx={{ mt: 4, maxWidth: 600, mx: 'auto' }}>
      <Alert severity="warning" sx={{ mb: 2 }}>
        Access Denied
      </Alert>
      <Typography variant="h5" gutterBottom>
        You do not have access
      </Typography>
      <Typography variant="body1" color="text.secondary">
        You have been authenticated, but your account is not registered for
        access to this application. Please contact your administrator to
        request access.
      </Typography>
    </Box>
  );
}
