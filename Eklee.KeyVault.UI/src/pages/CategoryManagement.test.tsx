import { beforeEach, describe, expect, it, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { CategoryManagement } from './CategoryManagement';
import { createCategory, deleteCategory, getCategories, renameCategory } from '../services/categoriesService';

vi.mock('../services/categoriesService');
const defaults = { id: 'stable-default', name: 'General', isDefault: true };
const finance = { id: 'finance', name: 'Finance', isDefault: false };

describe('category management', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    vi.mocked(getCategories).mockResolvedValue([defaults, finance]);
  });

  it('protects the renamed default category and permits its case-only rename', async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><CategoryManagement /></MemoryRouter>);
    expect(await screen.findByRole('button', { name: 'Delete General' })).toBeDisabled();
    vi.mocked(renameCategory).mockResolvedValue({ ...defaults, name: 'GENERAL' });
    await user.click(screen.getByRole('button', { name: 'Rename General' }));
    await user.clear(screen.getByRole('textbox', { name: 'Category name' }));
    await user.type(screen.getByRole('textbox', { name: 'Category name' }), 'GENERAL');
    await user.click(screen.getByRole('button', { name: 'Save' }));
    expect(await screen.findByRole('button', { name: 'Delete GENERAL' })).toBeDisabled();
    expect(renameCategory).toHaveBeenCalledWith(defaults.id, 'GENERAL');
  });

  it('rejects blank, duplicate, and overlong names while accepting exactly 30 characters', async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><CategoryManagement /></MemoryRouter>);
    await screen.findByRole('button', { name: 'Rename Finance' });
    await user.click(screen.getByRole('button', { name: 'Create Category' }));
    const input = screen.getByRole('textbox', { name: 'Category name' });
    const submit = screen.getByRole('button', { name: 'Create' });
    expect(submit).toBeDisabled();
    await user.type(input, '   ');
    expect(submit).toBeDisabled();
    await user.clear(input);
    await user.type(input, 'finance');
    expect(submit).toBeDisabled();
    await user.clear(input);
    await user.type(input, 'a'.repeat(31));
    expect(submit).toBeDisabled();
    expect(createCategory).not.toHaveBeenCalled();
    await user.clear(input);
    await user.type(input, 'a'.repeat(30));
    vi.mocked(createCategory).mockResolvedValue({ id: 'new', name: 'a'.repeat(30), isDefault: false });
    await user.click(submit);
    expect(await screen.findByRole('button', { name: `Rename ${'a'.repeat(30)}` })).toBeEnabled();
    expect(createCategory).toHaveBeenCalledWith('a'.repeat(30));
  });

  it('keeps a nonempty category and displays the server deletion guard', async () => {
    const user = userEvent.setup();
    vi.mocked(deleteCategory).mockRejectedValue({ isAxiosError: true, response: {
      status: 409, data: { detail: 'Delete the secrets in this category first.' },
    } });
    render(<MemoryRouter><CategoryManagement /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Delete Finance' }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Delete' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Delete the secrets in this category first.');
    expect(deleteCategory).toHaveBeenCalledExactlyOnceWith(finance.id);
  });

  it('removes only a successfully deleted empty category from the list', async () => {
    const user = userEvent.setup();
    vi.mocked(deleteCategory).mockResolvedValue(undefined);
    render(<MemoryRouter><CategoryManagement /></MemoryRouter>);
    await user.click(await screen.findByRole('button', { name: 'Delete Finance' }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Delete' }));
    await screen.findByRole('button', { name: 'Delete General' });
    expect(screen.queryByRole('button', { name: 'Delete Finance' })).not.toBeInTheDocument();
  });
});