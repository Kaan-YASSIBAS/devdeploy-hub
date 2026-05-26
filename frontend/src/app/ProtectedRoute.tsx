import { Navigate, Outlet, useLocation } from "react-router-dom";
import { RouteLoader } from "@/app/RouteLoader";
import { useAuth } from "@/features/auth/useAuth";
import { isSetupCompleted } from "@/features/setup/setup-state";

export function ProtectedRoute() {
  const location = useLocation();
  const { isAuthenticated, isLoading, user } = useAuth();

  if (isLoading) {
    return <RouteLoader />;
  }

  if (!isAuthenticated) {
    return <Navigate replace state={{ from: location }} to="/login" />;
  }

  if (!user) {
    return <RouteLoader />;
  }

  const setupCompleted = isSetupCompleted(user.id);
  const onSetupRoute = location.pathname === "/setup";

  if (!setupCompleted && !onSetupRoute) {
    return <Navigate replace state={{ from: location }} to="/setup" />;
  }

  if (setupCompleted && onSetupRoute) {
    return <Navigate replace to="/dashboard" />;
  }

  return <Outlet />;
}
