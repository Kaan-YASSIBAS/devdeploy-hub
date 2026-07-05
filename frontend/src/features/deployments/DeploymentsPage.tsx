import { useEffect, useMemo, useState } from "react";
import { Archive, Database, Plus, RefreshCw, Rocket, RotateCcw, Search, Trash2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  deployGitOpsApp,
  deploymentRecordsApi,
  getApiErrorStatus,
  getGitOpsAppStatus,
  serviceDefinitionsApi
} from "@/api/client";
import { CreateGitOpsAppModal } from "@/components/deployments/CreateGitOpsAppModal";
import { GitOpsDeployStatusCard } from "@/components/deployments/GitOpsDeployStatusCard";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Tabs } from "@/components/ui/tabs";
import type {
  ArchiveFilter,
  DeploymentRecord,
  DeploymentRuntimeStatus,
  GitOpsAppDeployInput,
  GitOpsAppDeployResponse,
  GitOpsAppDeployStatus,
  UntrackedDeploymentRuntime
} from "@/types";

const STATUS_POLL_INTERVAL_MS = 3_000;
const STATUS_POLL_TIMEOUT_MS = 120_000;

function isTerminalGitOpsStatus(status: GitOpsAppDeployStatus | undefined) {
  return status === "deployed" || status === "degraded";
}

function deployErrorKey(status: number | undefined) {
  if (status === 400) return "deployments.gitopsDeploy.errors.validation";
  if (status === 401 || status === 403) return "deployments.gitopsDeploy.errors.authorization";
  if (status === 409) return "deployments.gitopsDeploy.errors.conflict";
  return "deployments.gitopsDeploy.errors.deployFailed";
}

