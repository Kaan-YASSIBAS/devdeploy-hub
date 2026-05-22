import { useMemo, useState } from "react";
import { Boxes, ExternalLink, Plus, RefreshCw, Rocket, Search, Trash2 } from "lucide-react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { applicationsApi, deploymentsApi, getApiErrorMessage, getApiErrorStatus } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { PageHeader } from "@/components/layout/PageHeader";
import { CreateApplicationModal } from "@/components/applications/CreateApplicationModal";
import { CreateDeploymentModal } from "@/components/deployments/CreateDeploymentModal";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { useAuth } from "@/features/auth/useAuth";
import type { Application, ApplicationCreateInput, GitOpsDeploymentCreateInput } from "@/types";

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

export function ApplicationsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [search, setSearch] = useState("");
  const [createModalOpen, setCreateModalOpen] = useState(false);
  const [deploymentModalOpen, setDeploymentModalOpen] = useState(false);
  const [deploymentApplicationId, setDeploymentApplicationId] = useState<number | null>(null);
  const applicationsQuery = useQuery({ queryKey: ["applications"], queryFn: applicationsApi.list });
  const applications = useMemo(() => applicationsQuery.data ?? [], [applicationsQuery.data]);

  const createMutation = useMutation({
    mutationFn: (input: ApplicationCreateInput) => applicationsApi.create(input),
    onSuccess: async () => {
      toast.success(t("api.success.applicationCreated"));
      await queryClient.invalidateQueries({ queryKey: ["applications"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: () => toast.error(t("api.errors.applicationCreateFailed"))
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => applicationsApi.remove(id),
    onSuccess: async () => {
      toast.success(t("api.success.applicationDeleted"));
      await queryClient.invalidateQueries({ queryKey: ["applications"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: (error) => {
      if (getApiErrorStatus(error) === 409) {
        toast.error(t("api.errors.applicationDeleteBlocked"));
        return;
      }
      toast.error(getApiErrorMessage(error) || t("api.errors.applicationDeleteFailed"));
    }
  });

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

  const filteredApplications = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) {
      return applications;
    }

    return applications.filter((application) =>
      [
        application.name,
        application.slug,
        application.image_name,
        application.repository_url ?? "",
        application.default_environment,
        String(application.container_port),
        String(application.owner_id)
      ]
        .join(" ")
        .toLowerCase()
        .includes(query)
    );
  }, [applications, search]);

  const openDeployShortcut = (application: Application) => {
    setDeploymentApplicationId(application.id);
    setDeploymentModalOpen(true);
  };

  const confirmDelete = (application: Application) => {
    if (window.confirm(t("applications.actions.deleteConfirm", { name: application.name }))) {
      deleteMutation.mutate(application.id);
    }
  };

  const columns: Column<Application>[] = [
    {
      key: "application",
      header: t("applications.table.application"),
      render: (application) => (
        <div>
          <p className="font-medium text-white">{application.name}</p>
          <p className="text-xs text-slate-500">{application.slug}</p>
        </div>
      )
    },
    {
      key: "image",
      header: t("applications.table.imageRepository"),
      render: (application) => <span className="break-all font-mono text-xs text-cyan-100">{application.image_name}</span>
    },
    {
      key: "environment",
      header: t("applications.table.defaultEnvironment"),
      render: (application) => <EnvironmentBadge environment={application.default_environment} />
    },
    {
      key: "owner",
      header: t("applications.table.owner"),
      render: (application) => (application.owner_id === user?.id ? user.username : `${t("common.user")} #${application.owner_id}`)
    },
    {
      key: "port",
      header: t("applications.table.defaultPort"),
      render: (application) => <span className="font-mono text-xs">{application.container_port}</span>
    },
    {
      key: "repository",
      header: t("applications.table.repository"),
      render: (application) =>
        application.repository_url ? (
          <a className="inline-flex max-w-[240px] items-center gap-2 truncate text-cyan-200 hover:text-cyan-100" href={application.repository_url} rel="noreferrer" target="_blank">
            <span className="truncate">{application.repository_url}</span>
            <ExternalLink className="h-3.5 w-3.5 shrink-0" />
          </a>
        ) : (
          <span className="text-slate-500">-</span>
        )
    },
    {
      key: "updated",
      header: t("applications.table.updatedCreated"),
      render: (application) =>
        application.updated_at
          ? t("applications.table.updatedAt", { date: formatDate(application.updated_at) })
          : t("applications.table.createdAt", { date: formatDate(application.created_at) })
    },
    {
      key: "actions",
      header: t("applications.table.actions"),
      render: (application) => (
        <div className="flex flex-wrap items-center gap-2">
          <Button asChild size="sm" variant="ghost">
            <Link to={`/applications/${application.id}`}>{t("common.viewDetails")}</Link>
          </Button>
          <Button size="sm" variant="outline" onClick={() => openDeployShortcut(application)}>
            <Rocket className="h-4 w-4" />
            {t("applications.actions.deploy")}
          </Button>
          <Button
            aria-label={t("applications.actions.delete")}
            disabled={deleteMutation.isPending}
            size="icon"
            variant="danger"
            onClick={() => confirmDelete(application)}
          >
            <Trash2 className="h-4 w-4" />
          </Button>
        </div>
      )
    }
  ];

  const emptyTitle = applicationsQuery.isLoading
    ? t("common.loading")
    : applications.length
      ? t("applications.emptyNoResultsTitle")
      : t("applications.emptyTitle");
  const emptyDescription = applicationsQuery.isError
    ? t("api.errors.applicationsLoadFailed")
    : applications.length
      ? t("applications.emptyNoResultsDescription")
      : t("applications.emptyDescription");

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-wrap gap-3">
            <Button disabled={applicationsQuery.isFetching} variant="outline" onClick={() => void applicationsQuery.refetch()}>
              <RefreshCw className={applicationsQuery.isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
              {t("common.refresh")}
            </Button>
            <Button onClick={() => setCreateModalOpen(true)}>
              <Plus className="h-4 w-4" />
              {t("applications.newApplication")}
            </Button>
          </div>
        }
        description={t("applications.description")}
        title={t("applications.title")}
      />

      <Card>
        <CardContent className="space-y-5 pt-5">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
            <Input className="pl-10" placeholder={t("applications.searchPlaceholder")} value={search} onChange={(event) => setSearch(event.target.value)} />
          </div>

          <DataTable
            columns={columns}
            data={filteredApplications}
            emptyState={
              <EmptyState
                action={{ label: t("applications.newApplication"), onClick: () => setCreateModalOpen(true) }}
                description={emptyDescription}
                icon={<Boxes className="h-5 w-5" />}
                title={emptyTitle}
              />
            }
            getRowKey={(application) => String(application.id)}
          />
        </CardContent>
      </Card>

      <CreateApplicationModal
        isSubmitting={createMutation.isPending}
        open={createModalOpen}
        onCreate={async (application) => {
          await createMutation.mutateAsync(application);
        }}
        onOpenChange={setCreateModalOpen}
      />

      <CreateDeploymentModal
        applications={applications}
        initialApplicationId={deploymentApplicationId}
        isSubmitting={deployMutation.isPending}
        open={deploymentModalOpen}
        onCreate={async (deployment) => {
          await deployMutation.mutateAsync(deployment);
        }}
        onOpenChange={(open) => {
          setDeploymentModalOpen(open);
          if (!open) {
            setDeploymentApplicationId(null);
          }
        }}
      />
    </div>
  );
}
