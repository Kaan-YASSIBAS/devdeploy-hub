import { CheckCircle2, Circle, LoaderCircle } from "lucide-react";
import { useTranslation } from "react-i18next";

type GitOpsOperationTimelineProps = {
  kind: "create" | "delete";
  activeStep: number;
  completed?: boolean;
  timedOut?: boolean;
  className?: string;
};

const CREATE_STEPS = [
  "deployments.gitopsDeploy.progressSteps.prepare",
  "deployments.gitopsDeploy.progressSteps.writeGit",
  "deployments.gitopsDeploy.progressSteps.waitArgo",
  "deployments.gitopsDeploy.progressSteps.waitRollout",
  "deployments.gitopsDeploy.progressSteps.serviceReady",
  "deployments.gitopsDeploy.progressSteps.completed"
];

const DELETE_STEPS = [
  "deployments.records.destroy.progressSteps.prepare",
  "deployments.records.destroy.progressSteps.removeGit",
  "deployments.records.destroy.progressSteps.waitPrune",
  "deployments.records.destroy.progressSteps.cleanup",
  "deployments.records.destroy.progressSteps.completed"
];

export function GitOpsOperationTimeline({
  kind,
  activeStep,
  completed = false,
  timedOut = false,
  className = ""
}: GitOpsOperationTimelineProps) {
  const { t } = useTranslation();
  const steps = kind === "create" ? CREATE_STEPS : DELETE_STEPS;
  const descriptionKey =
    kind === "create"
      ? "deployments.gitopsDeploy.operationDescription"
      : "deployments.records.destroy.operationDescription";
  const boundedActiveStep = Math.max(0, Math.min(activeStep, steps.length - 1));

  return (
    <div className={`rounded-lg border border-white/10 bg-white/[0.03] px-4 py-3 ${className}`}>
      <p className="text-sm leading-6 text-slate-300">{t(descriptionKey)}</p>
      <ol className="mt-3 grid gap-2 sm:grid-cols-2">
        {steps.map((stepKey, index) => {
          const isDone = completed || index < boundedActiveStep;
          const isActive = !completed && index === boundedActiveStep;
          return (
            <li className="flex items-center gap-2 text-sm" key={stepKey}>
              {isDone ? (
                <CheckCircle2 className="h-4 w-4 shrink-0 text-emerald-300" />
              ) : isActive ? (
                <LoaderCircle className="h-4 w-4 shrink-0 animate-spin text-cyan-300" />
              ) : (
                <Circle className="h-4 w-4 shrink-0 text-slate-600" />
              )}
              <span className={isDone || isActive ? "text-slate-100" : "text-slate-500"}>{t(stepKey)}</span>
            </li>
          );
        })}
      </ol>
      {timedOut ? (
        <p className="mt-3 rounded-md border border-amber-300/20 bg-amber-500/10 px-3 py-2 text-sm text-amber-100">
          {t("deployments.gitopsDeploy.pollingTimedOut")}
        </p>
      ) : null}
    </div>
  );
}
