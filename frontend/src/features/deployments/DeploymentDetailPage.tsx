import { RotateCcw } from "lucide-react";
import { useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/layout/PageHeader";
import { DeploymentTimeline } from "@/components/shared/DeploymentTimeline";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { TerminalLogs } from "@/components/shared/TerminalLogs";
import { deploymentEvents, deployments, logs } from "@/lib/mock-data";

export function DeploymentDetailPage() {
  const { id } = useParams();
  const { t } = useTranslation();
  const deployment = deployments.find((item) => item.id === id);

  if (!deployment) {
    return (
      <EmptyState description={t("deployments.detail.notFoundDescription")} title={t("deployments.detail.notFoundTitle")} />
    );
  }

  const events = deploymentEvents.filter((event) => event.deploymentId === deployment.id);
  const deploymentLogs = logs.filter((entry) => entry.app === deployment.applicationName);

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
        title={deployment.id}
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
            <DeploymentTimeline events={events.length ? events : deploymentEvents.slice(0, 5)} />
          </CardContent>
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>{t("deployments.detail.metadata")}</CardTitle>
              <CardDescription>{deployment.applicationName}</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-3 sm:grid-cols-2">
              {[
                [t("common.application"), deployment.applicationName],
                [t("deployments.table.imageTag"), deployment.imageTag],
                [t("common.environment"), t(`environment.${deployment.environment}`)],
                [t("common.status"), t(`status.${deployment.status}`)],
                [t("common.strategy"), t(`strategy.${deployment.strategy}`)],
                [t("common.owner"), deployment.owner],
                [t("common.duration"), deployment.duration],
                [t("common.commit"), deployment.commit]
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
