import { Navigate, Outlet, useLocation } from "react-router-dom";
import { RouteLoader } from "@/app/RouteLoader";
import { useAuth } from "@/features/auth/useAuth";

export function ProtectedRoute() {
  const location = useLocation();
  const { isAuthenticated, isLoading } = useAuth();

  if (isLoading) {
    return <RouteLoader />;
  }

  if (!isAuthenticated) {
    return <Navigate replace state={{ from: location }} to="/login" />;
  }

  return <Outlet />;
}