function statusErrorKey(status: number | undefined) {
  if (status === 401 || status === 403) return "deployments.gitopsDeploy.errors.statusPermission";
  if (status === 503) return "deployments.gitopsDeploy.errors.statusUnavailable";
  return "deployments.gitopsDeploy.errors.statusFailed";
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function runtimeVariant(status: DeploymentRuntimeStatus["display_status"]) {
  if (status === "running") return "success";
  if (status === "progressing") return "warning";
  if (status === "not_found") return "danger";
  return "muted";
}

function driftVariant(status: NonNullable<DeploymentRecord["drift_status"]>["status"]) {
  if (status === "aligned") return "success";
  if (status === "drifted") return "warning";
  if (status === "gitops_missing" || status === "runtime_missing") return "danger";
  return "muted";
}

function hasPublishedGitOpsSummary(summary: string | null) {
  return summary?.toLowerCase().includes("gitops manifests published") ?? false;
}

function canRecover(record: DeploymentRecord) {
  const runtime = record.runtime_status;
  if (record.archived_at || !runtime) return false;
  return (
    runtime.display_status === "not_found" ||
    (runtime.display_status === "unknown" &&
      runtime.message === "Runtime status is temporarily unavailable.")
  );
}

export function DeploymentsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [search, setSearch] = useState("");
  const [archiveFilter, setArchiveFilter] = useState<ArchiveFilter>("active");
  const [gitOpsModalOpen, setGitOpsModalOpen] = useState(false);
  const [deployResponse, setDeployResponse] = useState<GitOpsAppDeployResponse | null>(null);
  const [pollTimedOut, setPollTimedOut] = useState(false);
  const recordsQuery = useQuery({
    queryKey: ["deployment-records", archiveFilter],
    queryFn: () => deploymentRecordsApi.list({ archiveFilter })
  });
  const showUntracked = archiveFilter !== "archived";
  const untrackedQuery = useQuery({
    queryKey: ["untracked-deployments"],
    queryFn: deploymentRecordsApi.listUntracked,
    enabled: showUntracked
  });
  const servicesQuery = useQuery({
    queryKey: ["service-definitions", "all"],
    queryFn: () => serviceDefinitionsApi.list({ archiveFilter: "all" })
  });
  const records = useMemo(() => recordsQuery.data ?? [], [recordsQuery.data]);
  const untrackedDeployments = useMemo(
    () => (showUntracked ? untrackedQuery.data?.items ?? [] : []),
    [showUntracked, untrackedQuery.data]
  );
  const services = useMemo(() => servicesQuery.data ?? [], [servicesQuery.data]);
  const servicesById = useMemo(
    () => new Map(services.map((service) => [service.id, service])),
    [services]
  );

  const archiveMutation = useMutation({
    mutationFn: (id: number) => deploymentRecordsApi.archive(id),
    onSuccess: async () => {
      toast.success(t("deployments.records.archive.success"));
      await queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: () => toast.error(t("deployments.records.archive.error"))
  });

  const archiveRecord = (record: DeploymentRecord) => {
    if (window.confirm(t("deployments.records.archive.confirm"))) {
      archiveMutation.mutate(record.id);
    }
  };

  const deleteMutation = useMutation({
    mutationFn: (id: number) => deploymentRecordsApi.remove(id),
    onSuccess: async () => {
      toast.success(t("deployments.records.delete.success"));
      await queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: () => toast.error(t("deployments.records.delete.error"))
  });

  const deleteRecord = (record: DeploymentRecord) => {
    if (window.confirm(t("deployments.records.delete.confirm"))) {
      deleteMutation.mutate(record.id);
    }
  };

  const recoverMutation = useMutation({
    mutationFn: (id: number) => deploymentRecordsApi.recover(id),
    onSuccess: async () => {
      toast.success(t("deployments.records.recover.success"));
      await queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
      await queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-services"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: () => toast.error(t("deployments.records.recover.error"))
  });

  const recoverRecord = (record: DeploymentRecord) => {
    if (window.confirm(t("deployments.records.recover.confirm"))) {
      recoverMutation.mutate(record.id);
    }
  };

  const gitOpsMutation = useMutation({
    mutationFn: (input: GitOpsAppDeployInput) => deployGitOpsApp(input),
    onSuccess: async (response) => {
      setDeployResponse(response);
      setPollTimedOut(false);
      toast.success(t("deployments.gitopsDeploy.pushedToast"));
      await queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
      await queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-services"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: (error) => {
      toast.error(t(deployErrorKey(getApiErrorStatus(error))));
    }
  });

  const liveStatusQuery = useQuery({
    queryKey: ["gitops-app-status", deployResponse?.app_name, deployResponse?.commit_sha],
    queryFn: () => getGitOpsAppStatus(deployResponse!.app_name, deployResponse!.commit_sha!),
    enabled: Boolean(deployResponse?.commit_sha) && !pollTimedOut,
    retry: false,
    refetchInterval: (query) => {
      if (query.state.status === "error" || isTerminalGitOpsStatus(query.state.data?.status)) {
        return false;
      }
      return STATUS_POLL_INTERVAL_MS;
    },
    refetchIntervalInBackground: false
  });

  const liveStatus = liveStatusQuery.data?.status;
  const liveStatusIsTerminal = isTerminalGitOpsStatus(liveStatus);

  useEffect(() => {
    if (!deployResponse?.commit_sha || liveStatusIsTerminal) {
      return;
    }

    const timeout = window.setTimeout(() => setPollTimedOut(true), STATUS_POLL_TIMEOUT_MS);
    return () => window.clearTimeout(timeout);
  }, [deployResponse?.commit_sha, liveStatusIsTerminal]);

  useEffect(() => {
    if (liveStatus !== "deployed") {
      return;
    }

    void queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
    void queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    void queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
    void queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
    void queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
    void queryClient.invalidateQueries({ queryKey: ["untracked-services"] });
  }, [liveStatus, queryClient]);

  const filteredRecords = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) {
      return records;
    }

    return records.filter((record) => {
      const serviceName = record.service_definition_id
        ? servicesById.get(record.service_definition_id)?.name ?? ""
        : "";
      return [
        record.app_name,
        record.image,
        record.namespace,
        record.desired_state,
        record.runtime_status?.display_status ?? "",
        record.drift_status?.status ?? "",
        ...(record.drift_status?.db_to_gitops.differences.map((difference) => difference.field) ?? []),
        ...(record.drift_status?.db_to_runtime.differences.map((difference) => difference.field) ?? []),
        record.status_summary ?? "",
        record.commit_sha ?? "",
        serviceName
      ]
        .join(" ")
        .toLowerCase()
        .includes(query);
    });
  }, [records, search, servicesById]);

  const filteredUntracked = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return untrackedDeployments;
    return untrackedDeployments.filter((deployment) =>
      [deployment.name, deployment.namespace, deployment.display_status]
        .join(" ")
        .toLowerCase()
        .includes(query)
    );
  }, [search, untrackedDeployments]);

  const columns: Column<DeploymentRecord>[] = [
    {
      key: "deployment",
      header: t("deployments.records.fields.appName"),
      render: (record) => (
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <p className="font-medium text-white">{record.app_name}</p>
            {record.archived_at ? (
              <Badge variant="muted">{t("archiveFilter.archivedBadge")}</Badge>
            ) : null}
          </div>
          <p className="text-xs text-slate-500">{record.namespace}</p>
        </div>
      )
    },
    {
      key: "service",
      header: t("deployments.records.fields.service"),
      render: (record) =>
        record.service_definition_id
          ? servicesById.get(record.service_definition_id)?.name ?? `#${record.service_definition_id}`
          : t("deployments.records.noService")
    },
    {
      key: "image",
      header: t("deployments.records.fields.image"),
      render: (record) => <span className="break-all font-mono text-xs text-cyan-100">{record.image}</span>
    },
    {
      key: "state",
      header: t("deployments.records.fields.status"),
      render: (record) => {
        const runtime = record.runtime_status;
        const published = hasPublishedGitOpsSummary(record.status_summary);
        const publishedLifecycle =
          published || (runtime?.display_status === "running" && record.desired_state === "pending");
        const lifecycleLabel =
          publishedLifecycle
            ? t("deployments.records.gitopsPublished")
            : record.desired_state === "draft"
              ? t("deployments.records.status.draft")
              : t("deployments.records.gitopsStateLabel", {
                  state: t(`deployments.records.status.${record.desired_state}`)
                });
        return (
          <div className="space-y-1.5">
            <Badge variant={runtime ? runtimeVariant(runtime.display_status) : "muted"}>
              {runtime
                ? t(`runtimeStatus.${runtime.display_status}`)
                : t(`deployments.records.status.${record.desired_state}`)}
            </Badge>
            <p className="text-xs text-slate-500">{lifecycleLabel}</p>
            {record.status_summary && !publishedLifecycle ? (
              <p className="max-w-[220px] text-xs text-slate-500">{record.status_summary}</p>
            ) : null}
          </div>
        );
      }
    },
    {
      key: "runtime",
      header: t("deployments.records.fields.runtimeDefaults"),
      render: (record) => {
        const runtime = record.runtime_status;
        if (!runtime?.deployment_found) {
          return (
            <span className="whitespace-nowrap font-mono text-xs">
              {record.replicas} x :{record.container_port} / {record.service_port}
            </span>
          );
        }
        return (
          <div className="space-y-1 font-mono text-xs">
            <p>
              {t("deployments.records.runtimeReplicas", {
                ready: runtime.ready_replicas ?? 0,
                desired: runtime.desired_replicas ?? record.replicas
              })}
            </p>
            <p className="text-slate-500">
              {t("deployments.records.runtimePods", {
                ready: runtime.pod_ready_count ?? 0,
                total: runtime.pod_total_count ?? 0
              })}
            </p>
          </div>
        );
      }
    },
    {
      key: "drift",
      header: t("deployments.records.fields.reconcileStatus"),
      render: (record) => {
        const drift = record.drift_status;
        if (!drift) {
          return <Badge variant="muted">{t("deployments.records.drift.status.unknown")}</Badge>;
        }
        const differences = [
          ...drift.db_to_gitops.differences,
          ...drift.db_to_runtime.differences
        ].slice(0, 2);
        return (
          <div className="max-w-[240px] space-y-1.5">
            <Badge variant={driftVariant(drift.status)}>
              {t(`deployments.records.drift.status.${drift.status}`)}
            </Badge>
            {drift.status === "drifted"
              ? differences.map((difference) => (
                  <p
                    className="break-words text-xs text-slate-500"
                    key={`${difference.source}-${difference.field}`}
                  >
                    {t("deployments.records.drift.difference", {
                      field: difference.field,
                      expected: difference.expected ?? "-",
                      actual: difference.actual ?? "-"
                    })}
                  </p>
                ))
              : null}
          </div>
        );
      }
    },
    {
      key: "gitops",
      header: t("deployments.records.fields.gitops"),
      render: (record) =>
        record.commit_sha || record.gitops_manifest_path ? (
          <div className="space-y-1 font-mono text-xs">
            <p>{record.commit_sha?.slice(0, 8) ?? "-"}</p>
            <p className="max-w-[220px] truncate text-slate-500">{record.gitops_manifest_path ?? "-"}</p>
          </div>
        ) : (
          <span className="text-slate-500">{t("deployments.records.notPublished")}</span>
        )
    },
    {
      key: "updated",
      header: t("deployments.records.fields.updated"),
      render: (record) => (
        <p>{formatDate(record.updated_at)}</p>
      )
    },
    {
      key: "actions",
      header: t("common.actions"),
      render: (record) => {
        if (record.archived_at) {
          return (
            <Button
              aria-label={t("deployments.records.delete.action")}
              disabled={deleteMutation.isPending && deleteMutation.variables === record.id}
              size="sm"
              variant="danger"
              onClick={() => deleteRecord(record)}
            >
              <Trash2 className="h-4 w-4" />
              {t("deployments.records.delete.action")}
            </Button>
          );
        }
        if (!canRecover(record)) return null;
        return (
          <div className="flex flex-wrap gap-2">
            <Button
              aria-label={t("deployments.records.recover.action")}
              disabled={recoverMutation.isPending && recoverMutation.variables === record.id}
              size="sm"
              variant="outline"
              onClick={() => recoverRecord(record)}
            >
              <RotateCcw className="h-4 w-4" />
              {t("deployments.records.recover.action")}
            </Button>
            {record.runtime_status?.display_status === "not_found" ? (
              <Button
                aria-label={t("deployments.records.archive.action")}
                disabled={archiveMutation.isPending && archiveMutation.variables === record.id}
                size="sm"
                variant="ghost"
                onClick={() => archiveRecord(record)}
              >
                <Archive className="h-4 w-4" />
                {t("deployments.records.archive.action")}
              </Button>
            ) : null}
          </div>
        );
      }
    }
  ];

  const untrackedColumns: Column<UntrackedDeploymentRuntime>[] = [
    {
      key: "deployment",
      header: t("deployments.records.fields.appName"),
      render: (deployment) => (
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <p className="font-medium text-white">{deployment.name}</p>
            <Badge variant="warning">{t("untracked.badge")}</Badge>
          </div>
          <p className="text-xs text-slate-500">{deployment.namespace}</p>
        </div>
      )
    },
    {
      key: "status",
      header: t("deployments.records.fields.status"),
      render: (deployment) => (
        <Badge variant={runtimeVariant(deployment.display_status)}>
          {t(`runtimeStatus.${deployment.display_status}`)}
        </Badge>
      )
    },
    {
      key: "replicas",
      header: t("deployments.records.fields.runtimeDefaults"),
      render: (deployment) => (
        <div className="space-y-1 font-mono text-xs">
          <p>
            {t("deployments.records.runtimeReplicas", {
              ready: deployment.ready_replicas ?? 0,
              desired: deployment.desired_replicas ?? 0
            })}
          </p>
          <p className="text-slate-500">
            {t("deployments.records.runtimePods", {
              ready: deployment.pod_ready_count ?? 0,
              total: deployment.pod_total_count ?? 0
            })}
          </p>
        </div>
      )
    },
    {
      key: "service",
      header: t("untracked.relatedService"),
      render: (deployment) => (
        <div className="space-y-1 text-xs">
          <p>{deployment.service_found ? t("runtimeStatus.ready") : t("runtimeStatus.not_found")}</p>
          <p className="font-mono text-slate-500">
            {deployment.service_ports?.map((port) => `${port.port}/${port.protocol ?? "TCP"}`).join(", ") ?? "-"}
          </p>
        </div>
      )
    },
    {
      key: "observed",
      header: t("untracked.observed"),
      render: (deployment) => formatDate(deployment.observed_at)
    }
  ];

  const emptyTitle = recordsQuery.isLoading
    ? t("common.loading")
    : records.length
      ? t("deployments.records.emptyNoResultsTitle")
      : archiveFilter === "archived"
        ? t("archiveFilter.emptyTitle")
        : t("deployments.records.emptyTitle");
  const emptyDescription = recordsQuery.isError
    ? t("deployments.records.loadError")
    : records.length
      ? t("deployments.records.emptyNoResultsDescription")
      : archiveFilter === "archived"
        ? t("archiveFilter.emptyDescription")
        : t("deployments.records.emptyDescription");
  const showManaged =
    filteredRecords.length > 0 ||
    filteredUntracked.length === 0 ||
    recordsQuery.isLoading ||
    recordsQuery.isError;
  const untrackedUnavailable =
    showUntracked && (untrackedQuery.isError || untrackedQuery.data?.runtime_available === false);
  const isRefreshing = recordsQuery.isFetching || (showUntracked && untrackedQuery.isFetching);

  const refreshLists = () => {
    if (showUntracked) {
      void Promise.all([recordsQuery.refetch(), untrackedQuery.refetch()]);
      return;
    }
    void recordsQuery.refetch();
  };

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-wrap gap-3">
            <Button
              disabled={isRefreshing}
              variant="outline"
              onClick={refreshLists}
            >
              <RefreshCw className={isRefreshing ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
              {t("common.refresh")}
            </Button>
            <Button onClick={() => setGitOpsModalOpen(true)}>
              <Plus className="h-4 w-4" />
              {t("deployments.createDeployment")}
            </Button>
          </div>
        }
        description={t("deployments.records.description")}
        title={t("deployments.title")}
      />

      <div className="mb-5 flex items-start gap-3 rounded-lg border border-cyan-300/15 bg-cyan-400/[0.06] px-4 py-3 text-sm text-slate-300">
        <Database className="mt-0.5 h-4 w-4 shrink-0 text-cyan-200" />
        <p>{t("deployments.records.pageNotice")}</p>
      </div>

      {deployResponse ? (
        <GitOpsDeployStatusCard
          deployResponse={deployResponse}
          errorKey={
            !deployResponse.commit_sha
              ? "deployments.gitopsDeploy.errors.missingCommit"
              : liveStatusQuery.isError
                ? statusErrorKey(getApiErrorStatus(liveStatusQuery.error))
                : undefined
          }
          isFetching={liveStatusQuery.isFetching}
          statusResponse={liveStatusQuery.data}
          timedOut={pollTimedOut}
          onRefresh={() => {
            setPollTimedOut(false);
            void liveStatusQuery.refetch();
          }}
        />
      ) : null}

      <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
        <Tabs
          tabs={[
            { value: "active", label: t("archiveFilter.active") },
            { value: "archived", label: t("archiveFilter.archived") },
            { value: "all", label: t("archiveFilter.all") }
          ]}
          value={archiveFilter}
          onValueChange={(value) => setArchiveFilter(value as ArchiveFilter)}
        />
        {archiveFilter !== "active" ? (
          <div className="max-w-xl text-xs text-slate-500">
            <p>{t("archiveFilter.description")}</p>
            <p>{t("archiveFilter.restoreLater")}</p>
          </div>
        ) : null}
      </div>

      <div className="relative mb-5">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
        <Input
          className="pl-10"
          placeholder={t("deployments.records.searchPlaceholder")}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
      </div>

      <div className="space-y-5">
        {showManaged ? (
          <Card>
            <CardContent className="space-y-4 pt-5">
              {filteredRecords.length ? (
                <div>
                  <h2 className="text-sm font-semibold text-white">{t("untracked.managedDeployments")}</h2>
                  <p className="mt-1 text-xs text-slate-500">{t("untracked.managedDescription")}</p>
                </div>
              ) : null}
              <DataTable
                columns={columns}
                data={filteredRecords}
                emptyState={
                  <EmptyState
                    description={emptyDescription}
                    icon={<Rocket className="h-5 w-5" />}
                    title={emptyTitle}
                  />
                }
                getRowKey={(record) => String(record.id)}
              />
            </CardContent>
          </Card>
        ) : null}

        {showUntracked && filteredUntracked.length ? (
          <Card className="border-amber-300/20">
            <CardContent className="space-y-4 pt-5">
              <div>
                <h2 className="text-sm font-semibold text-amber-100">{t("untracked.deploymentsTitle")}</h2>
                <p className="mt-1 text-xs text-slate-400">{t("untracked.description")}</p>
                <p className="mt-1 text-xs text-slate-500">{t("untracked.importLater")}</p>
              </div>
              <DataTable
                columns={untrackedColumns}
                data={filteredUntracked}
                getRowKey={(deployment) => `${deployment.namespace}/${deployment.name}`}
              />
            </CardContent>
          </Card>
        ) : null}

        {untrackedUnavailable ? (
          <p className="rounded-lg border border-amber-300/20 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">
            {t("untracked.unavailable")}
          </p>
        ) : null}
      </div>

      <CreateGitOpsAppModal
        isSubmitting={gitOpsMutation.isPending}
        open={gitOpsModalOpen}
        onDeploy={(input) => gitOpsMutation.mutateAsync(input)}
        onOpenChange={setGitOpsModalOpen}
      />
    </div>
  );
}
