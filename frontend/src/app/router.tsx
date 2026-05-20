import { createBrowserRouter, Navigate } from "react-router-dom";
import { AppShell } from "@/components/layout/AppShell";
import { ProtectedRoute } from "@/app/ProtectedRoute";
import { LandingPage } from "@/features/auth/LandingPage";
import { LoginPage } from "@/features/auth/LoginPage";
import { RegisterPage } from "@/features/auth/RegisterPage";
import { DashboardPage } from "@/features/dashboard/DashboardPage";
import { ApplicationsPage } from "@/features/applications/ApplicationsPage";
import { ApplicationDetailPage } from "@/features/applications/ApplicationDetailPage";
import { DeploymentsPage } from "@/features/deployments/DeploymentsPage";
import { DeploymentDetailPage } from "@/features/deployments/DeploymentDetailPage";
import { ClusterPage } from "@/features/cluster/ClusterPage";
import { LogsPage } from "@/features/monitoring/LogsPage";
import { MonitoringPage } from "@/features/monitoring/MonitoringPage";
import { SettingsPage } from "@/features/settings/SettingsPage";

export const router = createBrowserRouter([
  {
    path: "/",
    element: <LandingPage />
  },
  {
    path: "/login",
    element: <LoginPage />
  },
  {
    path: "/register",
    element: <RegisterPage />
  },
  {
    element: <ProtectedRoute />,
    children: [
      {
        element: <AppShell />,
        children: [
          { path: "/dashboard", element: <DashboardPage /> },
          { path: "/applications", element: <ApplicationsPage /> },
          { path: "/applications/:id", element: <ApplicationDetailPage /> },
          { path: "/deployments", element: <DeploymentsPage /> },
          { path: "/deployments/:id", element: <DeploymentDetailPage /> },
          { path: "/cluster", element: <ClusterPage /> },
          { path: "/logs", element: <LogsPage /> },
          { path: "/monitoring", element: <MonitoringPage /> },
          { path: "/settings", element: <SettingsPage /> }
        ]
      }
    ]
  },
  {
    path: "*",
    element: <Navigate replace to="/" />
  }
]);
