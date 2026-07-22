import { useEffect, useMemo, useRef, useState } from "react";
import { Archive, Database, ExternalLink, Plus, RefreshCw, Rocket, RotateCcw, Search, Trash2 } from "lucide-react";
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
import { GitOpsOperationTimeline } from "@/components/deployments/GitOpsOperationTimeline";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs } from "@/components/ui/tabs";
import type {
  ArchiveFilter,
  DeploymentAccess,
  DeploymentAccessStatus,
  DeploymentRecord,
  DeploymentRuntimeStatus,
  GitOpsAppDeployInput,
  GitOpsAppDeployResponse,
  GitOpsAppDeployStatus,
  UntrackedDeploymentRuntime
} from "@/types";

const STATUS_POLL_INTERVAL_MS = 3_000;
const STATUS_POLL_TIMEOUT_MS = 120_000;
const DELETE_CLEANUP_TIMEOUT_MS = 120_000;
const DELETE_COMPLETED_DISMISS_MS = 2_500;

type DestroyProgressPhase = "requesting" | "cleanup_pending" | "completed" | "timed_out";

type DestroyProgressState = {
  record: DeploymentRecord;
  phase: DestroyProgressPhase;
  startedAt: number;
};

function runtimeIdentity(namespace: string, name: string) {
  return `${namespace}/${name}`.toLowerCase();
}

function deleteProgressStep(phase: DestroyProgressPhase): number {
  if (phase === "requesting") return 0;
  if (phase === "completed") return 4;
  return 3;
}

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

function reconcileVariant(status: NonNullable<DeploymentRecord["reconcile_status"]>["status"]) {
  if (status === "synced") return "success";
  if (status === "progressing" || status === "drifted") return "warning";
  if (status === "degraded") return "danger";
  return "muted";
}

