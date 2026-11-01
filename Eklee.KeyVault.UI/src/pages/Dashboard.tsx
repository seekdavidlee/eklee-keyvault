import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { isAxiosError } from 'axios';
import { Link } from 'react-router-dom';
import {
  Accordion,
  AccordionDetails,
  AccordionSummary,
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
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  MenuItem,
  useMediaQuery,
  useTheme,
} from '@mui/material';
import {
  Visibility as VisibilityIcon,
  ContentCopy as CopyIcon,
  Edit as EditIcon,
  Check as CheckIcon,
  Close as CloseIcon,
  Delete as DeleteIcon,
  Add as AddIcon,
  ExpandMore as ExpandMoreIcon,
  Refresh as RefreshIcon,
  ArrowBack as ArrowBackIcon,
  Folder as FolderIcon,
} from '@mui/icons-material';
import { DataGrid, type GridColDef } from '@mui/x-data-grid';
import { deleteSecret, generateSecret, getSecrets, getSecretValue, setSecret } from '../services/secretsService';
import { getMetadata, updateMetadata } from '../services/metadataService';
import { getCategories } from '../services/categoriesService';
import { useUser } from '../auth/UserContext';
import type { ApiProblemDetails, CategoryItem, SecretGenerationRequest, SecretItemMetaList, SecretItemView } from '../types';

/** Placeholder text shown instead of the actual secret value. */
const PLACEHOLDER_VALUE = '***';

const DEFAULT_SECRET_GENERATION_POLICY: SecretGenerationRequest = {
  totalLength: 15,
  minimumAlphabeticCharacters: 1,
  minimumNumericCharacters: 1,
  minimumSpecialCharacters: 3,
};

function getSecretGenerationErrorMessage(error: unknown): string {
  if (isAxiosError<ApiProblemDetails>(error) && error.response?.data.detail) {
    return error.response.data.detail;
  }

  return error instanceof Error ? error.message : 'Failed to generate secret.';
}

/** Extended view model with mutable client-side state for display name editing and secret reveal. */
interface SecretRow extends SecretItemView {
  displayValue: string;
  isEditingDisplayName: boolean;
  editDisplayName: string;
}

/** Category-first navigation; selecting a category mounts an isolated secret table. */
export function Dashboard() {
  const { isAdmin } = useUser();
  const [categories, setCategories] = useState<CategoryItem[]>([]);
  const [selected, setSelected] = useState<CategoryItem | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let ignore = false;
    getCategories().then((result) => {
      if (!ignore) setCategories(result);
    }).catch((failure: unknown) => {
      if (!ignore) setError(isAxios403(failure)
        ? 'You do not have access. Please contact your administrator.'
        : isAxiosError<ApiProblemDetails>(failure) && failure.response?.data.detail
          ? failure.response.data.detail : failure instanceof Error ? failure.message : 'Unable to load categories.');
    }).finally(() => {
      if (!ignore) setLoading(false);
    });
    return () => { ignore = true; };
  }, [reload]);

  if (selected) {
    return (
      <Box>
        <Button startIcon={<ArrowBackIcon />} onClick={() => setSelected(null)} sx={{ mb: 2 }}>
          Back to categories
        </Button>
        <Typography variant="h5" component="h1" sx={{ mb: 2, overflowWrap: 'anywhere' }}>{selected.name}</Typography>
        <CategorySecrets key={selected.id} category={selected} categories={categories} />
      </Box>
    );
  }

  return (
    <Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, flexWrap: 'wrap', mb: 2 }}>
        <Typography variant="h5" component="h1" sx={{ flexGrow: 1 }}>Categories</Typography>
        <Tooltip title="Reload categories"><IconButton aria-label="Reload categories" disabled={loading}
          onClick={() => { setLoading(true); setError(null); setReload((current) => current + 1); }}>
          <RefreshIcon />
        </IconButton></Tooltip>
        {isAdmin && <Button component={Link} to="/categories" startIcon={<FolderIcon />}>Manage Categories</Button>}
      </Box>
      {error && <Alert severity="error">{error}</Alert>}
      {loading ? <CircularProgress aria-label="Loading categories" /> : (
        <List aria-label="Categories">
          {[...categories].sort((first, second) => first.name.localeCompare(second.name)).map((category) => (
            <ListItemButton key={category.id} onClick={() => setSelected(category)}>
              <ListItemIcon><FolderIcon /></ListItemIcon>
              <ListItemText primary={category.name} secondary={category.isDefault ? 'Default category' : undefined}
                sx={{ minWidth: 0, overflowWrap: 'anywhere' }} />
            </ListItemButton>
          ))}
          {!categories.length && !error && <Typography>No categories available.</Typography>}
        </List>
      )}
    </Box>
  );
}

