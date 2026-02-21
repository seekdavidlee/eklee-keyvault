import {
  createContext,
  useContext,
  useState,
  useEffect,
  type ReactNode,
} from 'react';
import { useIsAuthenticated } from '@azure/msal-react';
import { getMe } from '../services/userAccessService';
import type { UserRole } from '../types';

interface UserContextValue {
  /** The current user's role, or null while loading / if access denied. */
  role: UserRole | null;
  /** Convenience flag — true when the user has the Admin role. */
  isAdmin: boolean;
  /** True while the initial /me call is in progress. */
  loading: boolean;
  /** True when the user is authenticated but not registered for access. */
  accessDenied: boolean;
}

const UserCtx = createContext<UserContextValue>({
  role: null,
  isAdmin: false,
  loading: true,
  accessDenied: false,
});

/**
 * Provides the current user's role information to the component tree.
 * Calls GET /api/useraccess/me after authentication to determine the user's role.
 * If the user is not registered, sets accessDenied so the app can show an appropriate page.
 */
export function UserProvider({ children }: { children: ReactNode }) {
  const isAuthenticated = useIsAuthenticated();
  const [role, setRole] = useState<UserRole | null>(null);
  const [loading, setLoading] = useState(true);
  const [accessDenied, setAccessDenied] = useState(false);

  useEffect(() => {
    if (!isAuthenticated) {
      setLoading(false);
      return;
    }

    let cancelled = false;

    const fetchMe = async () => {
      try {
        const me = await getMe();
        if (!cancelled) {
          setRole(me.role);
          setAccessDenied(false);
        }
      } catch (err: unknown) {
        if (!cancelled) {
          if (isAxios403(err)) {
            setAccessDenied(true);
          }
          setRole(null);
        }
      } finally {
        if (!cancelled) {
          setLoading(false);
        }
      }
    };

    fetchMe();

    return () => {
      cancelled = true;
    };
  }, [isAuthenticated]);

  return (
    <UserCtx.Provider
      value={{
        role,
        isAdmin: role === 'Admin',
        loading,
        accessDenied,
      }}
    >
      {children}
    </UserCtx.Provider>
  );
}

/** Hook to access the current user's role and access status. */
export function useUser(): UserContextValue {
  return useContext(UserCtx);
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