function accessVariant(status: DeploymentAccessStatus) {
  if (status === "available") return "success";
  if (status === "not_ready" || status === "runtime_unavailable") return "warning";
  if (status === "service_missing") return "danger";
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

function canReconcile(record: DeploymentRecord) {
  const runtime = record.runtime_status;
  const drift = record.drift_status;
  if (record.archived_at || !runtime || !drift) return false;
  if (runtime.display_status !== "running" && runtime.display_status !== "progressing") {
    return false;
  }
  return drift.status === "drifted" || drift.status === "gitops_missing";
}

function canDestroy(record: DeploymentRecord) {
  if (record.archived_at || record.desired_state === "destroyed") return false;
  return Boolean(record.gitops_manifest_path || record.commit_sha || hasPublishedGitOpsSummary(record.status_summary));
}

function canRecoverDestroyed(record: DeploymentRecord) {
  return Boolean(
    record.archived_at &&
      record.desired_state === "destroyed" &&
      record.service_definition_id
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
  const [accessByDeployment, setAccessByDeployment] = useState<Record<number, DeploymentAccess>>({});
  const [openingPreviewId, setOpeningPreviewId] = useState<number | null>(null);
  const [destroyTarget, setDestroyTarget] = useState<DeploymentRecord | null>(null);
  const [destroyConfirmName, setDestroyConfirmName] = useState("");
  const [destroyInProgress, setDestroyInProgress] = useState<DestroyProgressState | null>(null);
  const [recoverDestroyedTarget, setRecoverDestroyedTarget] = useState<DeploymentRecord | null>(null);
  const [recoverInProgress, setRecoverInProgress] = useState<DeploymentRecord | null>(null);
  const destroyToastId = useRef<ReturnType<typeof toast.loading> | undefined>(undefined);
  const recoverToastId = useRef<ReturnType<typeof toast.loading> | undefined>(undefined);
  const deleteCleanupPolling =
    destroyInProgress?.phase === "cleanup_pending" || destroyInProgress?.phase === "timed_out";
  const recordsQuery = useQuery({
    queryKey: ["deployment-records", archiveFilter],
    queryFn: () => deploymentRecordsApi.list({ archiveFilter }),
    refetchInterval: deleteCleanupPolling ? STATUS_POLL_INTERVAL_MS : false
  });
  const showUntracked = archiveFilter !== "archived";
  const untrackedQuery = useQuery({
    queryKey: ["untracked-deployments"],
    queryFn: deploymentRecordsApi.listUntracked,
    enabled: showUntracked || Boolean(destroyInProgress),
    refetchInterval: deleteCleanupPolling ? STATUS_POLL_INTERVAL_MS : false
  });
  const servicesQuery = useQuery({
    queryKey: ["service-definitions", "all"],
    queryFn: () => serviceDefinitionsApi.list({ archiveFilter: "all" }),
    refetchInterval: deleteCleanupPolling ? STATUS_POLL_INTERVAL_MS : false
  });
  const records = useMemo(() => recordsQuery.data ?? [], [recordsQuery.data]);
  const untrackedDeployments = useMemo(
    () => ((showUntracked || destroyInProgress) ? untrackedQuery.data?.items ?? [] : []),
    [destroyInProgress, showUntracked, untrackedQuery.data]
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
    mutationFn: (record: DeploymentRecord) => deploymentRecordsApi.recover(record.id),
    onMutate: (record) => {
      if (record.archived_at && record.desired_state === "destroyed") {
        setRecoverInProgress(record);
        setRecoverDestroyedTarget(null);
        recoverToastId.current = toast.loading(t("deployments.records.recover.destroyedProgress"));
      }
    },
    onSuccess: async (response, record) => {
      const isDestroyedRecovery = Boolean(record.archived_at && record.desired_state === "destroyed");
      if (isDestroyedRecovery) {
        if (response.status === "recovered") {
          toast.success(t("deployments.records.recover.destroyedSuccess"), { id: recoverToastId.current });
        } else if (response.status === "runtime_pending") {
          toast.warning(t("deployments.records.recover.destroyedPending"), { id: recoverToastId.current });
        } else {
          toast.error(t("deployments.records.recover.destroyedError"), { id: recoverToastId.current });
        }
        setRecoverInProgress(null);
        recoverToastId.current = undefined;
      } else {
        toast.success(t("deployments.records.recover.success"));
      }
      await queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
      await queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-services"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: (_error, record) => {
      if (record.archived_at && record.desired_state === "destroyed") {
        toast.error(t("deployments.records.recover.destroyedError"), { id: recoverToastId.current });
        setRecoverInProgress(null);
        recoverToastId.current = undefined;
      } else {
        toast.error(t("deployments.records.recover.error"));
      }
    }
  });

  const recoverRecord = (record: DeploymentRecord) => {
    if (window.confirm(t("deployments.records.recover.confirm"))) {
      recoverMutation.mutate(record);
    }
  };

  const openRecoverDestroyedDialog = (record: DeploymentRecord) => {
    setRecoverDestroyedTarget(record);
  };

  const closeRecoverDestroyedDialog = () => {
    if (recoverMutation.isPending) return;
    setRecoverDestroyedTarget(null);
  };

  const reconcileMutation = useMutation({
    mutationFn: (id: number) => deploymentRecordsApi.reconcile(id),
    onSuccess: async (response) => {
      toast.success(
        t(
          response.status === "no_changes"
            ? "deployments.records.reconcile.noChanges"
            : "deployments.records.reconcile.success"
        )
      );
      await queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
      await queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-services"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: () => toast.error(t("deployments.records.reconcile.error"))
  });

  const reconcileRecord = (record: DeploymentRecord) => {
    if (window.confirm(t("deployments.records.reconcile.confirm"))) {
      reconcileMutation.mutate(record.id);
    }
  };

  const destroyMutation = useMutation({
    mutationFn: (record: DeploymentRecord) => deploymentRecordsApi.destroy(record.id),
    onMutate: (record) => {
      setDestroyInProgress({ record, phase: "requesting", startedAt: Date.now() });
      setDestroyTarget(null);
      setDestroyConfirmName("");
      destroyToastId.current = toast.loading(t("deployments.records.destroy.progress"));
    },
    onSuccess: async (response, record) => {
      if (response.status === "runtime_cleanup_pending") {
        toast.warning(t("deployments.records.destroy.pending"), { id: destroyToastId.current });
      } else {
        toast.loading(t("deployments.records.destroy.progress"), { id: destroyToastId.current });
      }
      setDestroyInProgress((current) =>
        current?.record.id === record.id
          ? { ...current, phase: "cleanup_pending" }
          : current
      );
      await queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
      await queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["untracked-services"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: () => {
      toast.error(t("deployments.records.destroy.error"), { id: destroyToastId.current });
      setDestroyInProgress(null);
      destroyToastId.current = undefined;
    }
  });

  const openDestroyDialog = (record: DeploymentRecord) => {
    setDestroyTarget(record);
    setDestroyConfirmName("");
  };

  const closeDestroyDialog = () => {
    if (destroyMutation.isPending) return;
    setDestroyTarget(null);
    setDestroyConfirmName("");
  };

  const accessMutation = useMutation({
    mutationFn: (id: number) => deploymentRecordsApi.access(id),
    onSuccess: (response, id) => {
      setAccessByDeployment((current) => ({ ...current, [id]: response }));
    },
    onError: () => toast.error(t("deployments.records.access.error"))
  });

  const openPreview = async (deploymentId: number) => {
    if (openingPreviewId !== null) return;
    const previewWindow = window.open("about:blank", "_blank");
    if (!previewWindow) {
      toast.error(t("deployments.records.access.openError"));
      return;
    }
    previewWindow.opener = null;
    setOpeningPreviewId(deploymentId);
    try {
      const access = await deploymentRecordsApi.access(deploymentId);
      setAccessByDeployment((current) => ({ ...current, [deploymentId]: access }));
      if (!access.available || !access.preview_url) {
        previewWindow.close();
        toast.error(t("deployments.records.access.openError"));
        return;
      }
      previewWindow.location.replace(deploymentRecordsApi.previewUrl(access.preview_url));
    } catch {
      previewWindow.close();
      toast.error(t("deployments.records.access.openError"));
    } finally {
      setOpeningPreviewId(null);
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

  const pendingDeleteRuntimeKey = destroyInProgress && destroyInProgress.phase !== "completed"
    ? runtimeIdentity(destroyInProgress.record.namespace, destroyInProgress.record.app_name)
    : null;
  const visibleUntrackedDeployments = useMemo(
    () => untrackedDeployments.filter(
      (deployment) => runtimeIdentity(deployment.namespace, deployment.name) !== pendingDeleteRuntimeKey
    ),
    [pendingDeleteRuntimeKey, untrackedDeployments]
  );

  useEffect(() => {
    if (
      !destroyInProgress ||
      (destroyInProgress.phase !== "cleanup_pending" && destroyInProgress.phase !== "timed_out")
    ) {
      return;
    }

    const pendingKey = runtimeIdentity(destroyInProgress.record.namespace, destroyInProgress.record.app_name);
    const activeRecordExists = records.some(
      (record) =>
        runtimeIdentity(record.namespace, record.app_name) === pendingKey &&
        !record.archived_at &&
        record.desired_state !== "destroyed"
    );
    const runtimeResourceExists = untrackedDeployments.some(
      (deployment) => runtimeIdentity(deployment.namespace, deployment.name) === pendingKey
    );
    const matchingService = services.find(
      (service) => service.name.toLowerCase() === destroyInProgress.record.app_name.toLowerCase()
    );
    const managedServiceRuntimeExists = matchingService
      ? matchingService.runtime_status?.service_found !== false ||
        matchingService.runtime_status?.related_deployment_found !== false
      : false;
    const recordsReady = recordsQuery.isSuccess && recordsQuery.dataUpdatedAt >= destroyInProgress.startedAt;
    const runtimeReady =
      untrackedQuery.isSuccess &&
      untrackedQuery.dataUpdatedAt >= destroyInProgress.startedAt &&
      untrackedQuery.data?.runtime_available !== false;
    const servicesReady = servicesQuery.isSuccess && servicesQuery.dataUpdatedAt >= destroyInProgress.startedAt;

    if (
      !recordsReady ||
      !runtimeReady ||
      !servicesReady ||
      activeRecordExists ||
      runtimeResourceExists ||
      managedServiceRuntimeExists
    ) {
      return;
    }

    toast.success(t("deployments.records.destroy.success"), { id: destroyToastId.current });
    destroyToastId.current = undefined;
    setDestroyInProgress((current) =>
      current?.record.id === destroyInProgress.record.id
        ? { ...current, phase: "completed" }
        : current
    );
    void queryClient.invalidateQueries({ queryKey: ["deployment-records"] });
    void queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
    void queryClient.invalidateQueries({ queryKey: ["untracked-deployments"] });
    void queryClient.invalidateQueries({ queryKey: ["untracked-services"] });
    void queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
    void queryClient.invalidateQueries({ queryKey: ["user-summary"] });
  }, [destroyInProgress, records, recordsQuery.dataUpdatedAt, recordsQuery.isSuccess, queryClient, services, servicesQuery.dataUpdatedAt, servicesQuery.isSuccess, t, untrackedDeployments, untrackedQuery.data?.runtime_available, untrackedQuery.dataUpdatedAt, untrackedQuery.isSuccess]);

  useEffect(() => {
    if (!destroyInProgress || destroyInProgress.phase !== "cleanup_pending") {
      return;
    }

    const elapsed = Date.now() - destroyInProgress.startedAt;
    const remaining = Math.max(0, DELETE_CLEANUP_TIMEOUT_MS - elapsed);
    const timeout = window.setTimeout(() => {
      toast.warning(t("deployments.records.destroy.timeout"), { id: destroyToastId.current });
      destroyToastId.current = undefined;
      setDestroyInProgress((current) =>
        current?.record.id === destroyInProgress.record.id
          ? { ...current, phase: "timed_out" }
          : current
      );
    }, remaining);

    return () => window.clearTimeout(timeout);
  }, [destroyInProgress, t]);

  useEffect(() => {
    if (destroyInProgress?.phase !== "completed") {
      return;
    }

    const timeout = window.setTimeout(() => setDestroyInProgress(null), DELETE_COMPLETED_DISMISS_MS);
    return () => window.clearTimeout(timeout);
  }, [destroyInProgress?.phase]);

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
        record.reconcile_status?.status ?? "",
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
    if (!query) return visibleUntrackedDeployments;
    return visibleUntrackedDeployments.filter((deployment) =>
      [deployment.name, deployment.namespace, deployment.display_status]
        .join(" ")
        .toLowerCase()
        .includes(query)
    );
  }, [search, visibleUntrackedDeployments]);

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
        const reconcile = record.reconcile_status;
        if (!reconcile) {
          return <Badge variant="muted">{t("deployments.records.reconcileState.unknown")}</Badge>;
        }
        return (
          <div className="max-w-[220px] space-y-1.5" title={reconcile.message}>
            <Badge variant={reconcileVariant(reconcile.status)}>
              {t(`deployments.records.reconcileState.${reconcile.status}`)}
            </Badge>
            <p className="truncate text-xs text-slate-500">
              {t(`deployments.records.reconcileSummary.${reconcile.status}`)}
            </p>
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
          const recoverDestroyedEligible = canRecoverDestroyed(record);
          return (
            <div className="flex flex-wrap gap-2">
              {recoverDestroyedEligible ? (
                <Button
                  aria-label={t("deployments.records.recover.destroyedAction")}
                  disabled={recoverMutation.isPending}
                  size="sm"
                  variant="outline"
                  onClick={() => openRecoverDestroyedDialog(record)}
                >
                  <RotateCcw className="h-4 w-4" />
                  {t("deployments.records.recover.destroyedAction")}
                </Button>
              ) : null}
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
            </div>
          );
        }
        const recoverEligible = canRecover(record);
        const reconcileEligible = canReconcile(record);
        const destroyEligible = canDestroy(record);
        const access = accessByDeployment[record.id];
        return (
          <div className="min-w-[220px] space-y-3">
            <div className="space-y-2" data-testid="deployment-access-actions">
              <div className="flex flex-wrap gap-2">
                <Button
                  aria-label={t("deployments.records.access.action")}
                  disabled={accessMutation.isPending && accessMutation.variables === record.id}
                  size="sm"
                  variant="outline"
                  onClick={() => accessMutation.mutate(record.id)}
                >
                  <ExternalLink className="h-4 w-4" />
                  {t("deployments.records.access.action")}
                </Button>
                {access?.available && access.preview_url ? (
                  <Button
                    aria-label={t("deployments.records.access.openAction")}
                    disabled={openingPreviewId !== null}
                    size="sm"
                    variant="outline"
                    onClick={() => void openPreview(record.id)}
                  >
                    <ExternalLink className="h-4 w-4" />
                    {t("deployments.records.access.openAction")}
                  </Button>
                ) : null}
              </div>
              {access ? (
                <div className="space-y-1 border-l border-white/10 pl-2 text-xs">
                  <Badge variant={accessVariant(access.status)}>
                    {t(`deployments.records.access.status.${access.status}`)}
                  </Badge>
                  <p className="max-w-[260px] text-slate-400">
                    {t(`deployments.records.access.message.${access.status}`)}
                  </p>
                  {access.service ? (
                    <p className="font-mono text-slate-500">
                      {access.service.name} · {access.service.namespace} · {access.service.port ?? "-"}/{access.service.service_type ?? "-"}
                    </p>
                  ) : null}
                </div>
              ) : null}
            </div>
            {recoverEligible || reconcileEligible ? (
              <div className="flex flex-wrap gap-2">
                {recoverEligible ? (
                  <Button
                    aria-label={t("deployments.records.recover.action")}
                    disabled={recoverMutation.isPending && recoverMutation.variables?.id === record.id}
                    size="sm"
                    variant="outline"
                    onClick={() => recoverRecord(record)}
                  >
                    <RotateCcw className="h-4 w-4" />
                    {t("deployments.records.recover.action")}
                  </Button>
                ) : null}
                {reconcileEligible ? (
                  <Button
                    aria-label={t("deployments.records.reconcile.action")}
                    disabled={reconcileMutation.isPending && reconcileMutation.variables === record.id}
                    size="sm"
                    variant="outline"
                    onClick={() => reconcileRecord(record)}
                  >
                    <RefreshCw className="h-4 w-4" />
                    {t("deployments.records.reconcile.action")}
                  </Button>
                ) : null}
              </div>
            ) : null}
            {recoverEligible && record.runtime_status?.display_status === "not_found" ? (
              <div className="flex flex-wrap gap-2">
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
              </div>
            ) : null}
            {destroyEligible ? (
              <div className="space-y-2 border-t border-red-300/15 pt-2" data-testid="deployment-danger-actions">
                <p className="text-[11px] font-medium text-red-200/70">
                  {t("deployments.records.destroy.dangerLabel")}
                </p>
                <Button
                  aria-label={t("deployments.records.destroy.action")}
                  disabled={destroyMutation.isPending || Boolean(destroyInProgress)}
                  size="sm"
                  variant="danger"
                  onClick={() => openDestroyDialog(record)}
                >
                  <Trash2 className="h-4 w-4" />
                  {t("deployments.records.destroy.action")}
                </Button>
              </div>
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

      {destroyInProgress ? (
        <div className="mb-5 flex items-start gap-3 rounded-lg border border-amber-300/20 bg-amber-400/[0.08] px-4 py-3 text-sm text-amber-50">
          <RefreshCw className="mt-0.5 h-4 w-4 shrink-0 animate-spin text-amber-200" />
          <div className="min-w-0 flex-1 space-y-3">
            <div>
              <p className="font-medium text-white">{t("deployments.records.destroy.progressTitle")}</p>
              <p className="text-amber-100/90">{t("deployments.records.destroy.progress")}</p>
            </div>
            <GitOpsOperationTimeline
              activeStep={deleteProgressStep(destroyInProgress.phase)}
              completed={destroyInProgress.phase === "completed"}
              kind="delete"
              timedOut={destroyInProgress.phase === "timed_out"}
            />
          </div>
        </div>
      ) : null}

      {recoverInProgress ? (
        <div className="mb-5 flex items-start gap-3 rounded-lg border border-sky-300/20 bg-sky-400/[0.08] px-4 py-3 text-sm text-sky-50">
          <RefreshCw className="mt-0.5 h-4 w-4 shrink-0 animate-spin text-sky-200" />
          <div>
            <p className="font-medium text-white">{t("deployments.records.recover.destroyedProgressTitle")}</p>
            <p className="text-sky-100/90">{t("deployments.records.recover.destroyedProgress")}</p>
          </div>
        </div>
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

      <Dialog
        closeLabel={t("common.close")}
        description={
          recoverDestroyedTarget
            ? t("deployments.records.recover.destroyedDescription", { name: recoverDestroyedTarget.app_name })
            : undefined
        }
        open={Boolean(recoverDestroyedTarget)}
        title={t("deployments.records.recover.destroyedTitle")}
        onOpenChange={(open) => {
          if (!open) closeRecoverDestroyedDialog();
        }}
      >
        {recoverDestroyedTarget ? (
          <div className="space-y-4">
            <div className="rounded-lg border border-sky-300/20 bg-sky-500/10 px-4 py-3 text-sm leading-6 text-sky-100">
              {t("deployments.records.recover.destroyedWarning")}
            </div>
            <DialogFooter>
              <Button
                disabled={recoverMutation.isPending}
                variant="outline"
                onClick={closeRecoverDestroyedDialog}
              >
                {t("common.cancel")}
              </Button>
              <Button
                disabled={recoverMutation.isPending}
                variant="primary"
                onClick={() => recoverMutation.mutate(recoverDestroyedTarget)}
              >
                <RotateCcw className="h-4 w-4" />
                {recoverMutation.isPending
                  ? t("deployments.records.recover.destroyedSubmitting")
                  : t("deployments.records.recover.destroyedConfirmAction")}
              </Button>
            </DialogFooter>
          </div>
        ) : null}
      </Dialog>

      <Dialog
        closeLabel={t("common.close")}
        description={
          destroyTarget
            ? t("deployments.records.destroy.description", { name: destroyTarget.app_name })
            : undefined
        }
        open={Boolean(destroyTarget)}
        title={t("deployments.records.destroy.title")}
        onOpenChange={(open) => {
          if (!open) closeDestroyDialog();
        }}
      >
        {destroyTarget ? (
          <div className="space-y-4">
            <div className="rounded-lg border border-red-300/20 bg-red-500/10 px-4 py-3 text-sm leading-6 text-red-100">
              {t("deployments.records.destroy.warning")}
            </div>
            <div className="space-y-2">
              <Label className="normal-case" htmlFor="destroy-confirm-name">
                {t("deployments.records.destroy.confirmLabel", { name: destroyTarget.app_name })}
              </Label>
              <Input
                id="destroy-confirm-name"
                autoComplete="off"
                value={destroyConfirmName}
                onChange={(event) => setDestroyConfirmName(event.target.value)}
              />
            </div>
            <DialogFooter>
              <Button
                disabled={destroyMutation.isPending || Boolean(destroyInProgress)}
                variant="outline"
                onClick={closeDestroyDialog}
              >
                {t("common.cancel")}
              </Button>
              <Button
                disabled={
                  destroyMutation.isPending ||
                  destroyConfirmName.trim() !== destroyTarget.app_name
                }
                variant="danger"
                onClick={() => destroyMutation.mutate(destroyTarget)}
              >
                <Trash2 className="h-4 w-4" />
                {destroyMutation.isPending
                  ? t("deployments.records.destroy.submitting")
                  : t("deployments.records.destroy.confirmAction")}
              </Button>
            </DialogFooter>
          </div>
        ) : null}
      </Dialog>
    </div>
  );
}
