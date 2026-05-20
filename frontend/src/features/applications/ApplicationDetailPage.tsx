import { useMemo, useState } from "react";
import { Box, Clock, Container, Gauge, Server } from "lucide-react";
import { useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs } from "@/components/ui/tabs";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { DeploymentTimeline } from "@/components/shared/DeploymentTimeline";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { MetricChart } from "@/components/shared/MetricChart";
import { StatCard } from "@/components/shared/StatCard";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { TerminalLogs } from "@/components/shared/TerminalLogs";
import { applications, deploymentEvents, deployments, logs, metrics, pods } from "@/lib/mock-data";
import type { Deployment, Pod } from "@/types";

export function ApplicationDetailPage() {
  const { id } = useParams();
  const { t } = useTranslation();
  const [activeTab, setActiveTab] = useState("overview");
  const application = applications.find((item) => item.id === id);

  const appDeployments = useMemo(
    () => deployments.filter((deployment) => deployment.applicationId === application?.id),
    [application?.id]
  );
  const appPods = useMemo(() => pods.filter((pod) => pod.applicationId === application?.id), [application?.id]);
  const appLogs = useMemo(() => logs.filter((entry) => entry.app === application?.name), [application?.name]);
  const events = deploymentEvents.filter((event) => event.deploymentId === appDeployments[0]?.id);

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
          <p className="text-xs text-slate-500">{deployment.commit}</p>
        </div>
      )
    },
    { key: "imageTag", header: t("deployments.table.imageTag"), render: (deployment) => deployment.imageTag },
    { key: "environment", header: t("deployments.table.environment"), render: (deployment) => <EnvironmentBadge environment={deployment.environment} /> },
    { key: "status", header: t("deployments.table.status"), render: (deployment) => <StatusBadge status={deployment.status} type="deployment" /> },
    { key: "created", header: t("deployments.table.created"), render: (deployment) => deployment.createdAt }
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
  const currentImageTag = application.image.includes(":") ? application.image.split(":").pop() ?? application.image : application.image;

  return (
    <div>
      <PageHeader
        actions={<StatusBadge status={application.health} type="health" />}
        description={t("applications.detail.subtitle")}
        title={application.name}
      />

      <div className="mb-6 flex flex-wrap items-center gap-3">
        <EnvironmentBadge environment={application.environment} />
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-slate-400">{application.image}</span>
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
              <StatCard detail={application.image} icon={<Container className="h-5 w-5" />} label={t("applications.detail.currentImage")} value={currentImageTag} />
              <StatCard detail={application.namespace} icon={<Box className="h-5 w-5" />} label={t("common.environment")} tone="violet" value={t(`environment.${application.environment}`)} />
              <StatCard detail={application.namespace} icon={<Server className="h-5 w-5" />} label={t("common.replicas")} tone="emerald" value={String(application.replicas)} />
              <StatCard detail={application.owner} icon={<Clock className="h-5 w-5" />} label={t("applications.detail.lastDeploy")} tone="amber" value={application.lastDeployment} />
              <StatCard detail={t("dashboard.stats.details.healthyPods")} icon={<Gauge className="h-5 w-5" />} label={t("applications.detail.healthScore")} tone="emerald" value={`${application.healthScore}%`} />
            </div>
            <div className="grid gap-6 xl:grid-cols-[0.8fr_1.2fr]">
              <Card>
                <CardHeader>
                  <CardTitle>{t("applications.detail.deploymentHistory")}</CardTitle>
                </CardHeader>
                <CardContent>
                  <DeploymentTimeline events={events.length ? events : deploymentEvents.slice(0, 5)} />
                </CardContent>
              </Card>
              <MetricChart data={metrics} dataKey="cpu" label={t("common.cpu")} title={t("applications.detail.runtimeMetrics")} />
            </div>
          </div>
        ) : null}

        {activeTab === "deployments" ? (
          <Card>
            <CardContent className="pt-5">
              <DataTable columns={deploymentColumns} data={appDeployments} getRowKey={(deployment) => deployment.id} />
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
                [t("common.owner"), application.owner],
                [t("common.repository"), application.repository],
                [t("common.namespace"), application.namespace],
                [t("common.replicas"), String(application.replicas)]
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
