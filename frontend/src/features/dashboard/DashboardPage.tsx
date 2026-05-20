import { Activity, Boxes, ClipboardList, Gauge, Rocket, Server, ShieldCheck, TriangleAlert } from "lucide-react";
import { Link } from "react-router-dom";
import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { DeploymentTimeline } from "@/components/shared/DeploymentTimeline";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { MetricChart } from "@/components/shared/MetricChart";
import { StatCard } from "@/components/shared/StatCard";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { applications, deploymentEvents, deployments, environments, metrics, pods } from "@/lib/mock-data";
import type { Deployment } from "@/types";

const pieColors = ["#22d3ee", "#a78bfa", "#34d399"];

export function DashboardPage() {
  const { t } = useTranslation();
  const activeDeployments = deployments.filter((deployment) => ["pending", "running"].includes(deployment.status)).length;
  const healthyPods = pods.filter((pod) => pod.status === "healthy").length;
  const failedDeployments = deployments.filter((deployment) => deployment.status === "failed").length;
  const timelineEvents = deploymentEvents.filter((event) => event.deploymentId === "dep-1041");

  const environmentDistribution = environments.map((environment) => ({
    name: t(`environment.${environment}`),
    value: applications.filter((application) => application.environment === environment).length
  }));

  const columns: Column<Deployment>[] = [
    {
      key: "application",
      header: t("deployments.table.application"),
      render: (deployment) => (
        <div>
          <p className="font-medium text-white">{deployment.applicationName}</p>
          <p className="text-xs text-slate-500">{deployment.id}</p>
        </div>
      )
    },
    {
      key: "imageTag",
      header: t("deployments.table.imageTag"),
      render: (deployment) => deployment.imageTag
    },
    {
      key: "environment",
      header: t("deployments.table.environment"),
      render: (deployment) => <EnvironmentBadge environment={deployment.environment} />
    },
    {
      key: "status",
      header: t("deployments.table.status"),
      render: (deployment) => <StatusBadge status={deployment.status} type="deployment" />
    },
    {
      key: "duration",
      header: t("deployments.table.duration"),
      render: (deployment) => deployment.duration
    }
  ];

  return (
    <div>
      <PageHeader description={t("dashboard.description")} title={t("dashboard.title")} />

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
        <StatCard
          detail={t("dashboard.stats.details.totalApps")}
          icon={<Boxes className="h-5 w-5" />}
          label={t("dashboard.stats.totalApps")}
          value={String(applications.length)}
        />
        <StatCard
          detail={t("dashboard.stats.details.activeDeployments")}
          icon={<Rocket className="h-5 w-5" />}
          label={t("dashboard.stats.activeDeployments")}
          tone="violet"
          value={String(activeDeployments)}
        />
        <StatCard
          detail={t("dashboard.stats.details.healthyPods")}
          icon={<Server className="h-5 w-5" />}
          label={t("dashboard.stats.healthyPods")}
          tone="emerald"
          value={String(healthyPods)}
        />
        <StatCard
          detail={t("dashboard.stats.details.failedDeployments")}
          icon={<TriangleAlert className="h-5 w-5" />}
          label={t("dashboard.stats.failedDeployments")}
          tone="red"
          value={String(failedDeployments)}
        />
        <StatCard
          detail={t("dashboard.stats.details.clusterHealth")}
          icon={<ShieldCheck className="h-5 w-5" />}
          label={t("dashboard.stats.clusterHealth")}
          tone="emerald"
          value="97%"
        />
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-[1.35fr_0.9fr]">
        <MetricChart
          color="#22d3ee"
          data={metrics}
          dataKey="deployments"
          description={t("dashboard.charts.deploymentActivityDescription")}
          label={t("dashboard.charts.deploymentActivity")}
          title={t("dashboard.charts.deploymentActivity")}
          type="bar"
        />

        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.charts.environmentDistribution")}</CardTitle>
            <CardDescription>{t("dashboard.charts.environmentDistributionDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="h-72">
              <ResponsiveContainer height="100%" width="100%">
                <PieChart>
                  <Pie data={environmentDistribution} dataKey="value" innerRadius={62} outerRadius={96} paddingAngle={5}>
                    {environmentDistribution.map((item, index) => (
                      <Cell key={item.name} fill={pieColors[index % pieColors.length]} />
                    ))}
                  </Pie>
                  <Tooltip
                    contentStyle={{
                      background: "rgba(15, 23, 42, 0.92)",
                      border: "1px solid rgba(255,255,255,0.12)",
                      borderRadius: "14px",
                      color: "#e2e8f0"
                    }}
                  />
                </PieChart>
              </ResponsiveContainer>
            </div>
            <div className="grid grid-cols-3 gap-2">
              {environmentDistribution.map((item, index) => (
                <div key={item.name} className="rounded-xl border border-white/10 bg-white/[0.035] p-3">
                  <div className="mb-2 h-2 w-8 rounded-full" style={{ backgroundColor: pieColors[index] }} />
                  <p className="text-xs text-slate-500">{item.name}</p>
                  <p className="text-lg font-semibold text-white">{item.value}</p>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-[1.2fr_0.8fr]">
        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.recentDeployments")}</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable columns={columns} data={deployments.slice(0, 5)} getRowKey={(deployment) => deployment.id} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.timeline")}</CardTitle>
          </CardHeader>
          <CardContent>
            <DeploymentTimeline events={timelineEvents} />
          </CardContent>
        </Card>
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.clusterStatus")}</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2">
            {["apiServer", "scheduler", "controllerManager", "ingress"].map((key) => (
              <div key={key} className="flex items-center justify-between rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <div className="flex items-center gap-3">
                  <Gauge className="h-4 w-4 text-cyan-200" />
                  <span className="text-sm text-slate-300">{t(`dashboard.cluster.${key}`)}</span>
                </div>
                <StatusBadge status="healthy" type="health" />
              </div>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.quickActions")}</CardTitle>
            <CardDescription>{t("dashboard.quickActionsDescription")}</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2">
            <Button asChild variant="outline">
              <Link to="/applications">
                <Boxes className="h-4 w-4" />
                {t("dashboard.actions.registerApplication")}
              </Link>
            </Button>
            <Button asChild variant="outline">
              <Link to="/deployments">
                <Rocket className="h-4 w-4" />
                {t("dashboard.actions.createDeployment")}
              </Link>
            </Button>
            <Button asChild variant="outline">
              <Link to="/logs">
                <ClipboardList className="h-4 w-4" />
                {t("dashboard.actions.viewLogs")}
              </Link>
            </Button>
            <Button asChild variant="outline">
              <Link to="/monitoring">
                <Activity className="h-4 w-4" />
                {t("dashboard.actions.openMonitoring")}
              </Link>
            </Button>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
