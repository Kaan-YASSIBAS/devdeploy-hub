import { useEffect, useMemo, useState } from "react";
import {
  Activity,
  Boxes,
  CheckCircle2,
  ClipboardList,
  Gauge,
  Info,
  Loader2,
  RefreshCw,
  Rocket,
  Timer,
  TriangleAlert
} from "lucide-react";
import { Link } from "react-router";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis
} from "recharts";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { toast } from "sonner";
import { dashboardApi } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatCard } from "@/components/shared/StatCard";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { cn } from "@/lib/utils";
import type {
  DashboardClusterHealthItem,
  DashboardClusterHealthStatus,
  DashboardTimelineEvent,
  DeploymentListItem
} from "@/types";

const pieColors = ["#22d3ee", "#a78bfa", "#34d399", "#fbbf24", "#f472b6"];

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

function deploymentLink(deployment: DeploymentListItem) {
  if (deployment.source === "legacy" && deployment.legacy_deployment_id) {
    return `/deployments/${deployment.legacy_deployment_id}`;
  }

  return `/deployments/gitops/${encodeURIComponent(deployment.namespace)}/${encodeURIComponent(deployment.name)}`;
}

function buildActivityData(deployments: DeploymentListItem[]) {
  const formatter = new Intl.DateTimeFormat(undefined, { month: "short", day: "2-digit" });
  const counts = new Map<string, number>();

  deployments.forEach((deployment) => {
    const timestamp = deployment.updated_at ?? deployment.created_at;
    if (!timestamp) {
      return;
    }
    const label = formatter.format(new Date(timestamp));
    counts.set(label, (counts.get(label) ?? 0) + 1);
  });

  return Array.from(counts.entries()).map(([time, deploymentsCount]) => ({
    time,
    deployments: deploymentsCount
  }));
}

function clusterHealthVariant(status: DashboardClusterHealthStatus) {
  if (status === "healthy") {
    return "success";
  }

  if (status === "degraded") {
    return "warning";
  }

  if (status === "unavailable") {
    return "danger";
  }

  return "muted";
}

function timelineIcon(event: DashboardTimelineEvent) {
  if (event.status === "failed") {
    return TriangleAlert;
  }

  if (event.status === "pending") {
    return Timer;
  }

  if (event.event_type === "deployment_updated") {
    return RefreshCw;
  }

  if (event.event_type === "deployment_healthy") {
    return CheckCircle2;
  }

  return Info;
}

