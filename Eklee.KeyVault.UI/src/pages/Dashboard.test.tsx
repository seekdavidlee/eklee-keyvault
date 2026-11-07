import { act, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Dashboard } from './Dashboard';
import { useUser } from '../auth/UserContext';
import { createCategory, getCategories } from '../services/categoriesService';
import { exportSecrets, getSecrets, importSecrets, setSecret } from '../services/secretsService';
import { getMetadata, updateMetadata } from '../services/metadataService';
import type { SecretItemView } from '../types';

vi.mock('../auth/UserContext');
vi.mock('../services/categoriesService');
vi.mock('../services/secretsService');
vi.mock('../services/metadataService');
const finance = { id: 'finance', name: 'Finance', isDefault: false };
const general = { id: 'default-id', name: 'General', isDefault: true };
const budget = { id: 'budget', name: 'budget', meta: { id: 'budget', displayName: 'Budget', categoryId: finance.id } };
const shared = { id: 'shared', name: 'shared', meta: { id: 'shared', displayName: 'Shared', categoryId: general.id } };

describe('category-first dashboard', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    vi.mocked(useUser).mockReturnValue({ isAdmin: true, role: 'Admin', loading: false, accessDenied: false });
    vi.mocked(getCategories).mockResolvedValue([finance, general]);
    vi.mocked(getSecrets).mockResolvedValue([budget]);
  });

  it('lands on categories without loading secrets and shows a category-specific empty state', async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await screen.findByRole('button', { name: 'Finance' });
    expect(getSecrets).not.toHaveBeenCalled();
    vi.mocked(getSecrets).mockResolvedValue([]);
    await user.click(screen.getByRole('button', { name: 'Finance' }));
    expect(await screen.findByText('No secrets in this category.')).toBeInTheDocument();
    expect(getSecrets).toHaveBeenCalledWith(finance.id);
  });

  it('ignores an older request after backing out and selecting another category', async () => {
    const user = userEvent.setup();
    let resolveOld!: (value: SecretItemView[]) => void;
    vi.mocked(getSecrets).mockImplementation((id) => id === finance.id
      ? new Promise((resolve) => { resolveOld = resolve; }) : Promise.resolve([shared, budget]));
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(screen.getByRole('button', { name: 'Back to categories' }));
    await user.click(screen.getByRole('button', { name: 'General Default category' }));
    expect(await screen.findByText('Shared')).toBeInTheDocument();
    await act(async () => resolveOld([budget]));
    expect(screen.queryByText('Budget')).not.toBeInTheDocument();
    expect(screen.getByText('Shared')).toBeInTheDocument();
  });

  it('requires a creation category and never offers a move control for updates', async () => {
    const user = userEvent.setup();
    vi.mocked(setSecret).mockResolvedValue('new-secret');
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(await screen.findByRole('button', { name: 'Create Secret' }));
    const dialog = within(screen.getByRole('dialog'));
    expect(dialog.getByRole('combobox', { name: 'Category' })).toHaveTextContent('Finance');
    await user.type(dialog.getByRole('textbox', { name: 'Secret Name' }), 'new-secret');
    await user.type(dialog.getByRole('textbox', { name: 'Secret Value' }), 'test-value');
    await user.click(dialog.getByRole('button', { name: 'Create' }));
    expect(setSecret).toHaveBeenCalledWith('new-secret', 'test-value', finance.id);
    await user.click(await screen.findByRole('button', { name: 'Update secret value' }));
    expect(within(screen.getByRole('dialog')).queryByRole('combobox', { name: 'Category' })).not.toBeInTheDocument();
  });

  it('preserves every category and secret association when saving a filtered display name', async () => {
    const user = userEvent.setup();
    vi.mocked(getMetadata).mockResolvedValue({ etag: 'etag-current', metaList: {
      categories: [finance, general], items: [budget.meta, shared.meta],
    } });
    vi.mocked(updateMetadata).mockResolvedValue('etag-new');
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(await screen.findByRole('button', { name: 'Edit display name for Budget' }));
    const cell = screen.getByDisplayValue('Budget');
    await user.clear(cell);
    await user.type(cell, 'Budget updated');
    expect(screen.getByDisplayValue('Budget updated')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Save display name' }));
    expect(await screen.findByText('Budget updated')).toBeInTheDocument();
    expect(updateMetadata).toHaveBeenCalledWith({ categories: [finance, general], items: [
      { ...budget.meta, displayName: 'Budget updated' }, shared.meta,
    ] }, 'etag-current');
  });

  it('preserves read access without exposing Admin actions', async () => {
    const user = userEvent.setup();
    vi.mocked(useUser).mockReturnValue({ isAdmin: false, role: 'User', loading: false, accessDenied: false });
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await screen.findByText('Budget');
    expect(screen.queryByRole('button', { name: 'Create Secret' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Show secret' })).toBeEnabled();
    expect(screen.queryByRole('button', { name: 'Edit display name for Budget' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Export category' })).toBeEnabled();
    expect(screen.queryByRole('button', { name: 'Import secrets' })).not.toBeInTheDocument();
  });

  it('warns about unencrypted values before downloading only the selected category', async () => {
    const user = userEvent.setup();
    const blob = new Blob(['test export'], { type: 'application/json' });
    vi.mocked(exportSecrets).mockResolvedValue(blob);
    const createUrl = vi.fn(() => 'blob:test');
    Object.defineProperty(URL, 'createObjectURL', { configurable: true, value: createUrl });
    Object.defineProperty(URL, 'revokeObjectURL', { configurable: true, value: vi.fn() });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(screen.getByRole('button', { name: 'Export category' }));
    expect(screen.getByText(/The exported JSON is unencrypted and contains secret values/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Download JSON' })).toBeDisabled();
    expect(exportSecrets).not.toHaveBeenCalled();
    await user.click(screen.getByRole('checkbox', { name: 'I understand this file contains unencrypted secrets' }));
    await user.click(screen.getByRole('button', { name: 'Download JSON' }));
    expect(exportSecrets).toHaveBeenCalledWith(finance.id);
    expect(createUrl).toHaveBeenCalledWith(blob);
    expect(click).toHaveBeenCalledOnce();
    click.mockRestore();
  });

  it('requires a destination and imports raw JSON into an existing category with value-free mixed results', async () => {
    const user = userEvent.setup();
    const raw = '{"formatVersion":1,"secrets":[{"name":"new","value":"sensitive-marker","tags":{"category":"keep"}}]}';
    const file = new File([raw], 'export.json', { type: 'application/json' });
    Object.defineProperty(file, 'text', { value: () => Promise.resolve(raw) });
    vi.mocked(importSecrets).mockResolvedValue({ accessDenied: false, results: [
      { name: 'new', status: 'imported' }, { name: 'existing', status: 'skipped', error: 'This name already exists in the vault.' },
    ] });
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(screen.getByRole('button', { name: 'Import secrets' }));
    expect(screen.getByRole('button', { name: 'Import' })).toBeDisabled();
    await user.upload(screen.getByLabelText('Import JSON file'), file);
    expect(screen.getByRole('button', { name: 'Import' })).toBeDisabled();
    await user.click(screen.getByRole('combobox', { name: 'Destination category' }));
    await user.click(await screen.findByRole('option', { name: 'General' }));
    await user.click(screen.getByRole('button', { name: 'Import' }));
    expect(await screen.findByRole('status')).toHaveTextContent('1 imported; 1 skipped; 0 failed or not attempted.');
    expect(importSecrets).toHaveBeenCalledWith(general.id, raw);
    expect(screen.queryByText(/sensitive-marker/)).not.toBeInTheDocument();
  });

  it('creates and selects a category during import and makes it available after returning', async () => {
    const user = userEvent.setup();
    const created = { id: 'created', name: 'Imported', isDefault: false };
    vi.mocked(createCategory).mockResolvedValue(created);
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(screen.getByRole('button', { name: 'Import secrets' }));
    await user.type(screen.getByRole('textbox', { name: 'New category name' }), 'Imported');
    await user.click(screen.getByRole('button', { name: 'Create destination category' }));
    expect(await screen.findByRole('combobox', { name: 'Destination category' })).toHaveTextContent('Imported');
    expect(createCategory).toHaveBeenCalledWith('Imported');
    await user.click(screen.getByRole('button', { name: 'Close' }));
    await user.click(await screen.findByRole('button', { name: 'Back to categories' }));
    expect(screen.getByRole('button', { name: 'Imported' })).toBeInTheDocument();
  });

  it('reports rejected malformed files without rendering parser or response secrets', async () => {
    const user = userEvent.setup();
    const raw = '{"value":"sensitive-marker"';
    const file = new File([raw], 'invalid.json', { type: 'application/json' });
    Object.defineProperty(file, 'text', { value: () => Promise.resolve(raw) });
    vi.mocked(importSecrets).mockRejectedValue(new Error('sensitive-marker'));
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(screen.getByRole('button', { name: 'Import secrets' }));
    await user.upload(screen.getByLabelText('Import JSON file'), file);
    await user.click(screen.getByRole('combobox', { name: 'Destination category' }));
    await user.click(await screen.findByRole('option', { name: 'Finance' }));
    await user.click(screen.getByRole('button', { name: 'Import' }));
    expect(await screen.findByText(/Import failed. Use a valid application export/)).toBeInTheDocument();
    expect(screen.queryByText(/sensitive-marker/)).not.toBeInTheDocument();
  });

  it('rejects oversized files before sending and clears the previous file selection', async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Finance' }));
    await user.click(screen.getByRole('button', { name: 'Import secrets' }));
    const file = new File(['{}'], 'large.json', { type: 'application/json' });
    Object.defineProperty(file, 'size', { value: 10 * 1024 * 1024 + 1 });
    await user.upload(screen.getByLabelText('Import JSON file'), file);
    expect(screen.getByText('File exceeds the 10 MiB limit.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Import' })).toBeDisabled();
    expect(importSecrets).not.toHaveBeenCalled();
  });
});