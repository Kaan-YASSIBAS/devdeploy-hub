import { useMemo, useState } from "react";
import { Plus, RefreshCw, Rocket } from "lucide-react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { applicationsApi, deploymentsApi, getApiErrorMessage, getApiErrorStatus } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { CreateDeploymentModal } from "@/components/deployments/CreateDeploymentModal";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { StatusBadge } from "@/components/shared/StatusBadge";
import type { DeploymentListItem, DeploymentListSource, GitOpsDeploymentCreateInput, GitOpsDeploymentResponse, DeploymentStatus } from "@/types";

const statuses: DeploymentStatus[] = ["pending", "running", "progressing", "success", "failed", "unknown"];

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

function sourceVariant(source: DeploymentListSource) {
  if (source === "gitops") {
    return "success";
  }
  if (source === "cluster") {
    return "info";
  }
  return "muted";
}

export function DeploymentsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [environment, setEnvironment] = useState<string>("all");
  const [status, setStatus] = useState<DeploymentStatus | "all">("all");
  const [application, setApplication] = useState("all");
  const [modalOpen, setModalOpen] = useState(false);
  const [gitopsResult, setGitopsResult] = useState<GitOpsDeploymentResponse | null>(null);
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
    mutationFn: (input: GitOpsDeploymentCreateInput) => deploymentsApi.createGitOps(input),
    onSuccess: async (response) => {
      if (response.workflow_triggered) {
        toast.success(t("deployments.gitops.result.startedToast"));
      } else if (response.request.status === "failed") {
        toast.error(response.request.error_message ?? t("api.errors.gitopsRequestFailed"));
      } else {
        toast.error(t("api.errors.deploymentAutomationUnavailable"));
      }

      await queryClient.invalidateQueries({ queryKey: ["deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: (error) => {
      if (getApiErrorStatus(error) === 503) {
        toast.error(t("api.errors.deploymentAutomationUnavailable"));
        return;
      }

      const message = getApiErrorMessage(error);
      toast.error(message || t("api.errors.gitopsRequestFailed"));
    }
  });

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
      render: (deployment) => <Badge variant={sourceVariant(deployment.source)}>{t(`deployments.source.${deployment.source}`)}</Badge>
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
          <Button asChild size="sm" variant="ghost">
            <Link to={href}>{t("common.viewDetails")}</Link>
          </Button>
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

      {gitopsResult ? (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>
              {gitopsResult.workflow_triggered
                ? t("deployments.gitops.result.workflowTriggered")
                : gitopsResult.request.status === "failed"
                  ? t("deployments.gitops.result.failed")
                  : t("api.errors.deploymentAutomationUnavailable")}
            </CardTitle>
            <CardDescription>
              {gitopsResult.workflow_triggered
                ? t("deployments.gitops.result.workflowTriggeredDescription")
                : gitopsResult.request.status === "failed"
                  ? t("deployments.gitops.result.failedDescription")
                  : t("api.errors.deploymentAutomationUnavailable")}
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
              <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <p className="text-xs uppercase text-slate-500">{t("deployments.gitops.appName")}</p>
                <p className="mt-2 font-medium text-white">{gitopsResult.request.app_name}</p>
              </div>
              <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <p className="text-xs uppercase text-slate-500">{t("deployments.gitops.image")}</p>
                <p className="mt-2 break-all font-mono text-xs text-cyan-200">{`${gitopsResult.request.image}:${gitopsResult.request.tag}`}</p>
              </div>
              <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <p className="text-xs uppercase text-slate-500">{t("deployments.gitops.namespace")}</p>
                <p className="mt-2 font-medium text-white">{gitopsResult.request.namespace}</p>
              </div>
              <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <p className="text-xs uppercase text-slate-500">{t("common.status")}</p>
                <p className="mt-2 font-medium text-white">{t(`deployments.gitops.status.${gitopsResult.request.status}`)}</p>
              </div>
            </div>

            {gitopsResult.workflow_triggered ? null : (
              <div className="rounded-2xl border border-amber-300/15 bg-amber-300/[0.06] p-4 text-sm leading-6 text-amber-100">
                {gitopsResult.request.status === "failed" ? gitopsResult.request.error_message ?? t("api.errors.gitopsRequestFailed") : t("api.errors.deploymentAutomationUnavailable")}
              </div>
            )}
          </CardContent>
        </Card>
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

      <CreateDeploymentModal
        applications={applications}
        isSubmitting={createMutation.isPending}
        open={modalOpen}
        onCreate={async (deployment) => {
          const response = await createMutation.mutateAsync(deployment);
          setGitopsResult(response);
        }}
        onOpenChange={setModalOpen}
      />
    </div>
  );
}
