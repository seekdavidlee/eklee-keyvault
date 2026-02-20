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
} from '@mui/material';
import {
  Visibility as VisibilityIcon,
  ContentCopy as CopyIcon,
  Edit as EditIcon,
  Check as CheckIcon,
  Close as CloseIcon,
} from '@mui/icons-material';
import { DataGrid, type GridColDef } from '@mui/x-data-grid';
import { getSecrets, getSecretValue } from '../services/secretsService';
import { updateMetadata } from '../services/metadataService';
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
 * and inline editing of display names (persisted to blob storage via the API).
 */
export function Dashboard() {
  const [rows, setRows] = useState<SecretRow[]>([]);
  const [filteredRows, setFilteredRows] = useState<SecretRow[]>([]);
  const [searchText, setSearchText] = useState('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  // Load secrets on mount
  useEffect(() => {
    loadSecrets();
  }, []);

  const loadSecrets = async () => {
    setLoading(true);
    setError(null);
    try {
      const secrets = await getSecrets();
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
      await updateMetadata(metaList);

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
      setError(
        err instanceof Error ? err.message : 'Failed to save display name.'
      );
      // Revert edit state on failure
      setRows((prev) =>
        prev.map((r) =>
          r.id === row.id ? { ...r, isEditingDisplayName: false } : r
        )
      );
    }
  }, [rows]);

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
            <IconButton size="small" onClick={() => handleStartEdit(row)}>
              <EditIcon fontSize="small" />
            </IconButton>
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
      width: 120,
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
      <Typography variant="h5" gutterBottom>
        Dashboard
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <TextField
        label="Search secrets"
        variant="outlined"
        size="small"
        fullWidth
        sx={{ mb: 2, maxWidth: 400 }}
        value={searchText}
        onChange={(e) => setSearchText(e.target.value)}
        helperText="Type at least 3 characters to filter"
      />

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
