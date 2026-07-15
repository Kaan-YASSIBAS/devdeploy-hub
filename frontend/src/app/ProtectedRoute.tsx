import { useQuery } from "@tanstack/react-query";
import { Navigate, Outlet, useLocation } from "react-router-dom";
import { platformApi } from "@/api/client";
import { RouteLoader } from "@/app/RouteLoader";
import { useAuth } from "@/features/auth/useAuth";

export function ProtectedRoute() {
  const location = useLocation();
  const { isAuthenticated, isLoading, user } = useAuth();
  const platformReadiness = useQuery({
    queryKey: ["platform", "cluster-health"],
    queryFn: platformApi.clusterHealth,
    enabled: !isLoading && isAuthenticated && Boolean(user),
    retry: false,
    staleTime: 30_000
  });

  if (isLoading) {
    return <RouteLoader />;
  }

  if (!isAuthenticated) {
    return <Navigate replace state={{ from: location }} to="/login" />;
  }

  if (!user) {
    return <RouteLoader />;
  }

  const onSetupRoute = location.pathname === "/setup";

  if (platformReadiness.isPending) {
    return <RouteLoader />;
  }

  const setupGateSatisfied = platformReadiness.data?.platform_ready === true;

  if (!setupGateSatisfied && !onSetupRoute) {
    return <Navigate replace state={{ from: location }} to="/setup" />;
  }

  if (setupGateSatisfied && onSetupRoute) {
    return <Navigate replace to="/dashboard" />;
  }

  return <Outlet />;
}
