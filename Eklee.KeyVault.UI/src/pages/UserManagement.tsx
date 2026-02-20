import { useState, useEffect, useCallback } from 'react';
import {
  Box,
  TextField,
  Button,
  Alert,
  Snackbar,
  Typography,
  CircularProgress,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  MenuItem,
  Select,
  IconButton,
  Tooltip,
  type SelectChangeEvent,
} from '@mui/material';
import {
  Delete as DeleteIcon,
  Add as AddIcon,
  Refresh as RefreshIcon,
} from '@mui/icons-material';
import { DataGrid, type GridColDef } from '@mui/x-data-grid';
import { getUsers, updateUsers } from '../services/userAccessService';
import type { UserAccess, UserRole } from '../types';

/**
 * Admin page for managing user access.
 * Displays all registered users in a data grid with role editing, user removal,
 * and the ability to add new users. Uses blob ETags for optimistic concurrency.
 */
export function UserManagement() {
  const [users, setUsers] = useState<UserAccess[]>([]);
  const [etag, setEtag] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);

  // Add-user dialog state
  const [addDialogOpen, setAddDialogOpen] = useState(false);
  const [newEmail, setNewEmail] = useState('');
  const [newRole, setNewRole] = useState<UserRole>('User');

  const loadUsers = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await getUsers();
      setUsers(response.users);
      setEtag(response.etag);
      setDirty(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load users.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadUsers();
  }, [loadUsers]);

  const handleRoleChange = useCallback((objectId: string | null, newRoleValue: UserRole) => {
    setUsers((prev) =>
      prev.map((u) =>
        u.objectId === objectId ? { ...u, role: newRoleValue } : u
      )
    );
    setDirty(true);
  }, []);

  const handleDeleteUser = useCallback((objectId: string | null) => {
    setUsers((prev) => prev.filter((u) => u.objectId !== objectId));
    setDirty(true);
  }, []);

  const handleAddUser = useCallback(() => {
    if (!newEmail.trim()) return;

    const user: UserAccess = {
      objectId: null,
      email: newEmail.trim(),
      role: newRole,
      createdAt: new Date().toISOString(),
    };

    setUsers((prev) => [...prev, user]);
    setDirty(true);
    setAddDialogOpen(false);
    setNewEmail('');
    setNewRole('User');
  }, [newEmail, newRole]);

  const handleSave = useCallback(async () => {
    setError(null);
    setSuccess(null);

    // Client-side validation: at least one admin
    if (!users.some((u) => u.role === 'Admin')) {
      setError('At least one user must have the Admin role.');
      return;
    }

    if (etag === null) {
      setError('Cannot save: no ETag available. Please reload.');
      return;
    }

    setSaving(true);
    try {
      const newEtag = await updateUsers(users, etag);
      setEtag(newEtag);
      setDirty(false);
      setSuccess('User access list saved successfully.');
    } catch (err: unknown) {
      if (isAxios409(err)) {
        setError(
          'Conflict: the user list was modified by another admin. Click Reload to get the latest data.'
        );
      } else {
        setError(err instanceof Error ? err.message : 'Failed to save.');
      }
    } finally {
      setSaving(false);
    }
  }, [users, etag]);

  const columns: GridColDef<UserAccess>[] = [
    {
      field: 'email',
      headerName: 'Email',
      flex: 1,
      minWidth: 250,
    },
    {
      field: 'objectId',
      headerName: 'Object ID',
      flex: 1,
      minWidth: 280,
      renderCell: (params) => (
        <Typography variant="body2" sx={{ fontFamily: 'monospace', fontSize: '0.8rem' }}>
          {params.value ?? '(pending first login)'}
        </Typography>
      ),
    },
    {
      field: 'role',
      headerName: 'Role',
      width: 150,
      renderCell: (params) => (
        <Select
          size="small"
          value={params.row.role}
          onChange={(e: SelectChangeEvent) =>
            handleRoleChange(params.row.objectId, e.target.value as UserRole)
          }
          variant="standard"
        >
          <MenuItem value="Admin">Admin</MenuItem>
          <MenuItem value="User">User</MenuItem>
        </Select>
      ),
    },
    {
      field: 'createdAt',
      headerName: 'Created',
      width: 180,
      renderCell: (params) => (
        <Typography variant="body2">
          {new Date(params.value as string).toLocaleDateString()}
        </Typography>
      ),
    },
    {
      field: 'actions',
      headerName: 'Actions',
      width: 80,
      sortable: false,
      filterable: false,
      renderCell: (params) => (
        <Tooltip title="Remove user">
          <IconButton
            size="small"
            color="error"
            onClick={() => handleDeleteUser(params.row.objectId)}
          >
            <DeleteIcon fontSize="small" />
          </IconButton>
        </Tooltip>
      ),
    },
  ];

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" mt={4}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 2 }}>
        User Management
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Box sx={{ display: 'flex', gap: 1, mb: 2 }}>
        <Button
          variant="contained"
          startIcon={<AddIcon />}
          onClick={() => setAddDialogOpen(true)}
        >
          Add User
        </Button>
        <Button
          variant="outlined"
          startIcon={<RefreshIcon />}
          onClick={loadUsers}
        >
          Reload
        </Button>
        <Button
          variant="contained"
          color="success"
          onClick={handleSave}
          disabled={!dirty || saving}
        >
          {saving ? 'Saving...' : 'Save Changes'}
        </Button>
      </Box>

      <DataGrid
        rows={users}
        columns={columns}
        getRowId={(row) => row.objectId ?? row.email ?? Math.random().toString()}
        pageSizeOptions={[10, 25]}
        initialState={{
          pagination: { paginationModel: { pageSize: 10 } },
        }}
        disableRowSelectionOnClick
        autoHeight
      />

      {/* Add User Dialog */}
      <Dialog
        open={addDialogOpen}
        onClose={() => setAddDialogOpen(false)}
        maxWidth="sm"
        fullWidth
      >
        <DialogTitle>Add User</DialogTitle>
        <DialogContent>
          <TextField
            label="Email / UPN"
            fullWidth
            value={newEmail}
            onChange={(e) => setNewEmail(e.target.value)}
            sx={{ mt: 1, mb: 2 }}
            helperText="The user's email address or User Principal Name from Entra ID"
          />
          <Select
            fullWidth
            value={newRole}
            onChange={(e: SelectChangeEvent) => setNewRole(e.target.value as UserRole)}
          >
            <MenuItem value="User">User</MenuItem>
            <MenuItem value="Admin">Admin</MenuItem>
          </Select>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAddDialogOpen(false)}>Cancel</Button>
          <Button
            variant="contained"
            onClick={handleAddUser}
            disabled={!newEmail.trim()}
          >
            Add
          </Button>
        </DialogActions>
      </Dialog>

      <Snackbar
        open={!!success}
        autoHideDuration={4000}
        onClose={() => setSuccess(null)}
        anchorOrigin={{ vertical: 'bottom', horizontal: 'center' }}
      >
        <Alert severity="success" onClose={() => setSuccess(null)}>
          {success}
        </Alert>
      </Snackbar>
    </Box>
  );
}

/** Type guard for Axios 409 Conflict errors. */
function isAxios409(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'response' in err &&
    typeof (err as { response?: { status?: number } }).response?.status ===
      'number' &&
    (err as { response: { status: number } }).response.status === 409
  );
}
