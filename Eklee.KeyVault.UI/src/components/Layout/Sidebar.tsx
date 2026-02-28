import { type ReactElement } from 'react';
import { List, ListItemButton, ListItemIcon, ListItemText } from '@mui/material';
import { Dashboard as DashboardIcon, People as PeopleIcon } from '@mui/icons-material';
import { useNavigate, useLocation } from 'react-router-dom';
import { useUser } from '../../auth/UserContext';

/** Shape of a navigation item used by both Sidebar and MobileNav. */
export interface NavItem {
  label: string;
  path: string;
  icon: ReactElement;
}

/**
 * Returns the navigation items available to the current user.
 * Admin users see the "User Management" link in addition to "Dashboard".
 */
export function useNavItems(): NavItem[] {
  const { isAdmin } = useUser();

  return [
    { label: 'Dashboard', path: '/', icon: <DashboardIcon /> },
    ...(isAdmin
      ? [{ label: 'User Management', path: '/users', icon: <PeopleIcon /> }]
      : []),
  ];
}

/**
 * Sidebar navigation component. Renders a list of navigation links
 * with active state highlighting based on the current route.
 * The "User Management" link is only shown to Admin users.
 */
export function Sidebar() {
  const navigate = useNavigate();
  const location = useLocation();
  const navItems = useNavItems();

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
