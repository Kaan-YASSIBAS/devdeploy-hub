import { RotateCcw } from "lucide-react";
import { useParams } from "react-router";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { applicationsApi, deploymentsApi } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/layout/PageHeader";
import { ApiDeploymentTimeline } from "@/components/shared/ApiDeploymentTimeline";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { TerminalLogs } from "@/components/shared/TerminalLogs";
import { logs } from "@/lib/mock-data";

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

export function DeploymentDetailPage() {
  const { id } = useParams();
  const { t } = useTranslation();
  const deploymentId = Number(id);
  const deploymentQuery = useQuery({
    queryKey: ["deployment", deploymentId],
    queryFn: () => deploymentsApi.get(deploymentId),
    enabled: Number.isFinite(deploymentId)
  });
  const applicationsQuery = useQuery({ queryKey: ["applications"], queryFn: applicationsApi.list });
  const deployment = deploymentQuery.data;
  const application = applicationsQuery.data?.find((item) => item.id === deployment?.application_id);

  if (deploymentQuery.isLoading) {
    return <EmptyState description={t("deployments.detail.loadingDescription")} title={t("common.loading")} />;
  }

  if (!deployment) {
    return (
      <EmptyState description={t("deployments.detail.notFoundDescription")} title={t("deployments.detail.notFoundTitle")} />
    );
  }

  const events = deployment.events ?? [];
  const deploymentLogs = logs.filter((entry) => entry.app === application?.name);

  return (
    <div>
      <PageHeader
        actions={
          <Button disabled variant="outline">
            <RotateCcw className="h-4 w-4" />
            {t("deployments.detail.rollback")}
          </Button>
        }
        description={t("deployments.detail.subtitle")}
        title={String(deployment.id)}
      />

      <div className="mb-6 flex flex-wrap items-center gap-3">
        <StatusBadge status={deployment.status} type="deployment" />
        <EnvironmentBadge environment={deployment.environment} />
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-slate-400">
          {t("deployments.detail.rollbackDisabled")}
        </span>
      </div>

      <div className="grid gap-6 xl:grid-cols-[0.9fr_1.1fr]">
        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.timeline")}</CardTitle>
          </CardHeader>
          <CardContent>
            <ApiDeploymentTimeline events={events} status={deployment.status} />
          </CardContent>
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>{t("deployments.detail.metadata")}</CardTitle>
              <CardDescription>{application?.name ?? `${t("common.application")} #${deployment.application_id}`}</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-3 sm:grid-cols-2">
              {[
                [t("common.application"), application?.name ?? `${t("common.application")} #${deployment.application_id}`],
                [t("deployments.table.imageTag"), deployment.image_tag],
                [t("common.environment"), t(`environment.${deployment.environment}`)],
                [t("common.status"), t(`status.${deployment.status}`)],
                [t("common.strategy"), t(`strategy.${deployment.strategy}`)],
                [t("common.replicas"), String(deployment.replica_count)],
                [t("common.owner"), `${t("common.user")} #${deployment.requested_by_id}`],
                [t("common.created"), formatDate(deployment.created_at)]
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
              <CardTitle>{t("deployments.detail.logsPreview")}</CardTitle>
            </CardHeader>
            <CardContent>
              <TerminalLogs compact logs={deploymentLogs.length ? deploymentLogs : logs.slice(0, 4)} />
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}
