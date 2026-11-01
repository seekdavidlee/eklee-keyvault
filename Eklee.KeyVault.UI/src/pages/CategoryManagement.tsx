import { useEffect, useState } from 'react';
import { isAxiosError } from 'axios';
import { Link } from 'react-router-dom';
import {
  Alert, Box, Button, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogContentText, DialogTitle, IconButton, List, ListItem, ListItemText,
  TextField, Tooltip, Typography,
} from '@mui/material';
import { Add, ArrowBack, Delete, Edit, Refresh } from '@mui/icons-material';
import { createCategory, deleteCategory, getCategories, renameCategory } from '../services/categoriesService';
import type { ApiProblemDetails, CategoryItem } from '../types';

/** Admin category CRUD surface; deletion never reassigns or deletes secrets. */
export function CategoryManagement() {
  const [categories, setCategories] = useState<CategoryItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [reload, setReload] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<'create' | 'rename' | 'delete' | null>(null);
  const [target, setTarget] = useState<CategoryItem | null>(null);
  const [name, setName] = useState('');
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  useEffect(() => {
    let ignore = false;
    getCategories().then((result) => {
      if (!ignore) setCategories(result);
    }).catch((failure: unknown) => {
      if (!ignore) setError(categoryError(failure));
    }).finally(() => {
      if (!ignore) setLoading(false);
    });
    return () => { ignore = true; };
  }, [reload]);

  const openDialog = (mode: 'create' | 'rename' | 'delete', category: CategoryItem | null = null) => {
    setTarget(category);
    setName(category?.name ?? '');
    setFormError(null);
    setError(null);
    setDialog(mode);
  };

  const trimmedName = name.trim();
  const nameError = !trimmedName ? 'Category name is required.'
    : trimmedName.length > 30 ? 'Category names must be 30 characters or fewer.'
    : categories.some((category) => category.id !== target?.id &&
      category.name.toLowerCase() === trimmedName.toLowerCase())
      ? 'A category with this name already exists.' : null;

  const save = async () => {
    if (dialog !== 'delete' && nameError) {
      setFormError(nameError);
      return;
    }
    setSaving(true);
    setFormError(null);
    try {
      if (dialog === 'delete' && target) {
        await deleteCategory(target.id);
        setCategories((current) => current.filter((category) => category.id !== target.id));
      } else if (dialog === 'rename' && target) {
        const renamed = await renameCategory(target.id, trimmedName);
        setCategories((current) => current.map((category) => category.id === renamed.id ? renamed : category));
      } else if (dialog === 'create') {
        const created = await createCategory(trimmedName);
        setCategories((current) => [...current, created]);
      }
      setDialog(null);
    } catch (failure) {
      setFormError(categoryError(failure));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Box>
      <Button component={Link} to="/" startIcon={<ArrowBack />} sx={{ mb: 2 }}>Categories</Button>
      <Box sx={{ display: 'flex', gap: 1, alignItems: 'center', flexWrap: 'wrap', mb: 2 }}>
        <Typography variant="h5" component="h1" sx={{ flexGrow: 1 }}>Category Management</Typography>
        <Tooltip title="Reload categories">
          <IconButton aria-label="Reload categories" disabled={loading || saving} onClick={() => {
            setLoading(true); setError(null); setReload((current) => current + 1);
          }}><Refresh /></IconButton>
        </Tooltip>
        <Button variant="contained" startIcon={<Add />} disabled={loading || !!error} onClick={() => openDialog('create')}>
          Create Category
        </Button>
      </Box>
      {error && <Alert severity="error">{error}</Alert>}
      {loading ? <CircularProgress aria-label="Loading categories" /> : (
        <List aria-label="Categories">
          {[...categories].sort((first, second) => first.name.localeCompare(second.name)).map((category) => (
            <ListItem key={category.id} divider sx={{ gap: 1 }}>
              <ListItemText primary={category.name} secondary={category.isDefault ? 'Default category' : undefined}
                sx={{ minWidth: 0, overflowWrap: 'anywhere' }} />
              <Tooltip title={`Rename ${category.name}`}>
                <IconButton aria-label={`Rename ${category.name}`} onClick={() => openDialog('rename', category)}>
                  <Edit />
                </IconButton>
              </Tooltip>
              <Tooltip title={category.isDefault ? 'The default category cannot be deleted.' : `Delete ${category.name}`}>
                <span><IconButton aria-label={`Delete ${category.name}`} disabled={category.isDefault}
                  color="error" onClick={() => openDialog('delete', category)}><Delete /></IconButton></span>
              </Tooltip>
            </ListItem>
          ))}
          {!categories.length && !error && <Typography>No categories available.</Typography>}
        </List>
      )}
      <Dialog open={dialog !== null} onClose={() => { if (!saving) setDialog(null); }} fullWidth maxWidth="xs">
        <DialogTitle>{dialog === 'create' ? 'Create Category' : dialog === 'rename' ? 'Rename Category' : 'Delete Category'}</DialogTitle>
        <DialogContent>
          {formError && <Alert severity="error" sx={{ mb: 1 }}>{formError}</Alert>}
          {dialog === 'delete' ? (
            <DialogContentText sx={{ overflowWrap: 'anywhere' }}>Delete category <strong>{target?.name}</strong>?</DialogContentText>
          ) : (
            <TextField autoFocus fullWidth margin="dense" label="Category name" value={name}
              disabled={saving} error={!!name && !!nameError} helperText={name && nameError ? nameError : `${trimmedName.length}/30`}
              onChange={(event) => { setName(event.target.value); setFormError(null); }} />
          )}
        </DialogContent>
        <DialogActions>
          <Button disabled={saving} onClick={() => setDialog(null)}>Cancel</Button>
          <Button variant="contained" color={dialog === 'delete' ? 'error' : 'primary'}
            disabled={saving || (dialog !== 'delete' && !!nameError)} onClick={save}>
            {saving ? 'Saving...' : dialog === 'create' ? 'Create' : dialog === 'rename' ? 'Save' : 'Delete'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}

function categoryError(failure: unknown): string {
  if (isAxiosError<ApiProblemDetails>(failure)) {
    if (failure.response?.data.detail) return failure.response.data.detail;
    if (failure.response?.status === 403) return 'You do not have access. Please contact your administrator.';
  }
  return failure instanceof Error ? failure.message : 'Unable to update categories. Reload and try again.';
}