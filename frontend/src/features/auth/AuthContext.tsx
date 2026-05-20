import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import { AUTH_USER_KEY, authApi, clearStoredAuth, getStoredToken, setStoredToken } from "@/api/client";
import { AuthContext, type AuthContextValue } from "@/features/auth/auth-context";
import type { User } from "@/types";

function readStoredUser() {
  const stored = localStorage.getItem(AUTH_USER_KEY);

  if (!stored) {
    return null;
  }

  try {
    return JSON.parse(stored) as User;
  } catch {
    localStorage.removeItem(AUTH_USER_KEY);
    return null;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const { t } = useTranslation();
  const [token, setToken] = useState<string | null>(() => getStoredToken());
  const [user, setUser] = useState<User | null>(() => readStoredUser());
  const [isLoading, setIsLoading] = useState(true);

  const persistUser = useCallback((nextUser: User | null) => {
    setUser(nextUser);

    if (nextUser) {
      localStorage.setItem(AUTH_USER_KEY, JSON.stringify(nextUser));
      return;
    }

    localStorage.removeItem(AUTH_USER_KEY);
  }, []);

  const logout = useCallback(() => {
    clearStoredAuth();
    setToken(null);
    persistUser(null);
  }, [persistUser]);

  const getCurrentUser = useCallback(async () => {
    const currentToken = getStoredToken();

    if (!currentToken) {
      logout();
      return null;
    }

    try {
      const currentUser = await authApi.me();
      persistUser(currentUser);
      return currentUser;
    } catch {
      logout();
      return null;
    }
  }, [logout, persistUser]);

  const login = useCallback(
    async (email: string, password: string) => {
      const response = await authApi.login({ email, password });
      setStoredToken(response.access_token);
      setToken(response.access_token);
      const currentUser = await authApi.me();
      persistUser(currentUser);
    },
    [persistUser]
  );

  const register = useCallback(
    async (email: string, username: string, password: string) => {
      await authApi.register({ email, username, password });
      await login(email, password);
    },
    [login]
  );

  useEffect(() => {
    let mounted = true;

    async function bootstrap() {
      if (!getStoredToken()) {
        persistUser(null);
        if (mounted) {
          setIsLoading(false);
        }
        return;
      }

      await getCurrentUser();

      if (mounted) {
        setIsLoading(false);
      }
    }

    void bootstrap();

    return () => {
      mounted = false;
    };
  }, [getCurrentUser, persistUser]);

  useEffect(() => {
    const onSessionExpired = () => {
      logout();
      toast.error(t("api.errors.sessionExpired"));
      window.location.assign("/login");
    };

    window.addEventListener("devdeploy:session-expired", onSessionExpired);
    return () => window.removeEventListener("devdeploy:session-expired", onSessionExpired);
  }, [logout, t]);

  const value = useMemo<AuthContextValue>(
    () => ({
      user,
      token,
      isAuthenticated: Boolean(token && user),
      isLoading,
      login,
      register,
      logout,
      getCurrentUser
    }),
    [getCurrentUser, isLoading, login, logout, register, token, user]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
