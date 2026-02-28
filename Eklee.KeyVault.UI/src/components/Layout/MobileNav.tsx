import {
  Box,
  FormControl,
  InputLabel,
  MenuItem,
  Select,
  type SelectChangeEvent,
} from '@mui/material';
import { useNavigate, useLocation } from 'react-router-dom';
import { useNavItems } from './Sidebar';

/**
 * Mobile navigation dropdown that replaces the sidebar on small screens.
 * Renders a MUI Select with the same navigation items as the Sidebar.
 */
export function MobileNav() {
  const navigate = useNavigate();
  const location = useLocation();
  const navItems = useNavItems();

  const currentPath = navItems.some((item) => item.path === location.pathname)
    ? location.pathname
    : '/';

  const handleChange = (event: SelectChangeEvent) => {
    navigate(event.target.value);
  };

  return (
    <Box sx={{ px: 3, pt: 2, pb: 1 }}>
      <FormControl fullWidth size="small">
        <InputLabel id="mobile-nav-label">Navigate</InputLabel>
        <Select
          labelId="mobile-nav-label"
          id="mobile-nav-select"
          value={currentPath}
          label="Navigate"
          onChange={handleChange}
        >
          {navItems.map((item) => (
            <MenuItem key={item.path} value={item.path}>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                {item.icon}
                {item.label}
              </Box>
            </MenuItem>
          ))}
        </Select>
      </FormControl>
    </Box>
  );
}
