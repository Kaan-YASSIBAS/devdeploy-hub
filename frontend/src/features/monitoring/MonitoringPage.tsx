import { Activity, Boxes, CheckCircle2, Cpu, DatabaseZap, MemoryStick, RefreshCw, RotateCcw, ShieldAlert } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { getApiErrorStatus, observabilityApi } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmptyState } from "@/components/shared/EmptyState";
import { MetricChart } from "@/components/shared/MetricChart";
import { StatCard } from "@/components/shared/StatCard";
import type { MetricSeries, ObservabilityComponentHealth } from "@/types";

const DEFAULT_NAMESPACE = "devdeploy";
const DEFAULT_RANGE = "15m";
const DEFAULT_AUTO_REFRESH = "5s";

const timeRangeOptions = [
  { value: "5m", labelKey: "monitoring.ranges.fiveMinutes" },
  { value: "15m", labelKey: "monitoring.ranges.fifteenMinutes" },
  { value: "1h", labelKey: "monitoring.ranges.oneHour" },
  { value: "6h", labelKey: "monitoring.ranges.sixHours" },
  { value: "24h", labelKey: "monitoring.ranges.twentyFourHours" },
  { value: "7d", labelKey: "monitoring.ranges.sevenDays" }
] as const;

const refreshIntervalOptions = [
  { value: "off", labelKey: "monitoring.refreshIntervals.off" },
  { value: "1s", labelKey: "monitoring.refreshIntervals.oneSecond" },
  { value: "5s", labelKey: "monitoring.refreshIntervals.fiveSeconds" },
  { value: "10s", labelKey: "monitoring.refreshIntervals.tenSeconds" },
  { value: "30s", labelKey: "monitoring.refreshIntervals.thirtySeconds" }
] as const;

type ChartDefinition = {
  key: string;
  titleKey: string;
  labelKey: string;
  color: string;
  type?: "area" | "bar";
  scale?: (value: number) => number;
};

const chartDefinitions: ChartDefinition[] = [
  { key: "cpu_usage", titleKey: "monitoring.charts.cpu", labelKey: "monitoring.units.cores", color: "#22d3ee" },
  {
    key: "memory_working_set",
    titleKey: "monitoring.charts.memory",
    labelKey: "monitoring.units.mebibytes",
    color: "#a78bfa",
    scale: (value) => value / 1024 ** 2
  },
  { key: "request_rate", titleKey: "monitoring.charts.requests", labelKey: "monitoring.units.requestsPerSecond", color: "#34d399", type: "bar" },
  { key: "error_rate", titleKey: "monitoring.charts.errors", labelKey: "monitoring.units.errorsPerSecond", color: "#f87171", type: "bar" },
  { key: "pod_restarts", titleKey: "monitoring.charts.restarts", labelKey: "monitoring.units.count", color: "#fbbf24", type: "bar" }
];

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

function formatMetricTime(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function formatClock(timestamp: number) {
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  }).format(new Date(timestamp));
}

function refreshIntervalMs(value: string) {
  if (value === "off") {
    return false;
  }
  return Number(value.replace("s", "")) * 1000;
}

function chartData(series: MetricSeries, scale?: (value: number) => number) {
  return series.points.map((point) => ({
    time: formatMetricTime(point.timestamp),
    value: scale ? scale(point.value) : point.value
  }));
}

