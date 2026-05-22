import { RotateCcw, Trash2 } from "lucide-react";
import { useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { deploymentsApi, getApiErrorMessage, getApiErrorStatus } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmptyState } from "@/components/shared/EmptyState";
import { StatusBadge } from "@/components/shared/StatusBadge";
import type { DeploymentListItem } from "@/types";

function formatDate(value: string | null) {
  if (!value) {
    return "-";
  }
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function sourceVariant(deployment: DeploymentListItem) {
  if (deployment.source === "gitops" && (deployment.status === "stale" || deployment.status === "deleted")) {
    return "muted";
  }
  if (deployment.source === "gitops" && deployment.status === "deletion_requested") {
    return "warning";
  }
  if (deployment.source === "gitops" && deployment.status === "failed" && !deployment.is_live) {
    return "danger";
  }
  if (deployment.source === "gitops" && !deployment.is_live) {
    return "warning";
  }
  if (deployment.source === "gitops") {
    return "success";
  }
  if (deployment.source === "cluster") {
    return "info";
  }
  return "muted";
}

function sourceLabelKey(deployment: DeploymentListItem) {
  if (deployment.source === "gitops" && deployment.is_live) {
    return "deployments.source.gitopsLive";
  }
  if (deployment.source === "gitops" && deployment.status === "stale") {
    return "deployments.source.staleRequest";
  }
  if (deployment.source === "gitops" && deployment.status === "failed" && !deployment.is_live) {
    return "deployments.source.failedRequest";
  }
  if (deployment.source === "gitops" && !deployment.is_live) {
    return "deployments.source.pendingRequest";
  }
  return `deployments.source.${deployment.source}`;
}

function getErrorKey(status?: number) {
  if (status === 403) {
    return "api.errors.observabilityPermissionDenied";
  }
  if (status === 503) {
    return "api.errors.observabilityUnavailable";
  }
  return "api.errors.deploymentsLoadFailed";
}

export function GitOpsDeploymentDetailPage() {
  const { namespace = "", name = "" } = useParams();
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const deploymentQuery = useQuery({
    queryKey: ["deployments", "gitops", namespace, name],
    queryFn: () => deploymentsApi.getGitOps(namespace, name),
    enabled: Boolean(namespace && name)
  });
  const deployment = deploymentQuery.data;
  const deleteMutation = useMutation({
    mutationFn: (item: DeploymentListItem) => deploymentsApi.deleteGitOps(item.namespace, item.name),
    onSuccess: async (response) => {
      if (response.workflow_triggered) {
        toast.success(t("deployments.gitops.delete.startedToast"));
      } else {
        toast.error(t("api.errors.deploymentAutomationUnavailable"));
      }
      await queryClient.invalidateQueries({ queryKey: ["deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await deploymentQuery.refetch();
    },
    onError: (error) => {
      if (getApiErrorStatus(error) === 503) {
        toast.error(t("api.errors.deploymentAutomationUnavailable"));
        return;
      }
      toast.error(getApiErrorMessage(error) || t("api.errors.deploymentDeleteFailed"));
    }
  });

  if (deploymentQuery.isLoading) {
    return <EmptyState description={t("deployments.detail.loadingDescription")} title={t("common.loading")} />;
  }

  if (!deployment) {
    return (
      <EmptyState
        description={deploymentQuery.isError ? t(getErrorKey(getApiErrorStatus(deploymentQuery.error))) : t("deployments.detail.notFoundDescription")}
        title={t("deployments.detail.notFoundTitle")}
      />
    );
  }

  const image = deployment.image ? `${deployment.image}${deployment.tag ? `:${deployment.tag}` : ""}` : "-";
  const canDelete = deployment.source !== "legacy" && deployment.status !== "deletion_requested" && deployment.status !== "deleted";
  const confirmDelete = () => {
    if (window.confirm(t("deployments.gitops.delete.confirm", { name: deployment.name }))) {
      deleteMutation.mutate(deployment);
    }
  };

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-wrap gap-3">
            <Button disabled variant="outline">
              <RotateCcw className="h-4 w-4" />
              {t("deployments.detail.rollback")}
            </Button>
            <Button disabled={!canDelete || deleteMutation.isPending} variant="danger" onClick={confirmDelete}>
              <Trash2 className="h-4 w-4" />
              {t("deployments.gitops.delete.action")}
            </Button>
          </div>
        }
        description={t("deployments.detail.liveSubtitle")}
        title={deployment.name}
      />

      <div className="mb-6 flex flex-wrap items-center gap-3">
        <StatusBadge status={deployment.status} type="deployment" />
        <Badge variant={sourceVariant(deployment)}>{t(sourceLabelKey(deployment))}</Badge>
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-slate-400">
          {deployment.namespace}
        </span>
      </div>

      <div className="grid gap-6 xl:grid-cols-[0.9fr_1.1fr]">
        <Card>
          <CardHeader>
            <CardTitle>{t("deployments.detail.liveStatus")}</CardTitle>
            <CardDescription>{t("deployments.detail.liveStatusDescription")}</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2">
            {[
              [t("common.status"), t(`status.${deployment.status}`)],
              [t("common.replicas"), `${deployment.available_replicas}/${deployment.replicas}`],
              [t("deployments.table.updatedReplicas"), String(deployment.updated_replicas)],
              [t("deployments.table.source"), t(sourceLabelKey(deployment))]
            ].map(([label, value]) => (
              <div key={label} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <p className="text-xs uppercase text-slate-500">{label}</p>
                <p className="mt-2 break-all text-sm text-white">{value}</p>
              </div>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("deployments.detail.metadata")}</CardTitle>
            <CardDescription>{deployment.app_name}</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2">
            {[
              [t("deployments.gitops.appName"), deployment.app_name],
              [t("common.namespace"), deployment.namespace],
              [t("deployments.gitops.image"), image],
              [t("deployments.gitops.tag"), deployment.tag ?? "-"],
              [t("common.environment"), t(`environment.${deployment.environment}`, { defaultValue: deployment.environment })],
              [t("common.created"), formatDate(deployment.created_at)],
              [t("deployments.table.updated"), formatDate(deployment.updated_at)],
              [t("deployments.table.requestId"), deployment.gitops_request_id ? String(deployment.gitops_request_id) : "-"]
            ].map(([label, value]) => (
              <div key={label} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <p className="text-xs uppercase text-slate-500">{label}</p>
                <p className="mt-2 break-all text-sm text-white">{value}</p>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
