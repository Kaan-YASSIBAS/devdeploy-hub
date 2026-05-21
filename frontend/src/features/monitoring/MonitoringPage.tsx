import { Boxes, CheckCircle2, Cpu, DatabaseZap, MemoryStick, RefreshCw, RotateCcw, ShieldAlert } from "lucide-react";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { getApiErrorStatus, observabilityApi } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmptyState } from "@/components/shared/EmptyState";
import { MetricChart } from "@/components/shared/MetricChart";
import { StatCard } from "@/components/shared/StatCard";
import { metrics } from "@/lib/mock-data";
import type { ObservabilityComponentHealth } from "@/types";

const DEFAULT_NAMESPACE = "devdeploy";

function formatNumber(value: number | null | undefined, digits = 2) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return null;
  }

  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: digits
  }).format(value);
}

function formatBytes(value: number | null | undefined) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return null;
  }

  if (value >= 1024 ** 3) {
    return `${formatNumber(value / 1024 ** 3, 2)} GiB`;
  }

  return `${formatNumber(value / 1024 ** 2, 1)} MiB`;
}

function getErrorKey(status?: number) {
  if (status === 403) {
    return "api.errors.observabilityPermissionDenied";
  }

  if (status === 503) {
    return "api.errors.observabilityUnavailable";
  }

  return "api.errors.observabilityLoadFailed";
}

function HealthCard({ isLoading, label, health }: { isLoading: boolean; label: string; health?: ObservabilityComponentHealth }) {
  const { t } = useTranslation();
  const available = Boolean(health?.available);
  const statusLabel = isLoading ? t("common.loading") : available ? t("observability.available") : t("common.unavailable");

  return (
    <Card className="p-5">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-sm text-slate-400">{label}</p>
          <p className="mt-2 text-lg font-semibold text-white">{statusLabel}</p>
        </div>
        <div className="flex h-11 w-11 items-center justify-center rounded-2xl border border-white/10 bg-white/[0.045] text-cyan-200">
          {available ? <CheckCircle2 className="h-5 w-5 text-emerald-300" /> : <ShieldAlert className="h-5 w-5 text-amber-300" />}
        </div>
      </div>
      <div className="mt-5">
        <Badge variant={isLoading ? "muted" : available ? "success" : "warning"}>
          {isLoading ? t("common.loading") : available ? t("observability.connected") : t("observability.notReachable")}
        </Badge>
      </div>
    </Card>
  );
}

