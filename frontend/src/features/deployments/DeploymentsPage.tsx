import { useEffect, useMemo, useState } from "react";
import { Plus, RefreshCw, Rocket, Trash2 } from "lucide-react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { applicationsApi, deployGitOpsApp, deploymentsApi, getApiErrorMessage, getApiErrorStatus, getGitOpsAppStatus } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { CreateGitOpsAppModal } from "@/components/deployments/CreateGitOpsAppModal";
import { GitOpsDeployStatusCard } from "@/components/deployments/GitOpsDeployStatusCard";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { StatusBadge } from "@/components/shared/StatusBadge";
import type { DeploymentListItem, DeploymentStatus, GitOpsAppDeployInput, GitOpsAppDeployStatus, GitOpsAppDeployResponse } from "@/types";

const statuses: DeploymentStatus[] = ["pending", "running", "progressing", "success", "failed", "stale", "deletion_requested", "deleted", "unknown"];
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

function formatEnvironment(t: ReturnType<typeof useTranslation>["t"], value: string) {
  return t(`environment.${value}`, { defaultValue: value });
}

function imageLabel(deployment: DeploymentListItem) {
  if (!deployment.image && !deployment.tag) {
    return "-";
  }
  if (!deployment.image) {
    return deployment.tag ?? "-";
  }
  return deployment.tag ? `${deployment.image}:${deployment.tag}` : deployment.image;
}

function sourceVariant(deployment: DeploymentListItem) {
  if (deployment.source === "gitops" && (deployment.status === "stale" || deployment.status === "deleted")) {
    return "muted";
  }
  if (deployment.source === "gitops" && deployment.status === "deletion_requested") {
    return "warning";
  }
  if (deployment.source === "gitops" && deployment.status === "failed" && !deployment.is_live) {
    return "danger";
  }
  if (deployment.source === "gitops" && !deployment.is_live) {
    return "warning";
  }
  if (deployment.source === "gitops") {
    return "success";
  }
  if (deployment.source === "cluster") {
    return "info";
  }
  return "muted";
}

function sourceLabelKey(deployment: DeploymentListItem) {
  if (deployment.source === "gitops" && deployment.is_live) {
    return "deployments.source.gitopsLive";
  }
  if (deployment.source === "gitops" && deployment.status === "stale") {
    return "deployments.source.staleRequest";
  }
  if (deployment.source === "gitops" && deployment.status === "failed" && !deployment.is_live) {
    return "deployments.source.failedRequest";
  }
  if (deployment.source === "gitops" && !deployment.is_live) {
    return "deployments.source.pendingRequest";
  }
  return `deployments.source.${deployment.source}`;
}

