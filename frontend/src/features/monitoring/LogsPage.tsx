import { useEffect, useMemo, useRef, useState } from "react";
import { Clipboard, RefreshCw, Search } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { getApiErrorStatus, observabilityApi } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmptyState } from "@/components/shared/EmptyState";
import type { LogEntry } from "@/types";

const limits = [50, 100, 200, 500];

function formatLogTimestamp(value: string) {
  const numeric = Number(value);

  if (Number.isFinite(numeric)) {
    const milliseconds = numeric > 10_000_000_000_000 ? numeric / 1_000_000 : numeric;
    return new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit"
    }).format(new Date(milliseconds));
  }

  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleString();
}

function getPodLabel(entry: LogEntry) {
  return entry.labels.pod ?? entry.labels.pod_name ?? "-";
}

function getContainerLabel(entry: LogEntry) {
  return entry.labels.container ?? entry.labels.container_name ?? "-";
}

function getErrorKey(status?: number) {
  if (status === 403) {
    return "api.errors.observabilityPermissionDenied";
  }

  if (status === 503) {
    return "api.errors.observabilityUnavailable";
  }

  return "api.errors.logsLoadFailed";
}

export function LogsPage() {
  const { t } = useTranslation();
  const [namespace, setNamespace] = useState("");
  const [pod, setPod] = useState("all");
  const [limit, setLimit] = useState(100);
  const [query, setQuery] = useState("");
  const [autoScroll, setAutoScroll] = useState(true);
  const containerRef = useRef<HTMLDivElement>(null);

  const healthQuery = useQuery({ queryKey: ["observability", "health"], queryFn: observabilityApi.health });
  const lokiHealth = healthQuery.data?.loki;
  const lokiReady = Boolean(lokiHealth?.available);
  const lokiUnavailable = Boolean(lokiHealth && !lokiHealth.available) || healthQuery.isError;
  const namespacesQuery = useQuery({ queryKey: ["observability", "namespaces"], queryFn: observabilityApi.namespaces });
  const podsQuery = useQuery({ queryKey: ["observability", "pods", namespace], queryFn: () => observabilityApi.pods(namespace), enabled: Boolean(namespace) });
  const logsQuery = useQuery({
    queryKey: ["observability", "logs", namespace, pod, limit],
    queryFn: () => observabilityApi.logs({ namespace, pod: pod === "all" ? undefined : pod, limit }),
    enabled: lokiReady && Boolean(namespace)
  });

  const namespaces = useMemo(() => namespacesQuery.data ?? [], [namespacesQuery.data]);
  const namespaceOptions = namespaces.map((item) => ({ value: item.name, label: item.name }));
  const podOptions = useMemo(
    () => [
      { value: "all", label: t("common.all") },
      ...(podsQuery.data ?? []).map((item) => ({ value: item.name, label: item.name }))
    ],
    [podsQuery.data, t]
  );
  const logRows = useMemo(() => logsQuery.data ?? [], [logsQuery.data]);
  const filteredLogs = useMemo(() => {
    const normalizedQuery = query.toLowerCase();
    if (!normalizedQuery) {
      return logRows;
    }

    return logRows.filter((entry) => {
      const labels = Object.values(entry.labels).join(" ").toLowerCase();
      return entry.line.toLowerCase().includes(normalizedQuery) || labels.includes(normalizedQuery);
    });
  }, [logRows, query]);

  useEffect(() => {
    if (!namespace && namespaces.length) {
      setNamespace(namespaces[0].name);
    }
  }, [namespace, namespaces]);

  useEffect(() => {
    if (autoScroll && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
    }
  }, [autoScroll, filteredLogs.length]);

  const handleCopy = () => {
    const content = filteredLogs
      .map((entry) => `${formatLogTimestamp(entry.timestamp)} ${getPodLabel(entry)} ${getContainerLabel(entry)} ${entry.line}`)
      .join("\n");
    void navigator.clipboard.writeText(content);
    toast.success(t("logs.copied"));
  };

  const refresh = () => {
    void healthQuery.refetch();
    void namespacesQuery.refetch();
    void podsQuery.refetch();
    if (lokiReady) {
      void logsQuery.refetch();
    }
  };

  const errorDescription = lokiUnavailable
    ? healthQuery.isError
      ? t(getErrorKey(getApiErrorStatus(healthQuery.error)))
      : t(`observability.messages.${lokiHealth?.message_code ?? "loki.unavailable"}`)
      : logsQuery.error || podsQuery.error
      ? t(getErrorKey(getApiErrorStatus(logsQuery.error ?? podsQuery.error)))
      : t("logs.emptyDescription");

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-wrap gap-3">
            <Button variant="outline" onClick={refresh}>
              <RefreshCw className="h-4 w-4" />
              {t("common.refresh")}
            </Button>
            <Button variant="outline" onClick={handleCopy}>
              <Clipboard className="h-4 w-4" />
              {t("logs.copyLogs")}
            </Button>
          </div>
        }
        description={t("logs.description")}
        title={t("logs.title")}
      />

      <Card className="mb-6">
        <CardContent className="grid gap-3 pt-5 lg:grid-cols-[170px_1fr_130px_1.2fr_auto]">
          <Select
            aria-label={t("common.namespace")}
            options={namespaceOptions}
            value={namespace}
            onChange={(event) => {
              setNamespace(event.target.value);
              setPod("all");
            }}
          />
          <Select aria-label={t("logs.filters.pod")} options={podOptions} value={pod} onChange={(event) => setPod(event.target.value)} />
          <Select
            aria-label={t("logs.filters.limit")}
            options={limits.map((item) => ({ value: String(item), label: String(item) }))}
            value={String(limit)}
            onChange={(event) => setLimit(Number(event.target.value))}
          />
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
            <Input className="pl-10" placeholder={t("logs.filters.search")} value={query} onChange={(event) => setQuery(event.target.value)} />
          </div>
          <label className="flex h-11 items-center gap-2 rounded-xl border border-white/10 bg-white/[0.045] px-3 text-sm text-slate-300">
            <input checked={autoScroll} className="accent-cyan-300" type="checkbox" onChange={(event) => setAutoScroll(event.target.checked)} />
            {t("logs.autoScroll")}
          </label>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("logs.terminalTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          {healthQuery.isLoading || lokiUnavailable || logsQuery.isLoading || logsQuery.isError || !filteredLogs.length ? (
            <EmptyState
              description={healthQuery.isLoading || logsQuery.isLoading ? t("logs.loadingDescription") : errorDescription}
              title={
                healthQuery.isLoading || logsQuery.isLoading
                  ? t("common.loading")
                  : lokiUnavailable || logsQuery.isError
                    ? t("logs.unavailableTitle")
                    : t("logs.emptyTitle")
              }
            />
          ) : (
            <div ref={containerRef} className="scrollbar-soft max-h-[620px] overflow-auto rounded-2xl border border-white/10 bg-slate-950/80 font-mono text-xs shadow-inner">
              <div className="min-w-[920px] divide-y divide-white/[0.06]">
                {filteredLogs.map((entry, index) => (
                  <div key={`${entry.timestamp}-${index}`} className="grid grid-cols-[180px_220px_160px_1fr] gap-3 px-4 py-3 text-slate-300">
                    <span className="text-slate-500">{formatLogTimestamp(entry.timestamp)}</span>
                    <span className="truncate text-cyan-200">{getPodLabel(entry)}</span>
                    <span className="truncate text-violet-200">{getContainerLabel(entry)}</span>
                    <span className="whitespace-pre-wrap break-words">{entry.line}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
