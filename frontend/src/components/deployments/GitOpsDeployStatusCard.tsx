import { CircleAlert, CircleCheck, Clock3, LoaderCircle, RefreshCw } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Badge, type BadgeProps } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { GitOpsOperationTimeline } from "@/components/deployments/GitOpsOperationTimeline";
import type { GitOpsAppDeployResponse, GitOpsAppDeployStatus, GitOpsAppStatusResponse } from "@/types";

type GitOpsDeployStatusCardProps = {
  deployResponse: GitOpsAppDeployResponse;
  statusResponse?: GitOpsAppStatusResponse;
  isFetching: boolean;
  timedOut: boolean;
  errorKey?: string;
  onRefresh: () => void;
};

function shortRevision(value: string | null | undefined) {
  return value ? value.slice(0, 12) : "-";
}

function statusVariant(status: GitOpsAppDeployStatus): BadgeProps["variant"] {
  if (status === "deployed") {
    return "success";
  }
  if (status === "degraded") {
    return "danger";
  }
  if (status === "unknown") {
    return "muted";
  }
  return "warning";
}

function createProgressStep(status: GitOpsAppDeployStatus): number {
  if (status === "pushed_waiting_for_argocd") return 1;
  if (status === "argocd_observing") return 2;
  if (status === "argocd_synced") return 3;
  if (status === "workload_progressing") return 4;
  if (status === "deployed") return 5;
  return 2;
}

function StatusIcon({ status, isFetching }: { status: GitOpsAppDeployStatus; isFetching: boolean }) {
  if (isFetching && status !== "deployed" && status !== "degraded") {
    return <LoaderCircle className="h-5 w-5 animate-spin text-cyan-300" />;
  }
  if (status === "deployed") {
    return <CircleCheck className="h-5 w-5 text-emerald-300" />;
  }
  if (status === "degraded") {
    return <CircleAlert className="h-5 w-5 text-red-300" />;
  }
  return <Clock3 className="h-5 w-5 text-amber-300" />;
}

export function GitOpsDeployStatusCard({
  deployResponse,
  statusResponse,
  isFetching,
  timedOut,
  errorKey,
  onRefresh
}: GitOpsDeployStatusCardProps) {
  const { t } = useTranslation();
  const status = statusResponse?.status ?? deployResponse.status;
  const workload = statusResponse?.workload;
  const rootApplication = statusResponse?.root_application;

  return (
    <Card aria-live="polite" className="mb-6">
      <CardHeader className="flex flex-row items-start justify-between gap-4 space-y-0">
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <StatusIcon isFetching={isFetching} status={status} />
            <CardTitle>{t("deployments.gitopsDeploy.progressTitle")}</CardTitle>
            <Badge variant={statusVariant(status)}>{t(`deployments.gitopsDeploy.status.${status}`)}</Badge>
          </div>
          <CardDescription>{t(`deployments.gitopsDeploy.statusMessage.${status}`)}</CardDescription>
        </div>
        <Button
          aria-label={t("deployments.gitopsDeploy.refreshStatus")}
          disabled={isFetching}
          size="icon"
          variant="outline"
          onClick={onRefresh}
        >
          <RefreshCw className={isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
        </Button>
      </CardHeader>

      <CardContent className="space-y-5">
        <p className="text-sm leading-6 text-slate-300">{statusResponse?.message ?? deployResponse.message}</p>

        <GitOpsOperationTimeline
          activeStep={createProgressStep(status)}
          completed={status === "deployed"}
          kind="create"
          timedOut={timedOut && status !== "deployed" && status !== "degraded"}
        />

        {errorKey ? (
          <div className="rounded-lg border border-red-300/20 bg-red-500/10 px-4 py-3 text-sm text-red-100" role="alert">
            {t(errorKey)}
          </div>
        ) : null}

        <div className="grid border-y border-white/10 sm:grid-cols-2 xl:grid-cols-4">
          <div className="py-4 sm:pr-4">
            <p className="text-xs text-slate-500">{t("deployments.gitopsDeploy.commit")}</p>
            <p className="mt-1 font-mono text-sm text-cyan-100">{shortRevision(deployResponse.commit_sha)}</p>
          </div>
          <div className="border-white/10 py-4 sm:border-l sm:px-4">
            <p className="text-xs text-slate-500">{t("deployments.gitopsDeploy.observedRevision")}</p>
            <p className="mt-1 font-mono text-sm text-slate-200">{shortRevision(statusResponse?.observed_revision)}</p>
          </div>
          <div className="border-white/10 py-4 xl:border-l xl:px-4">
            <p className="text-xs text-slate-500">{t("deployments.gitopsDeploy.rootSyncHealth")}</p>
            <p className="mt-1 text-sm text-slate-200">
              {rootApplication?.sync_status ?? "-"} / {rootApplication?.health_status ?? "-"}
            </p>
          </div>
          <div className="border-white/10 py-4 sm:border-l sm:pl-4">
            <p className="text-xs text-slate-500">{t("deployments.gitopsDeploy.commitObserved")}</p>
            <p className="mt-1 text-sm text-slate-200">
              {rootApplication ? t(rootApplication.observed_commit_match ? "deployments.gitopsDeploy.yes" : "deployments.gitopsDeploy.no") : "-"}
            </p>
          </div>
        </div>

        <div className="grid gap-x-6 gap-y-4 sm:grid-cols-3">
          <div>
            <p className="text-xs text-slate-500">{t("deployments.gitopsDeploy.deploymentReadiness")}</p>
            <p className="mt-1 text-sm text-slate-200">
              {workload
                ? `${workload.ready_replicas ?? 0}/${workload.desired_replicas ?? 0} (${workload.available_replicas ?? 0} ${t("deployments.gitopsDeploy.available")})`
                : "-"}
            </p>
          </div>
          <div>
            <p className="text-xs text-slate-500">{t("deployments.gitopsDeploy.serviceReadiness")}</p>
            <p className="mt-1 text-sm text-slate-200">
              {workload ? t(workload.service_ready ? "deployments.gitopsDeploy.ready" : "deployments.gitopsDeploy.notReady") : "-"}
            </p>
          </div>
          <div>
            <p className="text-xs text-slate-500">{t("deployments.gitopsDeploy.podReadiness")}</p>
            <p className="mt-1 text-sm text-slate-200">
              {workload ? `${workload.ready_pod_count}/${workload.pod_count}` : "-"}
            </p>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