function DashboardTimeline({ events }: { events: DashboardTimelineEvent[] }) {
  const { t } = useTranslation();

  if (!events.length) {
    return (
      <EmptyState
        className="min-h-[260px]"
        description={t("dashboard.timelineEmptyDescription")}
        icon={<Activity className="h-5 w-5" />}
        title={t("dashboard.timelineEmptyTitle")}
      />
    );
  }

  return (
    <div className="space-y-4">
      {events.map((event, index) => {
        const isLast = index === events.length - 1;
        const Icon = timelineIcon(event);
        return (
          <div key={event.id} className="relative flex gap-4">
            {!isLast ? <div className="absolute left-4 top-8 h-full w-px bg-white/10" /> : null}
            <div
              className={cn(
                "relative z-10 flex h-8 w-8 items-center justify-center rounded-full border bg-slate-950",
                event.status === "complete" && "border-emerald-300/40 text-emerald-200",
                event.status === "current" && "border-cyan-300/40 text-cyan-200",
                event.status === "failed" && "border-red-300/40 text-red-200",
                event.status === "pending" && "border-white/10 text-slate-500"
              )}
            >
              <Icon className="h-4 w-4" />
            </div>
            <div className="min-w-0 flex-1 pb-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="font-medium text-white">
                  {t(`dashboard.timelineEvents.${event.event_type}.title`, {
                    deployment: event.deployment_name
                  })}
                </p>
                <span className="text-xs text-slate-500">{formatDate(event.timestamp)}</span>
              </div>
              {event.status === "current" ? (
                <Badge className="mt-2" variant="info">
                  {t("dashboard.timelineInProgress")}
                </Badge>
              ) : null}
              <p className="mt-1 text-sm leading-6 text-slate-400">
                {t(`dashboard.timelineEvents.${event.event_type}.description`, {
                  namespace: event.namespace,
                  deployment: event.deployment_name
                })}
              </p>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function ClusterHealthGrid({ items }: { items: DashboardClusterHealthItem[] }) {
  const { t } = useTranslation();

  if (!items.length) {
    return (
      <EmptyState
        className="min-h-[220px] sm:col-span-2"
        description={t("dashboard.clusterHealthEmptyDescription")}
        icon={<Gauge className="h-5 w-5" />}
        title={t("dashboard.clusterHealthEmptyTitle")}
      />
    );
  }

  return (
    <>
      {items.map((item) => (
        <div key={item.key} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-3">
              <Gauge className="h-4 w-4 text-cyan-200" />
              <span className="text-sm font-medium text-slate-200">{item.name}</span>
            </div>
            <Badge variant={clusterHealthVariant(item.status)}>
              {t(`dashboard.clusterHealthStatus.${item.status}`)}
            </Badge>
          </div>
          <p className="mt-3 text-sm leading-6 text-slate-400">
            {t(`dashboard.clusterHealthDetails.${item.key}.${item.status}`)}
          </p>
        </div>
      ))}
    </>
  );
}

export function DashboardPage() {
  const { t } = useTranslation();
  const [lastRefreshed, setLastRefreshed] = useState<Date | null>(null);
  const dashboardQuery = useQuery({ queryKey: ["dashboard-summary"], queryFn: dashboardApi.summary });
  const summary = dashboardQuery.data;
  const activityData = useMemo(() => buildActivityData(summary?.recent_deployments ?? []), [summary?.recent_deployments]);
  const environmentDistribution = summary?.environment_distribution ?? [];

  useEffect(() => {
    if (summary) {
      setLastRefreshed(new Date());
    }
  }, [summary]);

  const handleRefresh = async () => {
    const result = await dashboardQuery.refetch();
    if (result.error) {
      toast.error(t("api.errors.dashboardSummaryFailed"));
      return;
    }
    toast.success(t("dashboard.refresh.success"));
  };

  const columns: Column<DeploymentListItem>[] = [
    {
      key: "deployment",
      header: t("deployments.table.deployment"),
      render: (deployment) => (
        <div>
          <p className="font-medium text-white">{deployment.name}</p>
          <p className="text-xs text-slate-500">{deployment.namespace}</p>
        </div>
      )
    },
    {
      key: "image",
      header: t("deployments.table.imageTag"),
      render: (deployment) => (
        <div>
          <p className="font-mono text-xs text-slate-300">{deployment.image ?? "-"}</p>
          <p className="font-mono text-xs text-slate-500">{deployment.tag ?? "-"}</p>
        </div>
      )
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
      key: "replicas",
      header: t("common.replicas"),
      render: (deployment) => `${deployment.available_replicas}/${deployment.replicas}`
    },
    {
      key: "actions",
      header: t("common.actions"),
      render: (deployment) => (
        <Button asChild size="sm" variant="ghost">
          <Link to={deploymentLink(deployment)}>{t("common.viewDetails")}</Link>
        </Button>
      )
    }
  ];

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            {lastRefreshed ? (
              <span className="text-xs text-slate-500">
                {t("dashboard.refresh.lastRefreshed", { time: formatDate(lastRefreshed.toISOString()) })}
              </span>
            ) : null}
            <Button disabled={dashboardQuery.isFetching} variant="outline" onClick={() => void handleRefresh()}>
              <RefreshCw className={cn("h-4 w-4", dashboardQuery.isFetching && "animate-spin")} />
              {t("common.refresh")}
            </Button>
          </div>
        }
        description={t("dashboard.description")}
        title={t("dashboard.title")}
      />

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-6">
        <StatCard
          detail={t("dashboard.stats.details.totalApps")}
          icon={<Boxes className="h-5 w-5" />}
          label={t("dashboard.stats.totalApps")}
          value={dashboardQuery.isLoading ? "..." : String(summary?.application_count ?? 0)}
        />
        <StatCard
          detail={t("dashboard.stats.details.totalDeployments")}
          icon={<Rocket className="h-5 w-5" />}
          label={t("dashboard.stats.totalDeployments")}
          tone="violet"
          value={dashboardQuery.isLoading ? "..." : String(summary?.deployment_count ?? 0)}
        />
        <StatCard
          detail={t("dashboard.stats.details.pendingDeployments")}
          icon={<Activity className="h-5 w-5" />}
          label={t("dashboard.stats.pendingDeployments")}
          tone="amber"
          value={dashboardQuery.isLoading ? "..." : String(summary?.pending_deployment_count ?? 0)}
        />
        <StatCard
          detail={t("dashboard.stats.details.runningDeployments")}
          icon={<Loader2 className="h-5 w-5" />}
          label={t("dashboard.stats.runningDeployments")}
          tone="cyan"
          value={dashboardQuery.isLoading ? "..." : String(summary?.running_deployment_count ?? 0)}
        />
        <StatCard
          detail={t("dashboard.stats.details.successfulDeployments")}
          icon={<CheckCircle2 className="h-5 w-5" />}
          label={t("dashboard.stats.successfulDeployments")}
          tone="emerald"
          value={dashboardQuery.isLoading ? "..." : String(summary?.successful_deployment_count ?? 0)}
        />
        <StatCard
          detail={t("dashboard.stats.details.failedDeployments")}
          icon={<TriangleAlert className="h-5 w-5" />}
          label={t("dashboard.stats.failedDeployments")}
          tone="red"
          value={dashboardQuery.isLoading ? "..." : String(summary?.failed_deployment_count ?? 0)}
        />
      </div>
      {dashboardQuery.isError ? (
        <div className="mt-4 rounded-2xl border border-red-300/20 bg-red-500/10 px-4 py-3 text-sm text-red-100">
          {t("api.errors.dashboardSummaryFailed")}
        </div>
      ) : null}

      <div className="mt-6 grid gap-6 xl:grid-cols-[1.35fr_0.9fr]">
        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.charts.deploymentActivity")}</CardTitle>
            <CardDescription>{t("dashboard.charts.deploymentActivityDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            {activityData.length ? (
              <div className="h-72">
                <ResponsiveContainer height="100%" width="100%">
                  <BarChart data={activityData}>
                    <CartesianGrid stroke="rgba(148, 163, 184, 0.12)" vertical={false} />
                    <XAxis dataKey="time" stroke="#64748b" tickLine={false} axisLine={false} />
                    <YAxis allowDecimals={false} stroke="#64748b" tickLine={false} axisLine={false} />
                    <Tooltip
                      cursor={{ fill: "rgba(255,255,255,0.04)" }}
                      contentStyle={{
                        background: "rgba(15, 23, 42, 0.92)",
                        border: "1px solid rgba(255,255,255,0.12)",
                        borderRadius: "14px",
                        color: "#e2e8f0"
                      }}
                    />
                    <Bar dataKey="deployments" name={t("common.deployments")} fill="#22d3ee" radius={[8, 8, 2, 2]} />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            ) : (
              <EmptyState
                description={t("dashboard.charts.deploymentActivityEmptyDescription")}
                icon={<Activity className="h-5 w-5" />}
                title={t("dashboard.charts.deploymentActivityEmptyTitle")}
              />
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.charts.environmentDistribution")}</CardTitle>
            <CardDescription>{t("dashboard.charts.environmentDistributionDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            {environmentDistribution.length ? (
              <>
                <div className="h-72">
                  <ResponsiveContainer height="100%" width="100%">
                    <PieChart>
                      <Pie data={environmentDistribution} dataKey="count" innerRadius={62} outerRadius={96} paddingAngle={5}>
                        {environmentDistribution.map((item, index) => (
                          <Cell key={item.environment} fill={pieColors[index % pieColors.length]} />
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
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                  {environmentDistribution.map((item, index) => (
                    <div key={item.environment} className="rounded-xl border border-white/10 bg-white/[0.035] p-3">
                      <div className="mb-2 h-2 w-8 rounded-full" style={{ backgroundColor: pieColors[index % pieColors.length] }} />
                      <p className="text-xs text-slate-500">{t(`environment.${item.environment}`, { defaultValue: item.environment })}</p>
                      <p className="text-lg font-semibold text-white">{item.count}</p>
                    </div>
                  ))}
                </div>
              </>
            ) : (
              <EmptyState
                description={t("dashboard.charts.environmentDistributionEmptyDescription")}
                icon={<Boxes className="h-5 w-5" />}
                title={t("dashboard.charts.environmentDistributionEmptyTitle")}
              />
            )}
          </CardContent>
        </Card>
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-[1.2fr_0.8fr]">
        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.recentDeployments")}</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              columns={columns}
              data={summary?.recent_deployments ?? []}
              emptyState={
                <EmptyState
                  description={dashboardQuery.isError ? t("api.errors.deploymentsLoadFailed") : t("deployments.emptyDescription")}
                  icon={<Rocket className="h-5 w-5" />}
                  title={dashboardQuery.isLoading ? t("common.loading") : t("deployments.emptyTitle")}
                />
              }
              getRowKey={(deployment) => `${deployment.source}/${deployment.namespace}/${deployment.name}/${deployment.id ?? "live"}`}
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.timeline")}</CardTitle>
          </CardHeader>
          <CardContent>
            <DashboardTimeline events={summary?.deployment_timeline ?? []} />
          </CardContent>
        </Card>
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t("dashboard.clusterStatus")}</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2">
            <ClusterHealthGrid items={summary?.cluster_health ?? []} />
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
                {t("dashboard.actions.viewServices")}
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
