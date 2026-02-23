import { useState, useEffect, useCallback } from 'react';
import {
  Box,
  TextField,
  IconButton,
  Snackbar,
  Alert,
  Typography,
  CircularProgress,
  Tooltip,
  Button,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  DialogContentText,
} from '@mui/material';
import {
  Visibility as VisibilityIcon,
  ContentCopy as CopyIcon,
  Edit as EditIcon,
  Check as CheckIcon,
  Close as CloseIcon,
  Delete as DeleteIcon,
  Add as AddIcon,
  Refresh as RefreshIcon,
} from '@mui/icons-material';
import { DataGrid, type GridColDef } from '@mui/x-data-grid';
import { getSecrets, getSecretValue, setSecret, deleteSecret } from '../services/secretsService';
import { getMetadata, updateMetadata } from '../services/metadataService';
import { useUser } from '../auth/UserContext';
import type { SecretItemView, SecretItemMetaList } from '../types';

/** Placeholder text shown instead of the actual secret value. */
const PLACEHOLDER_VALUE = '***';

/** Extended view model with mutable client-side state for display name editing and secret reveal. */
interface SecretRow extends SecretItemView {
  displayValue: string;
  isEditingDisplayName: boolean;
  editDisplayName: string;
}

/**
 * Dashboard page — lists Key Vault secrets in a data grid.
 * Supports searching, revealing secret values, copying to clipboard,
 * inline editing of display names (persisted to blob storage via the API),
 * and create / update / delete operations for Admin users.
 */