function seriesEmptyDescriptionKey(series: MetricSeries | undefined) {
  if (!series) {
    return "monitoring.empty.noData";
  }
  if (series.status === "unavailable") {
    return "monitoring.empty.metricUnavailable";
  }
  if (series.key === "request_rate" || series.key === "error_rate") {
    return "monitoring.empty.requestMetrics";
  }
  return "monitoring.empty.noData";
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

function TimeSeriesCard({
  definition,
  isLoading,
  series
}: {
  definition: ChartDefinition;
  isLoading: boolean;
  series?: MetricSeries;
}) {
  const { t } = useTranslation();
  const data = series ? chartData(series, definition.scale) : [];
  const hasData = data.length > 0;

  if (!hasData) {
    return (
      <Card className={definition.key === "pod_restarts" ? "xl:col-span-2" : undefined}>
        <CardHeader>
          <CardTitle>{t(definition.titleKey)}</CardTitle>
          <CardDescription>{t("monitoring.charts.realTimeSeries")}</CardDescription>
        </CardHeader>
        <CardContent>
          <EmptyState
            description={isLoading ? t("monitoring.empty.loading") : t(seriesEmptyDescriptionKey(series))}
            icon={<Activity className="h-5 w-5" />}
            title={isLoading ? t("common.loading") : t("monitoring.empty.title")}
          />
        </CardContent>
      </Card>
    );
  }

  return (
    <div className={definition.key === "pod_restarts" ? "xl:col-span-2" : undefined}>
      <MetricChart
        color={definition.color}
        data={data}
        dataKey="value"
        description={t("monitoring.charts.realTimeSeries")}
        label={t(definition.labelKey)}
        title={t(definition.titleKey)}
        type={definition.type}
      />
    </div>
  );
}

export function MonitoringPage() {
  const { t } = useTranslation();
  const [range, setRange] = useState(DEFAULT_RANGE);
  const [autoRefresh, setAutoRefresh] = useState(DEFAULT_AUTO_REFRESH);
  const [namespace, setNamespace] = useState(DEFAULT_NAMESPACE);
  const healthQuery = useQuery({ queryKey: ["observability", "health"], queryFn: observabilityApi.health });
  const clusterMetricsQuery = useQuery({ queryKey: ["observability", "metrics", "cluster"], queryFn: observabilityApi.clusterMetrics });
  const namespaceMetricsQuery = useQuery({
    queryKey: ["observability", "metrics", "namespace", namespace],
    queryFn: () => observabilityApi.namespaceMetrics(namespace)
  });
  const timeSeriesQuery = useQuery({
    queryKey: ["observability", "metrics", "timeseries", namespace, range],
    queryFn: () => observabilityApi.metricsTimeseries({ namespace, range })
  });
  const namespacesQuery = useQuery({ queryKey: ["observability", "namespaces"], queryFn: observabilityApi.namespaces });
  const namespaceOptions = namespacesQuery.data?.map((item) => ({ value: item.name, label: item.name })) ?? [{ value: namespace, label: namespace }];
  const firstError = healthQuery.error ?? clusterMetricsQuery.error ?? namespaceMetricsQuery.error ?? timeSeriesQuery.error;
  const isLoading = healthQuery.isLoading || clusterMetricsQuery.isLoading || namespaceMetricsQuery.isLoading || timeSeriesQuery.isLoading;
  const isFetching = healthQuery.isFetching || clusterMetricsQuery.isFetching || namespaceMetricsQuery.isFetching || timeSeriesQuery.isFetching || namespacesQuery.isFetching;
  const unavailable = isLoading ? "..." : t("common.unavailable");
  const clusterMetrics = clusterMetricsQuery.data;
  const namespaceMetrics = namespaceMetricsQuery.data;
  const seriesByKey = new Map((timeSeriesQuery.data?.series ?? []).map((item) => [item.key, item]));
  const prometheusUnavailable = getApiErrorStatus(timeSeriesQuery.error) === 503;
  const autoRefreshDelay = refreshIntervalMs(autoRefresh);
  const autoRefreshLabel = t(refreshIntervalOptions.find((item) => item.value === autoRefresh)?.labelKey ?? "monitoring.refreshIntervals.off");
  const lastRefreshedAt = Math.max(
    healthQuery.dataUpdatedAt,
    clusterMetricsQuery.dataUpdatedAt,
    namespaceMetricsQuery.dataUpdatedAt,
    timeSeriesQuery.dataUpdatedAt
  );
  const rangeOptions = useMemo(
    () => timeRangeOptions.map((item) => ({ value: item.value, label: t(item.labelKey) })),
    [t]
  );
  const autoRefreshOptions = useMemo(
    () => refreshIntervalOptions.map((item) => ({ value: item.value, label: t(item.labelKey) })),
    [t]
  );

  const refresh = useCallback(() => {
    if (isFetching) {
      return;
    }
    void healthQuery.refetch();
    void clusterMetricsQuery.refetch();
    void namespaceMetricsQuery.refetch();
    void timeSeriesQuery.refetch();
    void namespacesQuery.refetch();
  }, [clusterMetricsQuery, healthQuery, isFetching, namespaceMetricsQuery, namespacesQuery, timeSeriesQuery]);

  useEffect(() => {
    if (!autoRefreshDelay) {
      return undefined;
    }

    const intervalId = window.setInterval(() => {
      refresh();
    }, autoRefreshDelay);

    return () => window.clearInterval(intervalId);
  }, [autoRefreshDelay, refresh]);

  return (
    <div>
      <PageHeader
        actions={
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-[190px_160px_170px_auto]">
            <Select
              aria-label={t("monitoring.timeRange")}
              options={rangeOptions}
              value={range}
              onChange={(event) => setRange(event.target.value)}
            />
            <Select
              aria-label={t("monitoring.autoRefresh")}
              options={autoRefreshOptions}
              value={autoRefresh}
              onChange={(event) => setAutoRefresh(event.target.value)}
            />
            <Select
              aria-label={t("common.namespace")}
              options={namespaceOptions.some((item) => item.value === namespace) ? namespaceOptions : [{ value: namespace, label: namespace }, ...namespaceOptions]}
              value={namespace}
              onChange={(event) => setNamespace(event.target.value)}
            />
            <Button disabled={isFetching} variant="outline" onClick={refresh}>
              <RefreshCw className={isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
              {t("common.refresh")}
            </Button>
          </div>
        }
        description={t("monitoring.description")}
        title={t("monitoring.title")}
      />

      <div className="mb-6 flex flex-wrap items-center gap-3 text-xs text-slate-400">
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1">
          {t("monitoring.autoRefreshStatus", { interval: autoRefreshLabel })}
        </span>
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1">
          {lastRefreshedAt > 0
            ? t("monitoring.lastRefreshed", { time: formatClock(lastRefreshedAt) })
            : t("monitoring.notRefreshedYet")}
        </span>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <HealthCard health={healthQuery.data?.kubernetes} isLoading={healthQuery.isLoading} label={t("observability.kubernetes")} />
        <HealthCard health={healthQuery.data?.prometheus} isLoading={healthQuery.isLoading} label={t("observability.prometheus")} />
        <HealthCard health={healthQuery.data?.loki} isLoading={healthQuery.isLoading} label={t("observability.loki")} />
      </div>

      {firstError ? (
        <EmptyState className="mt-6" description={t(getErrorKey(getApiErrorStatus(firstError)))} title={t("monitoring.unavailableTitle")} />
      ) : null}

      {prometheusUnavailable ? (
        <div className="mt-6 rounded-2xl border border-amber-300/15 bg-amber-300/[0.06] p-4 text-sm leading-6 text-amber-100">
          {t("monitoring.prometheusUnavailable")}
        </div>
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
          <h2 className="text-base font-semibold text-white">{t("monitoring.timeseriesTitle")}</h2>
          <p className="mt-1 text-sm leading-6 text-slate-400">{t("monitoring.timeseriesDescription", { namespace })}</p>
        </div>
        <div className="grid gap-6 xl:grid-cols-2">
          {chartDefinitions.map((definition) => (
            <TimeSeriesCard
              key={definition.key}
              definition={definition}
              isLoading={timeSeriesQuery.isLoading}
              series={seriesByKey.get(definition.key)}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
