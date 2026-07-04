export type SetupStepKey =
  | "welcome"
  | "environment_type"
  | "preflight_checks"
  | "github_connection"
  | "gitops_repo_setup"
  | "argocd_setup"
  | "health_check"
  | "demo_app_deploy";

export type SetupStepStatus = "not_configured" | "pending" | "ready" | "simulated";

export type SetupEnvironmentType = "local_kind" | "local_minikube" | "docker_only" | null;

export type SetupWizardState = {
  version: 2;
  completed: boolean;
  currentStep: number;
  environmentType: SetupEnvironmentType;
  stepStatuses: Record<SetupStepKey, SetupStepStatus>;
  updatedAt: string;
};