export function Dashboard() {
  const { isAdmin } = useUser();
  const [rows, setRows] = useState<SecretRow[]>([]);
  const [filteredRows, setFilteredRows] = useState<SecretRow[]>([]);
  const [searchText, setSearchText] = useState('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  // Create / Update dialog state
  const [secretDialogOpen, setSecretDialogOpen] = useState(false);
  const [secretDialogMode, setSecretDialogMode] = useState<'create' | 'update'>('create');
  const [secretDialogName, setSecretDialogName] = useState('');
  const [secretDialogValue, setSecretDialogValue] = useState('');
  const [secretDialogSaving, setSecretDialogSaving] = useState(false);

  // Delete confirmation dialog state
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deleteTargetName, setDeleteTargetName] = useState('');
  const [deleteDialogDeleting, setDeleteDialogDeleting] = useState(false);

  // Metadata ETag for optimistic concurrency
  const [metadataEtag, setMetadataEtag] = useState<string | null>(null);

  // Load secrets on mount
  useEffect(() => {
    loadSecrets();
  }, []);

  const loadSecrets = async () => {
    setLoading(true);
    setError(null);
    try {
      const [secrets, metadataResult] = await Promise.all([
        getSecrets(),
        isAdmin ? getMetadata() : Promise.resolve(null),
      ]);

      if (metadataResult) {
        setMetadataEtag(metadataResult.etag);
      }

      const secretRows: SecretRow[] = secrets.map((s) => ({
        ...s,
        displayValue: PLACEHOLDER_VALUE,
        isEditingDisplayName: false,
        editDisplayName: s.meta.displayName ?? s.name,
      }));
      setRows(secretRows);
      setFilteredRows(secretRows);
    } catch (err) {
      if (isAxios403(err)) {
        setError('You do not have access. Please contact your administrator.');
      } else {
        setError(err instanceof Error ? err.message : 'Failed to load secrets.');
      }
    } finally {
      setLoading(false);
    }
  };

  // Client-side search filtering (3+ character threshold)
  useEffect(() => {
    if (searchText.length >= 3) {
      const lower = searchText.toLowerCase();
      setFilteredRows(
        rows.filter((r) =>
          (r.meta.displayName ?? r.name).toLowerCase().includes(lower)
        )
      );
    } else {
      setFilteredRows(rows);
    }
  }, [searchText, rows]);

  const handleShowSecret = useCallback(async (row: SecretRow) => {
    setError(null);
    setSuccess(null);
    try {
      const value = await getSecretValue(row.id);
      setRows((prev) =>
        prev.map((r) => (r.id === row.id ? { ...r, displayValue: value } : r))
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to get secret.');
    }
  }, []);

  const handleCopyToClipboard = useCallback(
    async (row: SecretRow) => {
      setError(null);
      setSuccess(null);
      try {
        let value = row.displayValue;
        if (value === PLACEHOLDER_VALUE) {
          value = await getSecretValue(row.id);
          setRows((prev) =>
            prev.map((r) =>
              r.id === row.id ? { ...r, displayValue: value } : r
            )
          );
        }
        await navigator.clipboard.writeText(value);
        setSuccess(`Copied secret for ${row.name} to clipboard`);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to copy.');
      }
    },
    []
  );

  const handleStartEdit = useCallback((row: SecretRow) => {
    setRows((prev) =>
      prev.map((r) =>
        r.id === row.id
          ? {
              ...r,
              isEditingDisplayName: true,
              editDisplayName: r.meta.displayName ?? r.name,
            }
          : r
      )
    );
  }, []);

  const handleSaveDisplayName = useCallback(async (row: SecretRow) => {
    setError(null);
    setSuccess(null);
    try {
      // Build the full metadata list from all current rows
      const metaList: SecretItemMetaList = {
        items: rows.map((r) => ({
          id: r.id,
          displayName:
            r.id === row.id ? row.editDisplayName : r.meta.displayName,
        })),
      };
      const newEtag = await updateMetadata(metaList, metadataEtag);
      setMetadataEtag(newEtag);

      setRows((prev) =>
        prev.map((r) =>
          r.id === row.id
            ? {
                ...r,
                meta: { ...r.meta, displayName: row.editDisplayName },
                isEditingDisplayName: false,
              }
            : r
        )
      );
    } catch (err) {
      if (isAxios409(err)) {
        setError('Conflict: the metadata was modified by another admin. Click reload to get the latest data.');
      } else {
        setError(
          err instanceof Error ? err.message : 'Failed to save display name.'
        );
      }
      // Revert edit state on failure
      setRows((prev) =>
        prev.map((r) =>
          r.id === row.id ? { ...r, isEditingDisplayName: false } : r
        )
      );
    }
  }, [rows, metadataEtag]);

  const handleCancelEdit = useCallback((row: SecretRow) => {
    setRows((prev) =>
      prev.map((r) =>
        r.id === row.id
          ? {
              ...r,
              isEditingDisplayName: false,
              editDisplayName: r.meta.displayName ?? r.name,
            }
          : r
      )
    );
  }, []);

  const handleEditDisplayNameChange = useCallback(
    (rowId: string, value: string) => {
      setRows((prev) =>
        prev.map((r) =>
          r.id === rowId ? { ...r, editDisplayName: value } : r
        )
      );
    },
    []
  );

  // --- Create / Update secret dialog handlers ---

  const handleOpenCreateDialog = useCallback(() => {
    setSecretDialogMode('create');
    setSecretDialogName('');
    setSecretDialogValue('');
    setSecretDialogOpen(true);
  }, []);

  const handleOpenUpdateDialog = useCallback((row: SecretRow) => {
    setSecretDialogMode('update');
    setSecretDialogName(row.name);
    setSecretDialogValue('');
    setSecretDialogOpen(true);
  }, []);

  const handleCloseSecretDialog = useCallback(() => {
    setSecretDialogOpen(false);
    setSecretDialogName('');
    setSecretDialogValue('');
  }, []);

  const handleSaveSecret = useCallback(async () => {
    setError(null);
    setSuccess(null);

    if (!secretDialogName.trim()) {
      setError('Secret name is required.');
      return;
    }

    if (!secretDialogValue) {
      setError('Secret value is required.');
      return;
    }

    setSecretDialogSaving(true);
    try {
      await setSecret(secretDialogName.trim(), secretDialogValue);
      setSuccess(
        secretDialogMode === 'create'
          ? `Secret '${secretDialogName.trim()}' created successfully.`
          : `Secret '${secretDialogName.trim()}' updated successfully.`
      );
      handleCloseSecretDialog();
      await loadSecrets();
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : `Failed to ${secretDialogMode} secret.`
      );
    } finally {
      setSecretDialogSaving(false);
    }
  }, [secretDialogName, secretDialogValue, secretDialogMode, handleCloseSecretDialog]);

  // --- Delete secret dialog handlers ---

  const handleOpenDeleteDialog = useCallback((row: SecretRow) => {
    setDeleteTargetName(row.name);
    setDeleteDialogOpen(true);
  }, []);

  const handleCloseDeleteDialog = useCallback(() => {
    setDeleteDialogOpen(false);
    setDeleteTargetName('');
  }, []);

  const handleConfirmDelete = useCallback(async () => {
    setError(null);
    setSuccess(null);
    setDeleteDialogDeleting(true);
    try {
      await deleteSecret(deleteTargetName);
      setSuccess(`Secret '${deleteTargetName}' deleted successfully.`);
      handleCloseDeleteDialog();
      await loadSecrets();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : 'Failed to delete secret.'
      );
    } finally {
      setDeleteDialogDeleting(false);
    }
  }, [deleteTargetName, handleCloseDeleteDialog]);

  const columns: GridColDef<SecretRow>[] = [
    {
      field: 'displayName',
      headerName: 'Name',
      flex: 1,
      minWidth: 200,
      renderCell: (params) => {
        const row = params.row;
        if (row.isEditingDisplayName) {
          return (
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
              <TextField
                size="small"
                value={row.editDisplayName}
                onChange={(e) =>
                  handleEditDisplayNameChange(row.id, e.target.value)
                }
                variant="outlined"
              />
              <IconButton
                size="small"
                color="primary"
                onClick={() => handleSaveDisplayName(row)}
              >
                <CheckIcon fontSize="small" />
              </IconButton>
              <IconButton
                size="small"
                onClick={() => handleCancelEdit(row)}
              >
                <CloseIcon fontSize="small" />
              </IconButton>
            </Box>
          );
        }
        return (
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
            <Typography variant="body2">
              {row.meta.displayName ?? row.name}
            </Typography>
            {isAdmin && (
              <IconButton size="small" onClick={() => handleStartEdit(row)}>
                <EditIcon fontSize="small" />
              </IconButton>
            )}
          </Box>
        );
      },
    },
    {
      field: 'displayValue',
      headerName: 'Value',
      flex: 1,
      minWidth: 200,
      renderCell: (params) => (
        <Typography
          variant="body2"
          sx={{ fontFamily: 'monospace' }}
        >
          {params.row.displayValue}
        </Typography>
      ),
    },
    {
      field: 'actions',
      headerName: 'Actions',
      width: isAdmin ? 200 : 120,
      sortable: false,
      filterable: false,
      renderCell: (params) => (
        <Box>
          <Tooltip title="Show secret">
            <IconButton
              size="small"
              onClick={() => handleShowSecret(params.row)}
            >
              <VisibilityIcon fontSize="small" />
            </IconButton>
          </Tooltip>
          <Tooltip title="Copy to clipboard">
            <IconButton
              size="small"
              onClick={() => handleCopyToClipboard(params.row)}
            >
              <CopyIcon fontSize="small" />
            </IconButton>
          </Tooltip>
          {isAdmin && (
            <>
              <Tooltip title="Update secret value">
                <IconButton
                  size="small"
                  color="primary"
                  onClick={() => handleOpenUpdateDialog(params.row)}
                >
                  <EditIcon fontSize="small" />
                </IconButton>
              </Tooltip>
              <Tooltip title="Delete secret">
                <IconButton
                  size="small"
                  color="error"
                  onClick={() => handleOpenDeleteDialog(params.row)}
                >
                  <DeleteIcon fontSize="small" />
                </IconButton>
              </Tooltip>
            </>
          )}
        </Box>
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
      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, mb: 2 }}>
        <TextField
          label="Search secrets"
          variant="outlined"
          size="small"
          sx={{ flexGrow: 1, maxWidth: 400 }}
          value={searchText}
          onChange={(e) => setSearchText(e.target.value)}
          helperText="Type at least 3 characters to filter"
        />
        <Tooltip title="Reload secrets">
          <IconButton onClick={loadSecrets}>
            <RefreshIcon />
          </IconButton>
        </Tooltip>
        {isAdmin && (
          <Button
            variant="contained"
            startIcon={<AddIcon />}
            onClick={handleOpenCreateDialog}
          >
            Create Secret
          </Button>
        )}
      </Box>

      <DataGrid
        rows={filteredRows}
        columns={columns}
        getRowId={(row) => row.id}
        pageSizeOptions={[10, 25, 50]}
        initialState={{
          pagination: { paginationModel: { pageSize: 25 } },
        }}
        disableRowSelectionOnClick
        autoHeight
      />

      {/* Create / Update Secret Dialog */}
      <Dialog
        open={secretDialogOpen}
        onClose={handleCloseSecretDialog}
        maxWidth="sm"
        fullWidth
      >
        <DialogTitle>
          {secretDialogMode === 'create' ? 'Create Secret' : 'Update Secret Value'}
        </DialogTitle>
        <DialogContent>
          <TextField
            label="Secret Name"
            fullWidth
            margin="dense"
            value={secretDialogName}
            onChange={(e) => setSecretDialogName(e.target.value)}
            disabled={secretDialogMode === 'update'}
            helperText={
              secretDialogMode === 'create'
                ? 'A unique name for the Key Vault secret (letters, digits, and hyphens).'
                : undefined
            }
          />
          <TextField
            label="Secret Value"
            fullWidth
            margin="dense"
            multiline
            minRows={2}
            value={secretDialogValue}
            onChange={(e) => setSecretDialogValue(e.target.value)}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={handleCloseSecretDialog} disabled={secretDialogSaving}>
            Cancel
          </Button>
          <Button
            onClick={handleSaveSecret}
            variant="contained"
            disabled={secretDialogSaving || !secretDialogName.trim() || !secretDialogValue}
          >
            {secretDialogSaving
              ? 'Saving...'
              : secretDialogMode === 'create'
                ? 'Create'
                : 'Update'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Delete Confirmation Dialog */}
      <Dialog open={deleteDialogOpen} onClose={handleCloseDeleteDialog}>
        <DialogTitle>Delete Secret</DialogTitle>
        <DialogContent>
          <DialogContentText>
            Are you sure you want to delete the secret <strong>{deleteTargetName}</strong>?
            This action will soft-delete the secret in Key Vault.
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={handleCloseDeleteDialog} disabled={deleteDialogDeleting}>
            Cancel
          </Button>
          <Button
            onClick={handleConfirmDelete}
            color="error"
            variant="contained"
            disabled={deleteDialogDeleting}
          >
            {deleteDialogDeleting ? 'Deleting...' : 'Delete'}
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

/** Type guard for Axios 403 errors. */
function isAxios403(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'response' in err &&
    typeof (err as { response?: { status?: number } }).response?.status ===
      'number' &&
    (err as { response: { status: number } }).response.status === 403
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
