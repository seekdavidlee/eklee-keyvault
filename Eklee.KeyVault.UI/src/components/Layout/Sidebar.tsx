import { List, ListItemButton, ListItemIcon, ListItemText } from '@mui/material';
import { Dashboard as DashboardIcon, People as PeopleIcon } from '@mui/icons-material';
import { useNavigate, useLocation } from 'react-router-dom';
import { useUser } from '../../auth/UserContext';

/**
 * Sidebar navigation component. Renders a list of navigation links
 * with active state highlighting based on the current route.
 * The "User Management" link is only shown to Admin users.
 */
export function Sidebar() {
  const navigate = useNavigate();
  const location = useLocation();
  const { isAdmin } = useUser();

  const navItems = [
    { label: 'Dashboard', path: '/', icon: <DashboardIcon /> },
    ...(isAdmin
      ? [{ label: 'User Management', path: '/users', icon: <PeopleIcon /> }]
      : []),
  ];

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