export function DeploymentsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [environment, setEnvironment] = useState<string>("all");
  const [status, setStatus] = useState<DeploymentStatus | "all">("all");
  const [application, setApplication] = useState("all");
  const [modalOpen, setModalOpen] = useState(false);
  const [deployResponse, setDeployResponse] = useState<GitOpsAppDeployResponse | null>(null);
  const [pollTimedOut, setPollTimedOut] = useState(false);
  const deploymentsQuery = useQuery({ queryKey: ["deployments"], queryFn: deploymentsApi.listGitOps });
  const applicationsQuery = useQuery({ queryKey: ["applications"], queryFn: applicationsApi.list });
  const deployments = useMemo(() => deploymentsQuery.data ?? [], [deploymentsQuery.data]);
  const applications = useMemo(() => applicationsQuery.data ?? [], [applicationsQuery.data]);
  const applicationOptions = useMemo(() => {
    const appOptions = applications.map((item) => ({ value: String(item.id), label: item.name }));
    const liveOptions = deployments
      .filter((deployment) => deployment.application_id === null)
      .map((deployment) => deployment.app_name)
      .filter((name, index, names) => names.indexOf(name) === index)
      .map((name) => ({ value: `name:${name}`, label: name }));
    return [{ value: "all", label: t("common.all") }, ...appOptions, ...liveOptions];
  }, [applications, deployments, t]);
  const environmentOptions = useMemo(() => {
    const values = deployments
      .map((deployment) => deployment.environment)
      .filter((value, index, values) => values.indexOf(value) === index);
    return [
      { value: "all", label: t("common.all") },
      ...values.map((value) => ({ value, label: formatEnvironment(t, value) }))
    ];
  }, [deployments, t]);

  const createMutation = useMutation({
    mutationFn: (input: GitOpsAppDeployInput) => deployGitOpsApp(input),
    onSuccess: async (response) => {
      setDeployResponse(response);
      setPollTimedOut(false);
      toast.success(t("deployments.gitopsDeploy.pushedToast"));
      await queryClient.invalidateQueries({ queryKey: ["deployments"] });
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

    void queryClient.invalidateQueries({ queryKey: ["deployments"] });
    void queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
    void queryClient.invalidateQueries({ queryKey: ["user-summary"] });
  }, [liveStatus, queryClient]);

  const deleteMutation = useMutation({
    mutationFn: (deployment: DeploymentListItem) => deploymentsApi.deleteGitOps(deployment.namespace, deployment.name),
    onSuccess: async (response) => {
      if (response.workflow_triggered) {
        toast.success(t("deployments.gitops.delete.startedToast"));
      } else {
        toast.error(t("api.errors.deploymentAutomationUnavailable"));
      }
      await queryClient.invalidateQueries({ queryKey: ["deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: (error) => {
      if (getApiErrorStatus(error) === 503) {
        toast.error(t("api.errors.deploymentAutomationUnavailable"));
        return;
      }
      toast.error(getApiErrorMessage(error) || t("api.errors.deploymentDeleteFailed"));
    }
  });

  const confirmDelete = (deployment: DeploymentListItem) => {
    if (window.confirm(t("deployments.gitops.delete.confirm", { name: deployment.name }))) {
      deleteMutation.mutate(deployment);
    }
  };

  const filteredDeployments = useMemo(
    () =>
      deployments.filter((deployment) => {
        const matchesEnvironment = environment === "all" || deployment.environment === environment;
        const matchesStatus = status === "all" || deployment.status === status;
        const matchesApplication =
          application === "all" ||
          String(deployment.application_id) === application ||
          `name:${deployment.app_name}` === application;
        return matchesEnvironment && matchesStatus && matchesApplication;
      }),
    [application, deployments, environment, status]
  );

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
    { key: "application", header: t("deployments.table.application"), render: (deployment) => deployment.app_name },
    {
      key: "image",
      header: t("deployments.table.imageTag"),
      render: (deployment) => <span className="break-all font-mono text-xs text-cyan-100">{imageLabel(deployment)}</span>
    },
    { key: "environment", header: t("deployments.table.environment"), render: (deployment) => formatEnvironment(t, deployment.environment) },
    { key: "status", header: t("deployments.table.status"), render: (deployment) => <StatusBadge status={deployment.status} type="deployment" /> },
    {
      key: "source",
      header: t("deployments.table.source"),
      render: (deployment) => <Badge variant={sourceVariant(deployment)}>{t(sourceLabelKey(deployment))}</Badge>
    },
    {
      key: "replicas",
      header: t("common.replicas"),
      render: (deployment) => (
        <span className="font-mono text-xs">
          {deployment.available_replicas}/{deployment.replicas}
          <span className="ml-2 text-slate-500">{t("deployments.table.updatedShort", { count: deployment.updated_replicas })}</span>
        </span>
      )
    },
    { key: "updated", header: t("deployments.table.updated"), render: (deployment) => formatDate(deployment.updated_at ?? deployment.created_at) },
    {
      key: "actions",
      header: t("deployments.table.actions"),
      render: (deployment) => {
        const href =
          deployment.source === "legacy" && deployment.legacy_deployment_id
            ? `/deployments/${deployment.legacy_deployment_id}`
            : `/deployments/gitops/${deployment.namespace}/${deployment.name}`;
        return (
          <div className="flex flex-wrap items-center gap-2">
            <Button asChild size="sm" variant="ghost">
              <Link to={href}>{t("common.viewDetails")}</Link>
            </Button>
            {deployment.source !== "legacy" ? (
              <Button
                aria-label={t("deployments.gitops.delete.action")}
                disabled={deleteMutation.isPending || deployment.status === "deletion_requested" || deployment.status === "deleted"}
                size="icon"
                variant="danger"
                onClick={() => confirmDelete(deployment)}
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            ) : null}
          </div>
        );
      }
    }
  ];

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-wrap gap-3">
            <Button variant="outline" onClick={() => void deploymentsQuery.refetch()}>
              <RefreshCw className="h-4 w-4" />
              {t("common.refresh")}
            </Button>
            <Button onClick={() => setModalOpen(true)}>
              <Plus className="h-4 w-4" />
              {t("deployments.createDeployment")}
            </Button>
          </div>
        }
        description={t("deployments.description")}
        title={t("deployments.title")}
      />

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
          <div className="grid gap-3 lg:grid-cols-3">
            <Select
              aria-label={t("deployments.filters.environment")}
              options={environmentOptions}
              value={environment}
              onChange={(event) => setEnvironment(event.target.value)}
            />
            <Select
              aria-label={t("deployments.filters.status")}
              options={[
                { value: "all", label: t("common.all") },
                ...statuses.map((item) => ({ value: item, label: t(`status.${item}`) }))
              ]}
              value={status}
              onChange={(event) => setStatus(event.target.value as DeploymentStatus | "all")}
            />
            <Select
              aria-label={t("deployments.filters.application")}
              options={applicationOptions}
              value={application}
              onChange={(event) => setApplication(event.target.value)}
            />
          </div>

          <DataTable
            columns={columns}
            data={filteredDeployments}
            emptyState={
              <EmptyState
                description={deploymentsQuery.isError ? t("api.errors.deploymentsLoadFailed") : t("deployments.emptyDescription")}
                icon={<Rocket className="h-5 w-5" />}
                title={deploymentsQuery.isLoading ? t("common.loading") : t("deployments.emptyTitle")}
              />
            }
            getRowKey={(deployment) => `${deployment.source}/${deployment.namespace}/${deployment.name}/${deployment.id ?? "live"}`}
          />
        </CardContent>
      </Card>

      <CreateGitOpsAppModal
        isSubmitting={createMutation.isPending}
        open={modalOpen}
        onDeploy={(input) => createMutation.mutateAsync(input)}
        onOpenChange={setModalOpen}
      />
    </div>
  );
}
