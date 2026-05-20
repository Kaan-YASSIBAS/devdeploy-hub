import { Navigate, Outlet } from "react-router-dom";

export function ProtectedRoute() {
  const hasToken = Boolean(localStorage.getItem("devdeploy-token"));

  if (!hasToken) {
    return <Navigate replace to="/login" />;
  }

  return <Outlet />;
}
