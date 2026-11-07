import { useEffect, useRef, useState } from 'react';
import { isAxiosError } from 'axios';
import {
  Alert, Box, Button, Checkbox, Dialog, DialogActions, DialogContent, DialogTitle,
  FormControlLabel, IconButton, MenuItem, TextField, Tooltip, Typography,
} from '@mui/material';
import Add from '@mui/icons-material/Add';
import Download from '@mui/icons-material/Download';
import Upload from '@mui/icons-material/Upload';
import { useUser } from '../auth/UserContext';
import { createCategory, getCategories } from '../services/categoriesService';
import { exportSecrets, importSecrets } from '../services/secretsService';
import type { CategoryItem, SecretImportResponse } from '../types';

const MAXIMUM_FILE_BYTES = 10 * 1024 * 1024;

/** Category-scoped transfer dialogs keep file contents out of rendered output and error messages. */
export function SecretTransferControls({ category, onCategoryCreated, onImported }: {
  category: CategoryItem;
  onCategoryCreated: (category: CategoryItem) => void;
  onImported: () => void;
}) {
  const { isAdmin } = useUser();
  const [mode, setMode] = useState<'export' | 'import' | null>(null);
  const [acknowledged, setAcknowledged] = useState(false);
  const [categories, setCategories] = useState<CategoryItem[]>([]);
  const [destinationId, setDestinationId] = useState('');
  const [newCategoryName, setNewCategoryName] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<SecretImportResponse | null>(null);
  const active = useRef(true);
  const inProgress = useRef(false);

  useEffect(() => {
    active.current = true;
    return () => { active.current = false; };
  }, []);

  useEffect(() => {
    if (mode !== 'import') return;
    let ignore = false;
    getCategories().then((items) => { if (!ignore) setCategories(items); }).catch(() => {
      if (!ignore) setError('Unable to load destination categories. Close and retry.');
    });
    return () => { ignore = true; };
  }, [mode]);

  function open(next: 'export' | 'import') {
    if (inProgress.current) return;
    setError(null);
    setResult(null);
    setFile(null);
    setDestinationId('');
    setNewCategoryName('');
    setCategories([]);
    setAcknowledged(false);
    setMode(next);
  }

  function close() {
    if (inProgress.current) return;
    setMode(null);
    setFile(null);
    setResult(null);
  }

  async function createDestination() {
    if (inProgress.current || !newCategoryName.trim()) return;
    inProgress.current = true;
    setBusy(true);
    setError(null);
    try {
      const created = await createCategory(newCategoryName.trim());
      if (!active.current) return;
      setCategories((items) => [...items, created]);
      setDestinationId(created.id);
      setNewCategoryName('');
      onCategoryCreated(created);
    } catch {
      if (active.current) setError('Unable to create category. Use a unique name of 1-30 characters and check your permissions.');
    } finally {
      inProgress.current = false;
      if (active.current) setBusy(false);
    }
  }

  async function transfer() {
    if (inProgress.current || (mode === 'import' && (!destinationId || !file)) || (mode === 'export' && !acknowledged)) return;
    inProgress.current = true;
    setBusy(true);
    setError(null);
    try {
      if (mode === 'export') {
        const blob = await exportSecrets(category.id);
        if (!active.current) return;
        const url = URL.createObjectURL(blob);
        const anchor = document.createElement('a');
        anchor.href = url;
        anchor.download = 'secrets-export.json';
        document.body.appendChild(anchor);
        anchor.click();
        anchor.remove();
        setTimeout(() => URL.revokeObjectURL(url), 0);
        setMode(null);
      } else if (file) {
        const text = await file.text();
        if (!active.current) return;
        const outcome = await importSecrets(destinationId, text);
        if (!active.current) return;
        setResult(outcome);
        setFile(null);
        onImported();
      }
    } catch (failure: unknown) {
      if (!active.current) return;
      if (isAxiosError<SecretImportResponse>(failure) && Array.isArray(failure.response?.data.results)) {
        setResult(failure.response.data);
        setFile(null);
        onImported();
      }
      setError(mode === 'export' ? 'Export failed. Check category access and the 1000-secret / 10 MiB limits.'
        : 'Import failed. Use a valid application export (formatVersion 1, at most 1000 secrets, 25 KiB per value, and at most 15 string tags per secret) and check destination access.');
    } finally {
      inProgress.current = false;
      if (active.current) setBusy(false);
    }
  }

  return (
    <>
      <Box sx={{ display: 'flex', gap: 1, mb: 2 }}>
        <Tooltip title="Export category"><span><IconButton aria-label="Export category" disabled={busy} onClick={() => open('export')}><Download /></IconButton></span></Tooltip>
        {isAdmin && <Tooltip title="Import secrets"><span><IconButton aria-label="Import secrets" disabled={busy} onClick={() => open('import')}><Upload /></IconButton></span></Tooltip>}
      </Box>
      <Dialog open={mode !== null} onClose={close} fullWidth maxWidth="sm">
        <DialogTitle>{mode === 'export' ? 'Export category' : 'Import secrets'}</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, pt: '8px !important' }}>
          {error && <Alert severity="error">{error}</Alert>}
          {mode === 'export' ? <>
            <Typography sx={{ overflowWrap: 'anywhere' }}>{category.name}</Typography>
            <Alert severity="warning">The exported JSON is unencrypted and contains secret values and all tags. Store it securely and delete it when no longer needed.</Alert>
            <FormControlLabel control={<Checkbox checked={acknowledged} disabled={busy} onChange={(event) => setAcknowledged(event.target.checked)} />}
              label="I understand this file contains unencrypted secrets" />
          </> : <>
            <TextField select label="Destination category" value={destinationId} disabled={busy || result !== null}
              onChange={(event) => setDestinationId(event.target.value)}>
              <MenuItem value="">Select a category</MenuItem>
              {categories.map((item) => <MenuItem key={item.id} value={item.id} sx={{ whiteSpace: 'normal', overflowWrap: 'anywhere' }}>{item.name}</MenuItem>)}
            </TextField>
            <Box sx={{ display: 'flex', gap: 1, alignItems: 'center' }}>
              <TextField label="New category name" value={newCategoryName} disabled={busy || result !== null} fullWidth
                slotProps={{ htmlInput: { maxLength: 30 } }} onChange={(event) => setNewCategoryName(event.target.value)} />
              <Tooltip title="Create destination category"><span><IconButton aria-label="Create destination category"
                disabled={busy || !newCategoryName.trim() || result !== null} onClick={() => void createDestination()}><Add /></IconButton></span></Tooltip>
            </Box>
            {!result && <input aria-label="Import JSON file" type="file" accept=".json,application/json" disabled={busy}
              style={{ maxWidth: '100%' }} onChange={(event) => {
                const selected = event.target.files?.[0] ?? null;
                setError(selected && selected.size > MAXIMUM_FILE_BYTES ? 'File exceeds the 10 MiB limit.' : null);
                setFile(selected && selected.size <= MAXIMUM_FILE_BYTES ? selected : null);
              }} />}
            {result && <Box role="status">
              <Typography>{result.results.filter((item) => item.status === 'imported').length} imported; {result.results.filter((item) => item.status === 'skipped').length} skipped; {result.results.filter((item) => item.status === 'failed' || item.status === 'notAttempted').length} failed or not attempted.</Typography>
              {result.results.map((item, index) => <Typography key={`${index}-${item.name}`} variant="body2" sx={{ overflowWrap: 'anywhere', mt: 1 }}>
                {item.name}: {item.status}{item.error ? `. ${item.error}` : ''}
              </Typography>)}
            </Box>}
          </>}
        </DialogContent>
        <DialogActions>
          <Button onClick={close} disabled={busy}>Close</Button>
          {!result && <Button variant="contained" startIcon={mode === 'export' ? <Download /> : <Upload />}
            disabled={busy || (mode === 'export' ? !acknowledged : !destinationId || !file)} onClick={() => void transfer()}>
            {busy ? 'Working...' : mode === 'export' ? 'Download JSON' : 'Import'}
          </Button>}
        </DialogActions>
      </Dialog>
    </>
  );
}