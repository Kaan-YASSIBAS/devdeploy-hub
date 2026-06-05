import { useEffect, useMemo, useRef, useState } from "react";
import { CheckCircle2, ChevronLeft, ChevronRight, PlayCircle, RefreshCw, Sparkles } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { getApiErrorMessage, setupApi } from "@/api/client";
import { PageHeader } from "@/components/layout/PageHeader";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { useAuth } from "@/features/auth/useAuth";
import { SETUP_STEP_KEYS, createDefaultSetupState, loadSetupState, resetSetupState, saveSetupState } from "@/features/setup/setup-state";
import type { SetupEnvironmentType, SetupStepKey, SetupStepStatus, SetupWizardState } from "@/features/setup/types";
import type { SetupPreflightCheckStatus, SetupPreflightOverallStatus, SetupPreflightResponse } from "@/types";

type StepDefinition = {
  key: SetupStepKey;
  titleKey: string;
  descriptionKey: string;
};

const STEPS: StepDefinition[] = [
  { key: "welcome", titleKey: "setup.steps.welcome.title", descriptionKey: "setup.steps.welcome.description" },
  { key: "environment_type", titleKey: "setup.steps.environment.title", descriptionKey: "setup.steps.environment.description" },
  { key: "preflight_checks", titleKey: "setup.steps.preflight.title", descriptionKey: "setup.steps.preflight.description" },
  { key: "github_connection", titleKey: "setup.steps.github.title", descriptionKey: "setup.steps.github.description" },
  { key: "gitops_repo_setup", titleKey: "setup.steps.gitopsRepo.title", descriptionKey: "setup.steps.gitopsRepo.description" },
  { key: "argocd_setup", titleKey: "setup.steps.argocd.title", descriptionKey: "setup.steps.argocd.description" },
  { key: "health_check", titleKey: "setup.steps.health.title", descriptionKey: "setup.steps.health.description" },
  { key: "demo_app_deploy", titleKey: "setup.steps.demoDeploy.title", descriptionKey: "setup.steps.demoDeploy.description" }
];

function isStepComplete(status: SetupStepStatus) {
  return status === "ready" || status === "simulated";
}

function statusVariant(status: SetupStepStatus) {
  if (status === "ready") {
    return "success";
  }
  if (status === "pending") {
    return "warning";
  }
  if (status === "simulated") {
    return "info";
  }
  return "muted";
}

function preflightStatusVariant(status: SetupPreflightCheckStatus | SetupPreflightOverallStatus) {
  if (status === "ok" || status === "ready") {
    return "success";
  }
  if (status === "warning" || status === "warnings") {
    return "warning";
  }
  if (status === "failed" || status === "blocked") {
    return "danger";
  }
  return "muted";
}