export function MonitoringPage() {
  const { t } = useTranslation();
  const [range, setRange] = useState("sixHours");
  const [namespace, setNamespace] = useState(DEFAULT_NAMESPACE);
  const healthQuery = useQuery({ queryKey: ["observability", "health"], queryFn: observabilityApi.health });
  const clusterMetricsQuery = useQuery({ queryKey: ["observability", "metrics", "cluster"], queryFn: observabilityApi.clusterMetrics });
  const namespaceMetricsQuery = useQuery({
    queryKey: ["observability", "metrics", "namespace", namespace],
    queryFn: () => observabilityApi.namespaceMetrics(namespace)
  });
  const namespacesQuery = useQuery({ queryKey: ["observability", "namespaces"], queryFn: observabilityApi.namespaces });
  const namespaceOptions = namespacesQuery.data?.map((item) => ({ value: item.name, label: item.name })) ?? [{ value: namespace, label: namespace }];
  const firstError = healthQuery.error ?? clusterMetricsQuery.error ?? namespaceMetricsQuery.error;
  const isLoading = healthQuery.isLoading || clusterMetricsQuery.isLoading || namespaceMetricsQuery.isLoading;
  const unavailable = isLoading ? "..." : t("common.unavailable");
  const clusterMetrics = clusterMetricsQuery.data;
  const namespaceMetrics = namespaceMetricsQuery.data;

  const refresh = () => {
    void healthQuery.refetch();
    void clusterMetricsQuery.refetch();
    void namespaceMetricsQuery.refetch();
    void namespacesQuery.refetch();
  };

  return (
    <div>
      <PageHeader
        actions={
          <div className="grid gap-3 sm:grid-cols-[170px_170px_auto]">
            <Select
              aria-label={t("monitoring.timeRange")}
              options={[
                { value: "oneHour", label: t("monitoring.ranges.oneHour") },
                { value: "sixHours", label: t("monitoring.ranges.sixHours") },
                { value: "twentyFourHours", label: t("monitoring.ranges.twentyFourHours") },
                { value: "sevenDays", label: t("monitoring.ranges.sevenDays") }
              ]}
              value={range}
              onChange={(event) => setRange(event.target.value)}
            />
            <Select
              aria-label={t("common.namespace")}
              options={namespaceOptions.some((item) => item.value === namespace) ? namespaceOptions : [{ value: namespace, label: namespace }, ...namespaceOptions]}
              value={namespace}
              onChange={(event) => setNamespace(event.target.value)}
            />
            <Button variant="outline" onClick={refresh}>
              <RefreshCw className="h-4 w-4" />
              {t("common.refresh")}
            </Button>
          </div>
        }
        description={t("monitoring.description")}
        title={t("monitoring.title")}
      />

      <div className="grid gap-4 md:grid-cols-3">
        <HealthCard health={healthQuery.data?.kubernetes} isLoading={healthQuery.isLoading} label={t("observability.kubernetes")} />
        <HealthCard health={healthQuery.data?.prometheus} isLoading={healthQuery.isLoading} label={t("observability.prometheus")} />
        <HealthCard health={healthQuery.data?.loki} isLoading={healthQuery.isLoading} label={t("observability.loki")} />
      </div>

      {firstError ? (
        <EmptyState className="mt-6" description={t(getErrorKey(getApiErrorStatus(firstError)))} title={t("monitoring.unavailableTitle")} />
      ) : null}

      <div className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-5">
        <StatCard
          detail={t("monitoring.metrics.clusterScope")}
          icon={<Cpu className="h-5 w-5" />}
          label={t("monitoring.metrics.cpuCores")}
          value={formatNumber(clusterMetrics?.cpu_usage_cores) ?? unavailable}
        />
        <StatCard
          detail={t("monitoring.metrics.clusterScope")}
          icon={<MemoryStick className="h-5 w-5" />}
          label={t("monitoring.metrics.memoryWorkingSet")}
          tone="violet"
          value={formatBytes(clusterMetrics?.memory_working_set_bytes) ?? unavailable}
        />
        <StatCard
          detail={namespace}
          icon={<Boxes className="h-5 w-5" />}
          label={t("monitoring.metrics.podCount")}
          tone="emerald"
          value={formatNumber(namespaceMetrics?.pod_count, 0) ?? unavailable}
        />
        <StatCard
          detail={namespace}
          icon={<RotateCcw className="h-5 w-5" />}
          label={t("monitoring.metrics.restartCount")}
          tone="amber"
          value={formatNumber(namespaceMetrics?.restart_count, 0) ?? unavailable}
        />
        <StatCard
          detail={namespace}
          icon={<DatabaseZap className="h-5 w-5" />}
          label={t("monitoring.metrics.availableReplicas")}
          tone="red"
          value={formatNumber(namespaceMetrics?.deployment_available_replicas, 0) ?? unavailable}
        />
      </div>

      <div className="mt-8 space-y-4">
        <div>
          <h2 className="text-base font-semibold text-white">{t("monitoring.previewTitle")}</h2>
          <p className="mt-1 text-sm leading-6 text-slate-400">{t("monitoring.previewDescription")}</p>
        </div>
        <div className="grid gap-6 xl:grid-cols-2">
          <MetricChart color="#22d3ee" data={metrics} dataKey="cpu" label={t("common.cpu")} title={t("monitoring.charts.cpu")} />
          <MetricChart color="#a78bfa" data={metrics} dataKey="memory" label={t("common.memory")} title={t("monitoring.charts.memory")} />
          <MetricChart color="#34d399" data={metrics} dataKey="requests" label={t("monitoring.charts.requests")} title={t("monitoring.charts.requests")} type="bar" />
          <MetricChart color="#f87171" data={metrics} dataKey="errors" label={t("monitoring.charts.errors")} title={t("monitoring.charts.errors")} type="bar" />
          <div className="xl:col-span-2">
            <MetricChart color="#fbbf24" data={metrics} dataKey="restarts" label={t("monitoring.charts.restarts")} title={t("monitoring.charts.restarts")} type="bar" />
          </div>
        </div>
      </div>
    </div>
  );
}
