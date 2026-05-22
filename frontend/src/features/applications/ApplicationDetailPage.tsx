import { useMemo, useState } from "react";
import { Boxes, Clock, ExternalLink, GitBranch, Package, Rocket, Server } from "lucide-react";
import { Link, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { applicationsApi, deploymentsApi, getApiErrorMessage, getApiErrorStatus } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs } from "@/components/ui/tabs";
import { PageHeader } from "@/components/layout/PageHeader";
import { CreateDeploymentModal } from "@/components/deployments/CreateDeploymentModal";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatCard } from "@/components/shared/StatCard";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { useAuth } from "@/features/auth/useAuth";
import type { DeploymentListItem, GitOpsDeploymentCreateInput } from "@/types";

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

export function ApplicationDetailPage() {
  const { id } = useParams();
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [activeTab, setActiveTab] = useState("overview");
  const [deploymentModalOpen, setDeploymentModalOpen] = useState(false);
  const applicationId = Number(id);
  const applicationQuery = useQuery({
    queryKey: ["application", applicationId],
    queryFn: () => applicationsApi.get(applicationId),
    enabled: Number.isFinite(applicationId)
  });
  const deploymentsQuery = useQuery({ queryKey: ["deployments"], queryFn: deploymentsApi.listGitOps });
  const application = applicationQuery.data;

  const relatedDeployments = useMemo(
    () =>
      (deploymentsQuery.data ?? []).filter(
        (deployment) =>
          deployment.application_id === application?.id ||
          deployment.app_name === application?.slug ||
          deployment.app_name === application?.name
      ),
    [application?.id, application?.name, application?.slug, deploymentsQuery.data]
  );

  const deployMutation = useMutation({
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
      await queryClient.invalidateQueries({ queryKey: ["dashboard-summary"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: (error) => {
      if (getApiErrorStatus(error) === 503) {
        toast.error(t("api.errors.deploymentAutomationUnavailable"));
        return;
      }
      toast.error(getApiErrorMessage(error) || t("api.errors.gitopsRequestFailed"));
    }
  });

  if (applicationQuery.isLoading) {
    return <EmptyState description={t("applications.detail.loadingDescription")} title={t("common.loading")} />;
  }

  if (!application) {
    return (
      <EmptyState description={t("applications.detail.notFoundDescription")} title={t("applications.detail.notFoundTitle")} />
    );
  }

  const deploymentColumns: Column<DeploymentListItem>[] = [
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
      render: (deployment) => <span className="break-all font-mono text-xs text-cyan-100">{imageLabel(deployment)}</span>
    },
    { key: "environment", header: t("deployments.table.environment"), render: (deployment) => formatEnvironment(t, deployment.environment) },
    { key: "status", header: t("deployments.table.status"), render: (deployment) => <StatusBadge status={deployment.status} type="deployment" /> },
    {
      key: "source",
      header: t("deployments.table.source"),
      render: (deployment) => <Badge variant={deployment.is_live ? "success" : "warning"}>{deployment.is_live ? t("deployments.source.gitopsLive") : t("deployments.source.pendingRequest")}</Badge>
    },
    { key: "updated", header: t("deployments.table.updated"), render: (deployment) => formatDate(deployment.updated_at ?? deployment.created_at) },
    {
      key: "actions",
      header: t("deployments.table.actions"),
      render: (deployment) => (
        <Button asChild size="sm" variant="ghost">
          <Link to={`/deployments/gitops/${deployment.namespace}/${deployment.name}`}>{t("common.viewDetails")}</Link>
        </Button>
      )
    }
  ];

  return (
    <div>
      <PageHeader
        actions={
          <Button onClick={() => setDeploymentModalOpen(true)}>
            <Rocket className="h-4 w-4" />
            {t("applications.actions.deploy")}
          </Button>
        }
        description={t("applications.detail.subtitle")}
        title={application.name}
      />

      <div className="mb-6 flex flex-wrap items-center gap-3">
        <EnvironmentBadge environment={application.default_environment} />
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-slate-400">{application.slug}</span>
        <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 font-mono text-xs text-cyan-100">{application.image_name}</span>
      </div>

      <Tabs
        tabs={[
          { value: "overview", label: t("applications.tabs.overview") },
          { value: "deployments", label: t("applications.tabs.deployments") },
          { value: "settings", label: t("applications.tabs.settings") }
        ]}
        value={activeTab}
        onValueChange={setActiveTab}
      />

      <div className="mt-6">
        {activeTab === "overview" ? (
          <div className="space-y-6">
            <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
              <StatCard detail={application.slug} icon={<Package className="h-5 w-5" />} label={t("applications.table.imageRepository")} value={application.image_name} />
              <StatCard detail={t("applications.detail.defaultEnvironmentDetail")} icon={<Boxes className="h-5 w-5" />} label={t("applications.table.defaultEnvironment")} tone="violet" value={t(`environment.${application.default_environment}`)} />
              <StatCard detail={t("applications.detail.defaultPortDetail")} icon={<Server className="h-5 w-5" />} label={t("applications.table.defaultPort")} tone="emerald" value={String(application.container_port)} />
              <StatCard detail={user?.email ?? `${t("common.user")} #${application.owner_id}`} icon={<GitBranch className="h-5 w-5" />} label={t("common.owner")} tone="amber" value={application.owner_id === user?.id ? user.username : `${t("common.user")} #${application.owner_id}`} />
              <StatCard detail={t("common.created")} icon={<Clock className="h-5 w-5" />} label={t("common.lastUpdated")} value={formatDate(application.updated_at ?? application.created_at)} />
            </div>

            <Card>
              <CardHeader>
                <CardTitle>{t("applications.detail.catalogMetadata")}</CardTitle>
                <CardDescription>{t("applications.detail.catalogMetadataDescription")}</CardDescription>
              </CardHeader>
              <CardContent className="grid gap-4 md:grid-cols-2">
                {[
                  [t("common.description"), application.description || t("applications.detail.noDescription")],
                  [t("common.repository"), application.repository_url || t("applications.detail.noRepository")],
                  [t("applications.table.defaultEnvironment"), t(`environment.${application.default_environment}`)],
                  [t("applications.modal.containerPort"), String(application.container_port)]
                ].map(([label, value]) => (
                  <div key={label} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                    <p className="text-xs uppercase text-slate-500">{label}</p>
                    {label === t("common.repository") && application.repository_url ? (
                      <a className="mt-2 inline-flex max-w-full items-center gap-2 break-all text-sm text-cyan-200 hover:text-cyan-100" href={application.repository_url} rel="noreferrer" target="_blank">
                        {application.repository_url}
                        <ExternalLink className="h-3.5 w-3.5 shrink-0" />
                      </a>
                    ) : (
                      <p className="mt-2 break-all text-sm text-white">{value}</p>
                    )}
                  </div>
                ))}
              </CardContent>
            </Card>
          </div>
        ) : null}

        {activeTab === "deployments" ? (
          <Card>
            <CardContent className="pt-5">
              <DataTable
                columns={deploymentColumns}
                data={relatedDeployments}
                emptyState={<EmptyState description={t("applications.detail.deploymentsEmptyDescription")} title={t("applications.detail.deploymentsEmptyTitle")} />}
                getRowKey={(deployment) => `${deployment.source}/${deployment.namespace}/${deployment.name}/${deployment.id ?? "live"}`}
              />
            </CardContent>
          </Card>
        ) : null}

        {activeTab === "settings" ? (
          <Card>
            <CardHeader>
              <CardTitle>{t("applications.detail.settingsTitle")}</CardTitle>
              <CardDescription>{t("applications.detail.settingsDescription")}</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-4 md:grid-cols-2">
              {[
                [t("common.owner"), user?.username ?? `${t("common.user")} #${application.owner_id}`],
                [t("common.repository"), application.repository_url ?? "-"],
                [t("applications.table.imageRepository"), application.image_name],
                [t("applications.modal.containerPort"), String(application.container_port)],
                [t("applications.modal.defaultEnvironment"), t(`environment.${application.default_environment}`)],
                [t("common.created"), formatDate(application.created_at)]
              ].map(([label, value]) => (
                <div key={label} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                  <p className="text-xs uppercase text-slate-500">{label}</p>
                  <p className="mt-2 break-all text-sm text-white">{value}</p>
                </div>
              ))}
            </CardContent>
          </Card>
        ) : null}
      </div>

      <CreateDeploymentModal
        applications={[application]}
        initialApplicationId={application.id}
        isSubmitting={deployMutation.isPending}
        open={deploymentModalOpen}
        onCreate={async (deployment) => {
          await deployMutation.mutateAsync(deployment);
        }}
        onOpenChange={setDeploymentModalOpen}
      />
    </div>
  );
}
