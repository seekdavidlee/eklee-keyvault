import { List, ListItemButton, ListItemIcon, ListItemText } from '@mui/material';
import { Dashboard as DashboardIcon } from '@mui/icons-material';
import { useNavigate, useLocation } from 'react-router-dom';

/** Navigation items displayed in the sidebar drawer. */
const navItems = [
  { label: 'Dashboard', path: '/', icon: <DashboardIcon /> },
];

/**
 * Sidebar navigation component. Renders a list of navigation links
 * with active state highlighting based on the current route.
 */
export function Sidebar() {
  const navigate = useNavigate();
  const location = useLocation();

  return (
    <List>
      {navItems.map((item) => (
        <ListItemButton
          key={item.path}
          selected={location.pathname === item.path}
          onClick={() => navigate(item.path)}
        >
          <ListItemIcon>{item.icon}</ListItemIcon>
          <ListItemText primary={item.label} />
        </ListItemButton>
      ))}
    </List>
  );
}