function CategorySecrets({ category, categories }: { category: CategoryItem; categories: CategoryItem[] }) {
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
  const [secretDialogCategoryId, setSecretDialogCategoryId] = useState(category.id);
  const [secretDialogSaving, setSecretDialogSaving] = useState(false);
  const [secretDialogGenerating, setSecretDialogGenerating] = useState(false);
  const [secretGenerationError, setSecretGenerationError] = useState<string | null>(null);
  const [secretGenerationPolicy, setSecretGenerationPolicy] = useState<SecretGenerationRequest>(
    DEFAULT_SECRET_GENERATION_POLICY
  );
  const secretGenerationInProgress = useRef(false);

  // Delete confirmation dialog state
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deleteTargetName, setDeleteTargetName] = useState('');
  const [deleteDialogDeleting, setDeleteDialogDeleting] = useState(false);

  const active = useRef(false);
  const requestVersion = useRef(0);

  // Mobile actions dialog state
  const [mobileActionsOpen, setMobileActionsOpen] = useState(false);
  const [mobileActionsRow, setMobileActionsRow] = useState<SecretRow | null>(null);
  const [mobileViewValue, setMobileViewValue] = useState<string | null>(null);

  const theme = useTheme();
  const isMobile = useMediaQuery(theme.breakpoints.down('md'));

  const handleOpenMobileActions = useCallback((row: SecretRow) => {
    setMobileActionsRow(row);
    setMobileViewValue(null);
    setMobileActionsOpen(true);
  }, []);

  const handleCloseMobileActions = useCallback(() => {
    setMobileActionsOpen(false);
    setMobileActionsRow(null);
    setMobileViewValue(null);
  }, []);

  const handleMobileView = useCallback(async (row: SecretRow) => {
    try {
      const value = await getSecretValue(row.id);
      setMobileViewValue(value);
      setRows((prev) =>
        prev.map((r) => (r.id === row.id ? { ...r, displayValue: value } : r))
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to get secret.');
      handleCloseMobileActions();
    }
  }, [handleCloseMobileActions]);

  const loadSecrets = useCallback(async () => {
    if (!active.current) return;
    const version = ++requestVersion.current;
    setLoading(true);
    setError(null);
    try {
      const secrets = await getSecrets(category.id);
      if (!active.current || version !== requestVersion.current) return;
      const secretRows: SecretRow[] = secrets.filter((secret) => secret.meta.categoryId === category.id).map((s) => ({
        ...s,
        displayValue: PLACEHOLDER_VALUE,
        isEditingDisplayName: false,
        editDisplayName: s.meta.displayName ?? s.name,
      }));
      setRows(secretRows);
      setFilteredRows(secretRows);
    } catch (err) {
      if (!active.current || version !== requestVersion.current) return;
      if (isAxios403(err)) {
        setError('You do not have access. Please contact your administrator.');
      } else {
        setError(err instanceof Error ? err.message : 'Failed to load secrets.');
      }
    } finally {
      if (active.current && version === requestVersion.current) setLoading(false);
    }
  }, [category.id]);

  useEffect(() => {
    active.current = true;
    void loadSecrets();
    return () => { active.current = false; };
  }, [loadSecrets]);

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
      const current = await getMetadata();
      const item = current.metaList.items?.find((entry) => entry.id?.toLowerCase() === row.id.toLowerCase());
      if (!item || item.displayName !== row.meta.displayName) {
        throw new Error('Conflict: the metadata changed. Reload before editing the display name.');
      }
      const metaList: SecretItemMetaList = {
        ...current.metaList,
        items: current.metaList.items!.map((entry) => entry === item
          ? { ...entry, displayName: row.editDisplayName } : entry),
      };
      await updateMetadata(metaList, current.etag);

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
  }, []);

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
    setSecretDialogCategoryId(category.id);
    setSecretGenerationError(null);
    setSecretGenerationPolicy(DEFAULT_SECRET_GENERATION_POLICY);
    secretGenerationInProgress.current = false;
    setSecretDialogGenerating(false);
    setSecretDialogOpen(true);
  }, [category.id]);

  const handleOpenUpdateDialog = useCallback((row: SecretRow) => {
    setSecretDialogMode('update');
    setSecretDialogName(row.name);
    setSecretDialogValue('');
    setSecretGenerationError(null);
    setSecretGenerationPolicy(DEFAULT_SECRET_GENERATION_POLICY);
    secretGenerationInProgress.current = false;
    setSecretDialogGenerating(false);
    setSecretDialogOpen(true);
  }, []);

  const handleCloseSecretDialog = useCallback(() => {
    if (secretGenerationInProgress.current) {
      return;
    }

    setSecretDialogOpen(false);
    setSecretDialogName('');
    setSecretDialogValue('');
    setSecretGenerationError(null);
    setSecretGenerationPolicy(DEFAULT_SECRET_GENERATION_POLICY);
  }, []);

  const handleGenerateSecret = useCallback(async () => {
    setError(null);
    setSuccess(null);
    setSecretGenerationError(null);
    secretGenerationInProgress.current = true;
    setSecretDialogGenerating(true);

    try {
      const generatedValue = await generateSecret(secretGenerationPolicy);
      setSecretDialogValue(generatedValue);
    } catch (err) {
      setSecretGenerationError(getSecretGenerationErrorMessage(err));
    } finally {
      secretGenerationInProgress.current = false;
      setSecretDialogGenerating(false);
    }
  }, [secretGenerationPolicy]);

  const handleSecretGenerationPolicyChange = useCallback(
    (field: keyof SecretGenerationRequest, value: string) => {
      const numericValue = Number(value);
      setSecretGenerationError(null);
      setSecretGenerationPolicy((currentPolicy) => ({
        ...currentPolicy,
        [field]: Number.isFinite(numericValue) ? numericValue : 0,
      }));
    },
    []
  );

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

    if (secretDialogMode === 'create' && !secretDialogCategoryId) {
      setError('Select a category for the new secret.');
      return;
    }

    setSecretDialogSaving(true);
    try {
      await setSecret(secretDialogName.trim(), secretDialogValue,
        secretDialogMode === 'create' ? secretDialogCategoryId : undefined);
      setSuccess(
        secretDialogMode === 'create'
          ? `Secret '${secretDialogName.trim()}' created successfully.`
          : `Secret '${secretDialogName.trim()}' updated successfully.`
      );
      handleCloseSecretDialog();
      await loadSecrets();
    } catch (err) {
      setError(
        isAxiosError<ApiProblemDetails>(err) && err.response?.data.detail
          ? err.response.data.detail : err instanceof Error ? err.message : `Failed to ${secretDialogMode} secret.`
      );
    } finally {
      setSecretDialogSaving(false);
    }
  }, [secretDialogName, secretDialogValue, secretDialogMode, secretDialogCategoryId, handleCloseSecretDialog, loadSecrets]);

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
  }, [deleteTargetName, handleCloseDeleteDialog, loadSecrets]);

  const columns = useMemo<GridColDef<SecretRow>[]>(() => [
    {
      field: 'displayName',
      headerName: 'Name',
      flex: 1,
      minWidth: isMobile ? 120 : 200,
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
                onKeyDown={(event) => event.stopPropagation()}
                variant="outlined"
              />
              <IconButton
                size="small"
                color="primary"
                aria-label="Save display name"
                onClick={() => handleSaveDisplayName(row)}
              >
                <CheckIcon fontSize="small" />
              </IconButton>
              <IconButton
                size="small"
                aria-label="Cancel display name edit"
                onClick={() => handleCancelEdit(row)}
              >
                <CloseIcon fontSize="small" />
              </IconButton>
            </Box>
          );
        }

        const displayText = row.meta.displayName ?? row.name;

        // On mobile, clicking the name opens the actions dialog
        if (isMobile) {
          return (
            <Typography
              variant="body2"
              sx={{ cursor: 'pointer', color: 'primary.main', '&:hover': { textDecoration: 'underline' } }}
              onClick={() => handleOpenMobileActions(row)}
            >
              {displayText}
            </Typography>
          );
        }

        return (
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
            <Typography variant="body2">
              {displayText}
            </Typography>
            {isAdmin && (
              <Tooltip title="Edit display name"><IconButton size="small" aria-label={`Edit display name for ${displayText}`} onClick={() => handleStartEdit(row)}>
                <EditIcon fontSize="small" />
              </IconButton></Tooltip>
            )}
          </Box>
        );
      },
    },
    // Hide Value and Actions columns on mobile
    ...(!isMobile
      ? [
          {
            field: 'displayValue',
            headerName: 'Value',
            flex: 1,
            minWidth: 200,
            renderCell: (params: { row: SecretRow }) => (
              <Typography
                variant="body2"
                sx={{ fontFamily: 'monospace' }}
              >
                {params.row.displayValue}
              </Typography>
            ),
          } satisfies GridColDef<SecretRow>,
          {
            field: 'actions',
            headerName: 'Actions',
            width: isAdmin ? 200 : 120,
            sortable: false,
            filterable: false,
            renderCell: (params: { row: SecretRow }) => (
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
          } satisfies GridColDef<SecretRow>,
        ]
      : []),
  ], [isMobile, isAdmin, handleOpenMobileActions, handleSaveDisplayName, handleCancelEdit,
    handleEditDisplayNameChange, handleStartEdit, handleShowSecret, handleCopyToClipboard,
    handleOpenUpdateDialog, handleOpenDeleteDialog]);

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

      <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, mb: 2, flexWrap: 'wrap' }}>
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

      {!rows.length && !searchText ? <Typography sx={{ py: 3 }}>No secrets in this category.</Typography> : <DataGrid
        rows={filteredRows}
        columns={columns}
        getRowId={(row) => row.id}
        pageSizeOptions={[10, 25, 50]}
        initialState={{
          pagination: { paginationModel: { pageSize: 25 } },
        }}
        disableRowSelectionOnClick
        autoHeight
      />}

      {/* Create / Update Secret Dialog */}
      <Dialog
        open={secretDialogOpen}
        onClose={(_, reason) => {
          if (
            secretGenerationInProgress.current &&
            (reason === 'backdropClick' || reason === 'escapeKeyDown')
          ) {
            return;
          }

          handleCloseSecretDialog();
        }}
        maxWidth="sm"
        fullWidth
      >
        <DialogTitle>
          {secretDialogMode === 'create' ? 'Create Secret' : 'Update Secret Value'}
        </DialogTitle>
        <DialogContent>
          {secretGenerationError && (
            <Alert severity="error" sx={{ mt: 1 }}>
              {secretGenerationError}
            </Alert>
          )}
          {error && <Alert severity="error" sx={{ mt: 1 }}>{error}</Alert>}
          {secretDialogMode === 'create' && (
            <TextField select fullWidth margin="dense" label="Category" value={secretDialogCategoryId}
              onChange={(event) => setSecretDialogCategoryId(event.target.value)} disabled={secretDialogSaving}>
              {categories.map((item) => <MenuItem key={item.id} value={item.id}>{item.name}</MenuItem>)}
            </TextField>
          )}
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
          <Accordion disableGutters sx={{ mt: 2 }}>
            <AccordionSummary expandIcon={<ExpandMoreIcon />}>
              <Typography>Advanced settings</Typography>
            </AccordionSummary>
            <AccordionDetails>
              <TextField
                label="Total length"
                fullWidth
                margin="dense"
                type="number"
                value={secretGenerationPolicy.totalLength}
                onChange={(e) =>
                  handleSecretGenerationPolicyChange('totalLength', e.target.value)
                }
                slotProps={{ htmlInput: { min: 1, max: 128 } }}
              />
              <TextField
                label="Minimum alphabetic characters"
                fullWidth
                margin="dense"
                type="number"
                value={secretGenerationPolicy.minimumAlphabeticCharacters}
                onChange={(e) =>
                  handleSecretGenerationPolicyChange(
                    'minimumAlphabeticCharacters',
                    e.target.value
                  )
                }
                slotProps={{ htmlInput: { min: 0, max: 128 } }}
              />
              <TextField
                label="Minimum numeric characters"
                fullWidth
                margin="dense"
                type="number"
                value={secretGenerationPolicy.minimumNumericCharacters}
                onChange={(e) =>
                  handleSecretGenerationPolicyChange(
                    'minimumNumericCharacters',
                    e.target.value
                  )
                }
                slotProps={{ htmlInput: { min: 0, max: 128 } }}
              />
              <TextField
                label="Minimum special characters"
                fullWidth
                margin="dense"
                type="number"
                value={secretGenerationPolicy.minimumSpecialCharacters}
                onChange={(e) =>
                  handleSecretGenerationPolicyChange(
                    'minimumSpecialCharacters',
                    e.target.value
                  )
                }
                slotProps={{ htmlInput: { min: 0, max: 128 } }}
              />
            </AccordionDetails>
          </Accordion>
        </DialogContent>
        <DialogActions>
          <Button
            onClick={handleCloseSecretDialog}
            disabled={secretDialogSaving || secretDialogGenerating}
          >
            Cancel
          </Button>
          <Button
            onClick={handleGenerateSecret}
            disabled={secretDialogSaving || secretDialogGenerating}
          >
            {secretDialogGenerating ? 'Generating...' : 'Generate secret'}
          </Button>
          <Button
            onClick={handleSaveSecret}
            variant="contained"
            disabled={
              secretDialogSaving ||
              secretDialogGenerating ||
              !secretDialogName.trim() ||
              (secretDialogMode === 'create' && !secretDialogCategoryId) ||
              !secretDialogValue
            }
          >
            {secretDialogSaving
              ? 'Saving...'
              : secretDialogMode === 'create'
                ? 'Create'
                : 'Update'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Mobile Actions Dialog */}
      <Dialog
        open={mobileActionsOpen}
        onClose={handleCloseMobileActions}
        maxWidth="xs"
        fullWidth
      >
        <DialogTitle>
          {mobileActionsRow?.meta.displayName ?? mobileActionsRow?.name}
        </DialogTitle>
        <DialogContent>
          {mobileViewValue !== null ? (
            <Typography
              variant="body2"
              sx={{ fontFamily: 'monospace', wordBreak: 'break-all', p: 1, bgcolor: 'grey.100', borderRadius: 1 }}
            >
              {mobileViewValue}
            </Typography>
          ) : (
            <List disablePadding>
              <ListItemButton
                onClick={() => mobileActionsRow && handleMobileView(mobileActionsRow)}
              >
                <ListItemIcon><VisibilityIcon /></ListItemIcon>
                <ListItemText primary="View Secret" />
              </ListItemButton>
              <ListItemButton
                onClick={() => {
                  if (mobileActionsRow) {
                    handleCopyToClipboard(mobileActionsRow);
                    handleCloseMobileActions();
                  }
                }}
              >
                <ListItemIcon><CopyIcon /></ListItemIcon>
                <ListItemText primary="Copy to Clipboard" />
              </ListItemButton>
              {isAdmin && (
                <>
                  <ListItemButton
                    onClick={() => {
                      if (mobileActionsRow) {
                        handleOpenUpdateDialog(mobileActionsRow);
                        handleCloseMobileActions();
                      }
                    }}
                  >
                    <ListItemIcon><EditIcon color="primary" /></ListItemIcon>
                    <ListItemText primary="Edit Secret" />
                  </ListItemButton>
                  <ListItemButton
                    onClick={() => {
                      if (mobileActionsRow) {
                        handleOpenDeleteDialog(mobileActionsRow);
                        handleCloseMobileActions();
                      }
                    }}
                  >
                    <ListItemIcon><DeleteIcon color="error" /></ListItemIcon>
                    <ListItemText primary="Delete Secret" />
                  </ListItemButton>
                </>
              )}
            </List>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={handleCloseMobileActions}>Close</Button>
        </DialogActions>
      </Dialog>

      {/* Delete Confirmation Dialog */}
      <Dialog open={deleteDialogOpen} onClose={handleCloseDeleteDialog}>
        <DialogTitle>Delete Secret</DialogTitle>
        <DialogContent>
          {error && <Alert severity="error" sx={{ mb: 1 }}>{error}</Alert>}
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
