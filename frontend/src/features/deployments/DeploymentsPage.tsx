import { useMemo, useState } from "react";
import { Plus, Rocket } from "lucide-react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { applicationsApi, deploymentsApi, getApiErrorMessage, getApiErrorStatus } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { CreateDeploymentModal } from "@/components/deployments/CreateDeploymentModal";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { useAuth } from "@/features/auth/useAuth";
import type { Deployment, GitOpsDeploymentCreateInput, GitOpsDeploymentResponse, DeploymentStatus, Environment } from "@/types";

const environments: Environment[] = ["dev", "staging", "prod"];

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
  const { user } = useAuth();
  const [environment, setEnvironment] = useState<Environment | "all">("all");
  const [status, setStatus] = useState<DeploymentStatus | "all">("all");
  const [application, setApplication] = useState("all");
  const [modalOpen, setModalOpen] = useState(false);
  const [gitopsResult, setGitopsResult] = useState<GitOpsDeploymentResponse | null>(null);
  const deploymentsQuery = useQuery({ queryKey: ["deployments"], queryFn: deploymentsApi.list });
  const applicationsQuery = useQuery({ queryKey: ["applications"], queryFn: applicationsApi.list });
  const deployments = useMemo(() => deploymentsQuery.data ?? [], [deploymentsQuery.data]);
  const applications = useMemo(() => applicationsQuery.data ?? [], [applicationsQuery.data]);
  const applicationNameById = useMemo(() => new Map(applications.map((item) => [item.id, item.name])), [applications]);

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
        const matchesApplication = application === "all" || String(deployment.application_id) === application;
        return matchesEnvironment && matchesStatus && matchesApplication;
      }),
    [application, deployments, environment, status]
  );

  const columns: Column<Deployment>[] = [
    {
      key: "deployment",
      header: t("deployments.table.deployment"),
      render: (deployment) => (
        <div>
          <p className="font-medium text-white">{deployment.id}</p>
          <p className="text-xs text-slate-500">{formatDate(deployment.created_at)}</p>
        </div>
      )
    },
    {
      key: "application",
      header: t("deployments.table.application"),
      render: (deployment) => applicationNameById.get(deployment.application_id) ?? `${t("common.application")} #${deployment.application_id}`
    },
    { key: "imageTag", header: t("deployments.table.imageTag"), render: (deployment) => deployment.image_tag },
    { key: "environment", header: t("deployments.table.environment"), render: (deployment) => <EnvironmentBadge environment={deployment.environment} /> },
    { key: "status", header: t("deployments.table.status"), render: (deployment) => <StatusBadge status={deployment.status} type="deployment" /> },
    { key: "owner", header: t("deployments.table.owner"), render: (deployment) => (deployment.requested_by_id === user?.id ? user.username : `${t("common.user")} #${deployment.requested_by_id}`) },
    { key: "replicas", header: t("common.replicas"), render: (deployment) => deployment.replica_count },
    {
      key: "actions",
      header: t("deployments.table.actions"),
      render: (deployment) => (
        <Button asChild size="sm" variant="ghost">
          <Link to={`/deployments/${deployment.id}`}>{t("common.viewDetails")}</Link>
        </Button>
      )
    }
  ];

  return (
    <div>
      <PageHeader
        actions={
          <Button onClick={() => setModalOpen(true)}>
            <Plus className="h-4 w-4" />
            {t("deployments.createDeployment")}
          </Button>
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
              options={[
                { value: "all", label: t("common.all") },
                ...environments.map((item) => ({ value: item, label: t(`environment.${item}`) }))
              ]}
              value={environment}
              onChange={(event) => setEnvironment(event.target.value as Environment | "all")}
            />
            <Select
              aria-label={t("deployments.filters.status")}
              options={[
                { value: "all", label: t("common.all") },
                { value: "pending", label: t("status.pending") },
                { value: "running", label: t("status.running") },
                { value: "success", label: t("status.success") },
                { value: "failed", label: t("status.failed") }
              ]}
              value={status}
              onChange={(event) => setStatus(event.target.value as DeploymentStatus | "all")}
            />
            <Select
              aria-label={t("deployments.filters.application")}
              options={[{ value: "all", label: t("common.all") }, ...applications.map((item) => ({ value: String(item.id), label: item.name }))]}
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
            getRowKey={(deployment) => String(deployment.id)}
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
