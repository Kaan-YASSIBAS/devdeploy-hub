import { lazy, Suspense, type ReactNode } from "react";
import { createBrowserRouter, Navigate } from "react-router";
import { AppShell } from "@/components/layout/AppShell";
import { ProtectedRoute } from "@/app/ProtectedRoute";
import { RouteLoader } from "@/app/RouteLoader";

const LandingPage = lazy(() => import("@/features/auth/LandingPage").then(({ LandingPage }) => ({ default: LandingPage })));
const LoginPage = lazy(() => import("@/features/auth/LoginPage").then(({ LoginPage }) => ({ default: LoginPage })));
const RegisterPage = lazy(() => import("@/features/auth/RegisterPage").then(({ RegisterPage }) => ({ default: RegisterPage })));
const SetupWizardPage = lazy(() => import("@/features/setup/SetupWizardPage").then(({ SetupWizardPage }) => ({ default: SetupWizardPage })));
const DashboardPage = lazy(() => import("@/features/dashboard/DashboardPage").then(({ DashboardPage }) => ({ default: DashboardPage })));
const ApplicationsPage = lazy(() => import("@/features/applications/ApplicationsPage").then(({ ApplicationsPage }) => ({ default: ApplicationsPage })));
const ApplicationDetailPage = lazy(() => import("@/features/applications/ApplicationDetailPage").then(({ ApplicationDetailPage }) => ({ default: ApplicationDetailPage })));
const DeploymentsPage = lazy(() => import("@/features/deployments/DeploymentsPage").then(({ DeploymentsPage }) => ({ default: DeploymentsPage })));
const DeploymentDetailPage = lazy(() => import("@/features/deployments/DeploymentDetailPage").then(({ DeploymentDetailPage }) => ({ default: DeploymentDetailPage })));
const GitOpsDeploymentDetailPage = lazy(() => import("@/features/deployments/GitOpsDeploymentDetailPage").then(({ GitOpsDeploymentDetailPage }) => ({ default: GitOpsDeploymentDetailPage })));
const ClusterPage = lazy(() => import("@/features/cluster/ClusterPage").then(({ ClusterPage }) => ({ default: ClusterPage })));
const LogsPage = lazy(() => import("@/features/monitoring/LogsPage").then(({ LogsPage }) => ({ default: LogsPage })));
const MonitoringPage = lazy(() => import("@/features/monitoring/MonitoringPage").then(({ MonitoringPage }) => ({ default: MonitoringPage })));
const SettingsPage = lazy(() => import("@/features/settings/SettingsPage").then(({ SettingsPage }) => ({ default: SettingsPage })));

function withSuspense(element: ReactNode) {
  return <Suspense fallback={<RouteLoader />}>{element}</Suspense>;
}

export const router = createBrowserRouter([
  {
    path: "/",
    element: withSuspense(<LandingPage />)
  },
  {
    path: "/login",
    element: withSuspense(<LoginPage />)
  },
  {
    path: "/register",
    element: withSuspense(<RegisterPage />)
  },
  {
    element: <ProtectedRoute />,
    children: [
      {
        element: <AppShell />,
        children: [
          { path: "/setup", element: withSuspense(<SetupWizardPage />) },
          { path: "/dashboard", element: withSuspense(<DashboardPage />) },
          { path: "/applications", element: withSuspense(<ApplicationsPage />) },
          { path: "/applications/:id", element: withSuspense(<ApplicationDetailPage />) },
          { path: "/deployments", element: withSuspense(<DeploymentsPage />) },
          { path: "/deployments/gitops/:namespace/:name", element: withSuspense(<GitOpsDeploymentDetailPage />) },
          { path: "/deployments/:id", element: withSuspense(<DeploymentDetailPage />) },
          { path: "/cluster", element: withSuspense(<ClusterPage />) },
          { path: "/logs", element: withSuspense(<LogsPage />) },
          { path: "/monitoring", element: withSuspense(<MonitoringPage />) },
          { path: "/settings", element: withSuspense(<SettingsPage />) }
        ]
      }
    ]
  },
  {
    path: "*",
    element: <Navigate replace to="/" />
  }
]);
