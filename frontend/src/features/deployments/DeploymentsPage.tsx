import { useEffect, useMemo, useState } from "react";
import { Database, Plus, RefreshCw, Rocket, Search } from "lucide-react";
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
import type {
  DeploymentRecord,
  GitOpsAppDeployInput,
  GitOpsAppDeployResponse,
  GitOpsAppDeployStatus
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

export function DeploymentsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [search, setSearch] = useState("");
  const [gitOpsModalOpen, setGitOpsModalOpen] = useState(false);
  const [deployResponse, setDeployResponse] = useState<GitOpsAppDeployResponse | null>(null);
  const [pollTimedOut, setPollTimedOut] = useState(false);
  const recordsQuery = useQuery({
    queryKey: ["deployment-records"],
    queryFn: deploymentRecordsApi.list
  });
  const servicesQuery = useQuery({
    queryKey: ["service-definitions"],
    queryFn: serviceDefinitionsApi.list
  });
  const records = useMemo(() => recordsQuery.data ?? [], [recordsQuery.data]);
  const services = useMemo(() => servicesQuery.data ?? [], [servicesQuery.data]);
  const servicesById = useMemo(
    () => new Map(services.map((service) => [service.id, service])),
    [services]
  );

  const gitOpsMutation = useMutation({
    mutationFn: (input: GitOpsAppDeployInput) => deployGitOpsApp(input),
    onSuccess: async (response) => {
      setDeployResponse(response);
      setPollTimedOut(false);
      toast.success(t("deployments.gitopsDeploy.pushedToast"));
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
        record.status_summary ?? "",
        record.commit_sha ?? "",
        serviceName
      ]
        .join(" ")
        .toLowerCase()
        .includes(query);
    });
  }, [records, search, servicesById]);

  const columns: Column<DeploymentRecord>[] = [
    {
      key: "deployment",
      header: t("deployments.records.fields.appName"),
      render: (record) => (
        <div>
          <p className="font-medium text-white">{record.app_name}</p>
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
      header: t("deployments.records.fields.desiredState"),
      render: (record) => (
        <Badge variant={record.desired_state === "pending" ? "warning" : "muted"}>
          {t(`deployments.records.status.${record.desired_state}`)}
        </Badge>
      )
    },
    {
      key: "runtime",
      header: t("deployments.records.fields.runtimeDefaults"),
      render: (record) => (
        <span className="whitespace-nowrap font-mono text-xs">
          {record.replicas} x :{record.container_port} / {record.service_port}
        </span>
      )
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
        <div>
          <p>{formatDate(record.updated_at)}</p>
          {record.status_summary ? <p className="mt-1 max-w-[220px] text-xs text-slate-500">{record.status_summary}</p> : null}
        </div>
      )
    }
  ];

  const emptyTitle = recordsQuery.isLoading
    ? t("common.loading")
    : records.length
      ? t("deployments.records.emptyNoResultsTitle")
      : t("deployments.records.emptyTitle");
  const emptyDescription = recordsQuery.isError
    ? t("deployments.records.loadError")
    : records.length
      ? t("deployments.records.emptyNoResultsDescription")
      : t("deployments.records.emptyDescription");

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-wrap gap-3">
            <Button disabled={recordsQuery.isFetching} variant="outline" onClick={() => void recordsQuery.refetch()}>
              <RefreshCw className={recordsQuery.isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
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

      <Card>
        <CardContent className="space-y-5 pt-5">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
            <Input
              className="pl-10"
              placeholder={t("deployments.records.searchPlaceholder")}
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </div>

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

      <CreateGitOpsAppModal
        isSubmitting={gitOpsMutation.isPending}
        open={gitOpsModalOpen}
        onDeploy={(input) => gitOpsMutation.mutateAsync(input)}
        onOpenChange={setGitOpsModalOpen}
      />
    </div>
  );
}
