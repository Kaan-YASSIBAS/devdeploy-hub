import { useMemo, useState } from "react";
import { Box, Clock, Container, Gauge, Server } from "lucide-react";
import { useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { applicationsApi, deploymentsApi } from "@/api/client";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs } from "@/components/ui/tabs";
import { PageHeader } from "@/components/layout/PageHeader";
import { ApiDeploymentTimeline } from "@/components/shared/ApiDeploymentTimeline";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { MetricChart } from "@/components/shared/MetricChart";
import { StatCard } from "@/components/shared/StatCard";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { TerminalLogs } from "@/components/shared/TerminalLogs";
import { logs, metrics, pods } from "@/lib/mock-data";
import { useAuth } from "@/features/auth/useAuth";
import type { Application, Deployment, HealthStatus, Pod } from "@/types";

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function deriveHealth(application: Application): HealthStatus {
  return application.id % 11 === 0 ? "degraded" : "healthy";
}

export function ApplicationDetailPage() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { user } = useAuth();
  const [activeTab, setActiveTab] = useState("overview");
  const applicationId = Number(id);
  const applicationQuery = useQuery({
    queryKey: ["application", applicationId],
    queryFn: () => applicationsApi.get(applicationId),
    enabled: Number.isFinite(applicationId)
  });
  const deploymentsQuery = useQuery({ queryKey: ["deployments"], queryFn: deploymentsApi.list });
  const application = applicationQuery.data;

  const appDeployments = useMemo(
    () => (deploymentsQuery.data ?? []).filter((deployment) => deployment.application_id === application?.id),
    [application?.id, deploymentsQuery.data]
  );
  const latestDeployment = appDeployments[0];
  const appPods = useMemo(
    () => pods.filter((pod) => (application ? pod.name.includes(application.name) : false)),
    [application]
  );
  const appLogs = useMemo(() => logs.filter((entry) => entry.app === application?.name), [application?.name]);
  const events = latestDeployment?.events ?? [];

  if (applicationQuery.isLoading) {
    return <EmptyState description={t("applications.detail.loadingDescription")} title={t("common.loading")} />;
  }

  if (!application) {
    return (
      <EmptyState description={t("applications.detail.notFoundDescription")} title={t("applications.detail.notFoundTitle")} />
    );
  }

  const deploymentColumns: Column<Deployment>[] = [
    {
      key: "id",
      header: t("deployments.table.deployment"),
      render: (deployment) => (
        <div>
          <p className="font-medium text-white">{deployment.id}</p>
          <p className="text-xs text-slate-500">{formatDate(deployment.created_at)}</p>
        </div>
      )
    },
    { key: "imageTag", header: t("deployments.table.imageTag"), render: (deployment) => deployment.image_tag },
    { key: "environment", header: t("deployments.table.environment"), render: (deployment) => <EnvironmentBadge environment={deployment.environment} /> },
    { key: "status", header: t("deployments.table.status"), render: (deployment) => <StatusBadge status={deployment.status} type="deployment" /> },
    { key: "created", header: t("deployments.table.created"), render: (deployment) => formatDate(deployment.created_at) }
  ];

  const podColumns: Column<Pod>[] = [
    { key: "pod", header: t("common.pod"), render: (pod) => <span className="font-mono text-xs text-slate-300">{pod.name}</span> },
    { key: "namespace", header: t("common.namespace"), render: (pod) => pod.namespace },
    { key: "status", header: t("common.status"), render: (pod) => <StatusBadge status={pod.status} type="health" /> },
    { key: "cpu", header: t("common.cpu"), render: (pod) => `${pod.cpu}%` },
    { key: "memory", header: t("common.memory"), render: (pod) => `${pod.memory}%` },
    { key: "restarts", header: t("common.restarts"), render: (pod) => pod.restarts },
    { key: "age", header: t("common.age"), render: (pod) => pod.age }
  ];
  const currentImageTag = latestDeployment?.image_tag ?? (
    application.image_name.includes(":") ? application.image_name.split(":").pop() ?? application.image_name : application.image_name
  );

  return (
    <div>
      <PageHeader
        actions={<StatusBadge status={deriveHealth(application)} type="health" />}
        description={t("applications.detail.subtitle")}
        title={application.name}
      />

      <div className="mb-6 flex flex-wrap items-center gap-3">
        <EnvironmentBadge environment={application.default_environment} />
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-slate-400">{application.image_name}</span>
      </div>

      <Tabs
        tabs={[
          { value: "overview", label: t("applications.tabs.overview") },
          { value: "deployments", label: t("applications.tabs.deployments") },
          { value: "pods", label: t("applications.tabs.pods") },
          { value: "logs", label: t("applications.tabs.logs") },
          { value: "metrics", label: t("applications.tabs.metrics") },
          { value: "settings", label: t("applications.tabs.settings") }
        ]}
        value={activeTab}
        onValueChange={setActiveTab}
      />

      <div className="mt-6">
        {activeTab === "overview" ? (
          <div className="space-y-6">
            <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
              <StatCard detail={application.slug} icon={<Container className="h-5 w-5" />} label={t("applications.detail.currentImage")} value={currentImageTag} />
              <StatCard detail={application.slug} icon={<Box className="h-5 w-5" />} label={t("common.environment")} tone="violet" value={t(`environment.${application.default_environment}`)} />
              <StatCard detail={t("deployments.table.created")} icon={<Server className="h-5 w-5" />} label={t("common.replicas")} tone="emerald" value={latestDeployment ? String(latestDeployment.replica_count) : "-"} />
              <StatCard detail={user?.username ?? `${t("common.user")} #${application.owner_id}`} icon={<Clock className="h-5 w-5" />} label={t("applications.detail.lastDeploy")} tone="amber" value={latestDeployment ? formatDate(latestDeployment.created_at) : formatDate(application.created_at)} />
              <StatCard detail={t("applications.detail.previewHealth")} icon={<Gauge className="h-5 w-5" />} label={t("applications.detail.healthScore")} tone="emerald" value={`${deriveHealth(application) === "healthy" ? 98 : 84}%`} />
            </div>
            <div className="grid gap-6 xl:grid-cols-[0.8fr_1.2fr]">
              <Card>
                <CardHeader>
                  <CardTitle>{t("applications.detail.deploymentHistory")}</CardTitle>
                </CardHeader>
                <CardContent>
                  <ApiDeploymentTimeline events={events} status={latestDeployment?.status} />
                </CardContent>
              </Card>
              <MetricChart data={metrics} dataKey="cpu" label={t("common.cpu")} title={t("applications.detail.runtimeMetrics")} />
            </div>
          </div>
        ) : null}

        {activeTab === "deployments" ? (
          <Card>
            <CardContent className="pt-5">
              <DataTable
                columns={deploymentColumns}
                data={appDeployments}
                emptyState={<EmptyState description={t("deployments.emptyDescription")} title={t("deployments.emptyTitle")} />}
                getRowKey={(deployment) => String(deployment.id)}
              />
            </CardContent>
          </Card>
        ) : null}

        {activeTab === "pods" ? (
          <Card>
            <CardHeader>
              <CardTitle>{t("applications.detail.relatedPods")}</CardTitle>
            </CardHeader>
            <CardContent>
              <DataTable columns={podColumns} data={appPods} getRowKey={(pod) => pod.id} />
            </CardContent>
          </Card>
        ) : null}

        {activeTab === "logs" ? <TerminalLogs logs={appLogs.length ? appLogs : logs.slice(0, 4)} /> : null}

        {activeTab === "metrics" ? (
          <div className="grid gap-6 xl:grid-cols-2">
            <MetricChart color="#22d3ee" data={metrics} dataKey="cpu" label={t("common.cpu")} title={t("monitoring.charts.cpu")} />
            <MetricChart color="#a78bfa" data={metrics} dataKey="memory" label={t("common.memory")} title={t("monitoring.charts.memory")} />
          </div>
        ) : null}

        {activeTab === "settings" ? (
          <Card>
            <CardHeader>
              <CardTitle>{t("applications.detail.settingsTitle")}</CardTitle>
              <CardDescription>{t("applications.detail.settingsDescription")}</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-4 md:grid-cols-2">
              {[
                [t("common.owner"), user?.username ?? `${t("common.user")} #${application.owner_id}`],
                [t("common.repository"), application.repository_url ?? "-"],
                [t("applications.modal.containerPort"), String(application.container_port)],
                [t("applications.modal.defaultEnvironment"), t(`environment.${application.default_environment}`)]
              ].map(([label, value]) => (
                <div key={label} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                  <p className="text-xs uppercase text-slate-500">{label}</p>
                  <p className="mt-2 break-all text-sm text-white">{value}</p>
                </div>
              ))}
            </CardContent>
          </Card>
        ) : null}
      </div>
    </div>
  );
}