export function SetupWizardPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { user } = useAuth();
  const timerRef = useRef<number | null>(null);

  const [state, setState] = useState<SetupWizardState>(() => createDefaultSetupState());
  const [preflightResult, setPreflightResult] = useState<SetupPreflightResponse | null>(null);
  const [preflightError, setPreflightError] = useState<string | null>(null);
  const [isRunningPreflight, setIsRunningPreflight] = useState(false);

  useEffect(() => {
    if (!user) {
      return;
    }
    setState(loadSetupState(user.id));
  }, [user]);

  useEffect(() => {
    return () => {
      if (timerRef.current) {
        window.clearTimeout(timerRef.current);
      }
    };
  }, []);

  const activeStep = useMemo(() => STEPS[Math.max(0, Math.min(state.currentStep, STEPS.length - 1))], [state.currentStep]);
  const activeStatus = state.stepStatuses[activeStep.key];
  const canFinish = SETUP_STEP_KEYS.every((stepKey) => isStepComplete(state.stepStatuses[stepKey]));
  const selectedEnvironment = state.environmentType ?? "local_kind";

  const updateState = (updater: (previous: SetupWizardState) => SetupWizardState) => {
    setState((previous) => {
      const nextState = updater(previous);
      if (user) {
        saveSetupState(user.id, nextState);
      }
      return nextState;
    });
  };

  const setStepStatus = (stepKey: SetupStepKey, status: SetupStepStatus) => {
    updateState((previous) => ({
      ...previous,
      stepStatuses: {
        ...previous.stepStatuses,
        [stepKey]: status
      }
    }));
  };

  const goToStep = (index: number) => {
    updateState((previous) => ({
      ...previous,
      currentStep: Math.max(0, Math.min(STEPS.length - 1, index))
    }));
  };

  const markWelcomeReady = () => {
    setStepStatus("welcome", "ready");
    goToStep(Math.min(state.currentStep + 1, STEPS.length - 1));
  };

  const saveEnvironmentType = () => {
    updateState((previous) => ({
      ...previous,
      environmentType: selectedEnvironment,
      stepStatuses: {
        ...previous.stepStatuses,
        environment_type: "ready"
      },
      currentStep: Math.min(previous.currentStep + 1, STEPS.length - 1)
    }));
  };

  const runSimulatedStep = (stepKey: SetupStepKey) => {
    setStepStatus(stepKey, "pending");
    if (timerRef.current) {
      window.clearTimeout(timerRef.current);
    }
    timerRef.current = window.setTimeout(() => {
      setStepStatus(stepKey, "simulated");
    }, 650);
  };

  const runPreflightChecks = async () => {
    setPreflightError(null);
    setIsRunningPreflight(true);
    setStepStatus("preflight_checks", "pending");
    try {
      const result = await setupApi.preflight();
      setPreflightResult(result);
      setStepStatus("preflight_checks", result.overall_status === "blocked" ? "not_configured" : "ready");
      toast.success(t("setup.preflight.messages.completed"));
    } catch (error) {
      setPreflightError(getApiErrorMessage(error));
      setStepStatus("preflight_checks", "not_configured");
      toast.error(t("setup.preflight.messages.failed"));
    } finally {
      setIsRunningPreflight(false);
    }
  };

  const finishSetup = () => {
    if (!canFinish) {
      return;
    }
    updateState((previous) => ({
      ...previous,
      completed: true
    }));
    toast.success(t("setup.messages.completed"));
    navigate("/dashboard", { replace: true });
  };

  const restartSetup = () => {
    if (!user) {
      return;
    }
    resetSetupState(user.id);
    setState(loadSetupState(user.id));
    toast.success(t("setup.messages.reset"));
  };

  const environmentOptions = [
    { value: "local_kind", label: t("setup.environment.localKind") },
    { value: "local_minikube", label: t("setup.environment.localMinikube") },
    { value: "docker_only", label: t("setup.environment.dockerOnly") }
  ];

  return (
    <div>
      <PageHeader
        actions={
          <Button variant="outline" onClick={restartSetup}>
            <RefreshCw className="h-4 w-4" />
            {t("setup.actions.restart")}
          </Button>
        }
        description={t("setup.description")}
        title={t("setup.title")}
      />

      <Card className="mb-6 border-cyan-300/20 bg-cyan-400/[0.06]">
        <CardContent className="flex items-center gap-3 p-4 text-sm text-cyan-100">
          <Sparkles className="h-4 w-4" />
          {t("setup.localFirstHint")}
        </CardContent>
      </Card>

      <div className="grid gap-6 xl:grid-cols-[320px_minmax(0,1fr)]">
        <Card>
          <CardHeader>
            <CardTitle>{t("setup.progressTitle")}</CardTitle>
            <CardDescription>{t("setup.progressDescription")}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {STEPS.map((step, index) => (
              <button
                key={step.key}
                className={`w-full rounded-xl border p-3 text-left transition ${
                  index === state.currentStep
                    ? "border-cyan-300/30 bg-cyan-300/10"
                    : "border-white/10 bg-white/[0.03] hover:border-white/20"
                }`}
                onClick={() => goToStep(index)}
              >
                <div className="mb-2 flex items-center justify-between gap-2">
                  <p className="text-sm font-medium text-white">
                    {index + 1}. {t(step.titleKey)}
                  </p>
                  <Badge variant={statusVariant(state.stepStatuses[step.key])}>
                    {t(`setup.status.${state.stepStatuses[step.key]}`)}
                  </Badge>
                </div>
                <p className="text-xs leading-5 text-slate-400">{t(step.descriptionKey)}</p>
              </button>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t(activeStep.titleKey)}</CardTitle>
            <CardDescription>{t(activeStep.descriptionKey)}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-5">
            {activeStep.key === "welcome" ? (
              <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-sm leading-6 text-slate-300">
                {t("setup.steps.welcome.body")}
              </div>
            ) : null}

            {activeStep.key === "environment_type" ? (
              <div className="space-y-3">
                <Label htmlFor="setup-environment">{t("setup.environment.label")}</Label>
                <Select
                  id="setup-environment"
                  options={environmentOptions}
                  value={selectedEnvironment}
                  onChange={(event) =>
                    updateState((previous) => ({
                      ...previous,
                      environmentType: event.target.value as SetupEnvironmentType
                    }))
                  }
                />
              </div>
            ) : null}

            {activeStep.key === "preflight_checks" ? (
              <div className="space-y-4">
                <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-sm leading-6 text-slate-300">
                  {t("setup.preflight.safeHint")}
                </div>

                <div className="flex flex-wrap items-center gap-2">
                  <Button disabled={isRunningPreflight} onClick={runPreflightChecks}>
                    <RefreshCw className={`h-4 w-4 ${isRunningPreflight ? "animate-spin" : ""}`} />
                    {isRunningPreflight ? t("setup.preflight.running") : t("setup.preflight.run")}
                  </Button>
                  {preflightResult ? (
                    <Badge variant={preflightStatusVariant(preflightResult.overall_status)}>
                      {t(`setup.preflight.overall.${preflightResult.overall_status}`)}
                    </Badge>
                  ) : null}
                </div>

                {preflightError ? (
                  <div className="rounded-2xl border border-red-300/20 bg-red-400/10 p-4 text-sm text-red-100">
                    {preflightError}
                  </div>
                ) : null}

                {preflightResult ? (
                  <div
                    className={`rounded-2xl border p-4 text-sm leading-6 ${
                      preflightResult.runtime_mode === "kubernetes"
                        ? "border-amber-300/20 bg-amber-400/10 text-amber-100"
                        : "border-cyan-300/20 bg-cyan-400/10 text-cyan-100"
                    }`}
                  >
                    <p className="font-medium">
                      {t(`setup.preflight.runtime.${preflightResult.runtime_mode}.title`, {
                        defaultValue: t("setup.preflight.runtime.unknown.title")
                      })}
                    </p>
                    <p className="mt-1 text-slate-300">
                      {t(`setup.preflight.runtime.${preflightResult.runtime_mode}.description`, {
                        defaultValue: preflightResult.runtime_message
                      })}
                    </p>
                  </div>
                ) : null}

                {preflightResult ? (
                  <div className="space-y-3">
                    {preflightResult.checks.map((check) => (
                      <div key={check.id} className="rounded-2xl border border-white/10 bg-white/[0.03] p-4">
                        <div className="flex flex-wrap items-center justify-between gap-2">
                          <p className="text-sm font-medium text-white">
                            {t(`setup.preflight.checks.${check.id}.label`, { defaultValue: check.label })}
                          </p>
                          <Badge variant={preflightStatusVariant(check.status)}>
                            {t(`setup.preflight.status.${check.status}`)}
                          </Badge>
                        </div>
                        <p className="mt-2 text-sm leading-6 text-slate-300">
                          {t(`setup.preflight.checks.${check.id}.${check.status}`, { defaultValue: check.message })}
                        </p>
                        {check.details ? <p className="mt-1 text-xs text-slate-500">{check.details}</p> : null}
                      </div>
                    ))}
                  </div>
                ) : null}
              </div>
            ) : null}

            {!["welcome", "environment_type", "preflight_checks"].includes(activeStep.key) ? (
              <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-sm leading-6 text-slate-300">
                {t("setup.simulatedDescription")}
              </div>
            ) : null}

            <div className="flex flex-wrap gap-2">
              <Badge variant={statusVariant(activeStatus)}>{t(`setup.status.${activeStatus}`)}</Badge>
              {activeStep.key === "welcome" ? (
                <Button onClick={markWelcomeReady}>
                  <CheckCircle2 className="h-4 w-4" />
                  {t("setup.actions.continue")}
                </Button>
              ) : null}
              {activeStep.key === "environment_type" ? (
                <Button onClick={saveEnvironmentType}>
                  <CheckCircle2 className="h-4 w-4" />
                  {t("setup.actions.saveEnvironment")}
                </Button>
              ) : null}
              {!["welcome", "environment_type", "preflight_checks"].includes(activeStep.key) ? (
                <Button onClick={() => runSimulatedStep(activeStep.key)}>
                  <PlayCircle className="h-4 w-4" />
                  {t("setup.actions.runSimulated")}
                </Button>
              ) : null}
            </div>

            <div className="flex flex-wrap justify-between gap-2 border-t border-white/10 pt-4">
              <Button disabled={state.currentStep === 0} variant="outline" onClick={() => goToStep(state.currentStep - 1)}>
                <ChevronLeft className="h-4 w-4" />
                {t("setup.actions.previous")}
              </Button>
              <div className="flex gap-2">
                <Button
                  disabled={state.currentStep >= STEPS.length - 1}
                  variant="outline"
                  onClick={() => goToStep(state.currentStep + 1)}
                >
                  {t("setup.actions.next")}
                  <ChevronRight className="h-4 w-4" />
                </Button>
                <Button disabled={!canFinish} onClick={finishSetup}>
                  <CheckCircle2 className="h-4 w-4" />
                  {t("setup.actions.finish")}
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
