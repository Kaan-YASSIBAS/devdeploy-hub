import type { SetupStepKey, SetupStepStatus, SetupWizardState } from "@/features/setup/types";

const STORAGE_PREFIX = "devdeploy-setup";

export const SETUP_STEP_KEYS: SetupStepKey[] = [
  "welcome",
  "environment_type",
  "preflight_checks",
  "github_connection",
  "gitops_repo_setup",
  "argocd_setup",
  "health_check",
  "demo_app_deploy"
];

function nowIso() {
  return new Date().toISOString();
}

function defaultStatuses(): Record<SetupStepKey, SetupStepStatus> {
  return {
    welcome: "not_configured",
    environment_type: "not_configured",
    preflight_checks: "not_configured",
    github_connection: "not_configured",
    gitops_repo_setup: "not_configured",
    argocd_setup: "not_configured",
    health_check: "not_configured",
    demo_app_deploy: "not_configured"
  };
}

export function createDefaultSetupState(): SetupWizardState {
  return {
    completed: false,
    currentStep: 0,
    environmentType: null,
    stepStatuses: defaultStatuses(),
    updatedAt: nowIso()
  };
}

export function setupStorageKey(userId: number) {
  return `${STORAGE_PREFIX}:${userId}`;
}

export function loadSetupState(userId: number): SetupWizardState {
  const raw = localStorage.getItem(setupStorageKey(userId));
  if (!raw) {
    return createDefaultSetupState();
  }

  try {
    const parsed = JSON.parse(raw) as Partial<SetupWizardState>;
    const fallback = createDefaultSetupState();
    return {
      completed: Boolean(parsed.completed),
      currentStep:
        typeof parsed.currentStep === "number" && Number.isFinite(parsed.currentStep)
          ? Math.max(0, Math.min(SETUP_STEP_KEYS.length - 1, Math.floor(parsed.currentStep)))
          : fallback.currentStep,
      environmentType: parsed.environmentType ?? fallback.environmentType,
      stepStatuses: {
        ...fallback.stepStatuses,
        ...(parsed.stepStatuses ?? {})
      },
      updatedAt: typeof parsed.updatedAt === "string" ? parsed.updatedAt : fallback.updatedAt
    };
  } catch {
    localStorage.removeItem(setupStorageKey(userId));
    return createDefaultSetupState();
  }
}

export function saveSetupState(userId: number, state: SetupWizardState) {
  localStorage.setItem(
    setupStorageKey(userId),
    JSON.stringify({
      ...state,
      updatedAt: nowIso()
    })
  );
}

export function resetSetupState(userId: number) {
  localStorage.setItem(setupStorageKey(userId), JSON.stringify(createDefaultSetupState()));
}

export function isSetupCompleted(userId: number) {
  return loadSetupState(userId).completed;
}
