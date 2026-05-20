import { useMemo, useState } from "react";
import { Boxes, Plus, Search, Trash2 } from "lucide-react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { applicationsApi } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { CreateApplicationModal } from "@/components/applications/CreateApplicationModal";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { useAuth } from "@/features/auth/useAuth";
import type { Application, ApplicationCreateInput, HealthStatus } from "@/types";

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function deriveHealth(application: Application): HealthStatus {
  if (application.id % 11 === 0) {
    return "degraded";
  }

  return "healthy";
}

export function ApplicationsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [search, setSearch] = useState("");
  const [health, setHealth] = useState<HealthStatus | "all">("all");
  const [modalOpen, setModalOpen] = useState(false);
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
      await queryClient.invalidateQueries({ queryKey: ["deployments"] });
      await queryClient.invalidateQueries({ queryKey: ["user-summary"] });
    },
    onError: () => toast.error(t("api.errors.applicationDeleteFailed"))
  });

  const filteredApplications = useMemo(() => {
    const query = search.toLowerCase();
    return applications.filter((application) => {
      const matchesSearch = [
        application.name,
        application.slug,
        application.image_name,
        application.repository_url ?? "",
        String(application.owner_id)
      ]
        .join(" ")
        .toLowerCase()
        .includes(query);
      const matchesHealth = health === "all" || deriveHealth(application) === health;
      return matchesSearch && matchesHealth;
    });
  }, [applications, health, search]);

  const columns: Column<Application>[] = [
    {
      key: "name",
      header: t("applications.table.name"),
      render: (application) => (
        <div>
          <p className="font-medium text-white">{application.name}</p>
          <p className="text-xs text-slate-500">{application.slug}</p>
        </div>
      )
    },
    {
      key: "image",
      header: t("applications.table.image"),
      render: (application) => <span className="font-mono text-xs text-slate-300">{application.image_name}</span>
    },
    {
      key: "environment",
      header: t("applications.table.environment"),
      render: (application) => <EnvironmentBadge environment={application.default_environment} />
    },
    {
      key: "owner",
      header: t("applications.table.owner"),
      render: (application) => (application.owner_id === user?.id ? user.username : `${t("common.user")} #${application.owner_id}`)
    },
    {
      key: "lastDeployment",
      header: t("applications.table.lastDeployment"),
      render: (application) => formatDate(application.updated_at ?? application.created_at)
    },
    {
      key: "health",
      header: t("applications.table.health"),
      render: (application) => <StatusBadge status={deriveHealth(application)} type="health" />
    },
    {
      key: "actions",
      header: t("applications.table.actions"),
      render: (application) => (
        <div className="flex items-center gap-2">
          <Button asChild size="sm" variant="ghost">
            <Link to={`/applications/${application.id}`}>{t("common.viewDetails")}</Link>
          </Button>
          <Button
            aria-label={t("applications.actions.delete")}
            disabled={deleteMutation.isPending}
            size="icon"
            variant="danger"
            onClick={() => deleteMutation.mutate(application.id)}
          >
            <Trash2 className="h-4 w-4" />
          </Button>
        </div>
      )
    }
  ];

  return (
    <div>
      <PageHeader
        actions={
          <Button onClick={() => setModalOpen(true)}>
            <Plus className="h-4 w-4" />
            {t("applications.newApplication")}
          </Button>
        }
        description={t("applications.description")}
        title={t("applications.title")}
      />

      <Card>
        <CardContent className="space-y-5 pt-5">
          <div className="grid gap-3 lg:grid-cols-[1fr_220px]">
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
              <Input className="pl-10" placeholder={t("applications.searchPlaceholder")} value={search} onChange={(event) => setSearch(event.target.value)} />
            </div>
            <Select
              aria-label={t("applications.statusFilter")}
              options={[
                { value: "all", label: t("common.all") },
                { value: "healthy", label: t("health.healthy") },
                { value: "degraded", label: t("health.degraded") },
                { value: "critical", label: t("health.critical") }
              ]}
              value={health}
              onChange={(event) => setHealth(event.target.value as HealthStatus | "all")}
            />
          </div>

          <DataTable
            columns={columns}
            data={filteredApplications}
            emptyState={
              <EmptyState
                action={{ label: t("applications.newApplication"), onClick: () => setModalOpen(true) }}
                description={applicationsQuery.isError ? t("api.errors.applicationsLoadFailed") : t("applications.emptyDescription")}
                icon={<Boxes className="h-5 w-5" />}
                title={applicationsQuery.isLoading ? t("common.loading") : t("applications.emptyTitle")}
              />
            }
            getRowKey={(application) => String(application.id)}
          />
        </CardContent>
      </Card>

      <CreateApplicationModal
        isSubmitting={createMutation.isPending}
        open={modalOpen}
        onCreate={async (application) => {
          await createMutation.mutateAsync(application);
        }}
        onOpenChange={setModalOpen}
      />
    </div>
  );
}
