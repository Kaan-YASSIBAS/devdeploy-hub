import { useMemo, useState } from "react";
import { Boxes, Plus, RefreshCw, Search } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { getApiErrorMessage, serviceDefinitionsApi } from "@/api/client";
import { CreateServiceDefinitionModal } from "@/components/applications/CreateServiceDefinitionModal";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { useAuth } from "@/features/auth/useAuth";
import type { ServiceDefinition, ServiceDefinitionCreateInput } from "@/types";

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
  const servicesQuery = useQuery({
    queryKey: ["service-definitions"],
    queryFn: serviceDefinitionsApi.list
  });
  const services = useMemo(() => servicesQuery.data ?? [], [servicesQuery.data]);

  const createMutation = useMutation({
    mutationFn: (input: ServiceDefinitionCreateInput) => serviceDefinitionsApi.create(input),
    onSuccess: async () => {
      toast.success(t("applications.domain.createdToast"));
      await queryClient.invalidateQueries({ queryKey: ["service-definitions"] });
    },
    onError: (error) => {
      toast.error(getApiErrorMessage(error) || t("applications.domain.createFailed"));
    }
  });

  const filteredServices = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) {
      return services;
    }

    return services.filter((service) =>
      [
        service.name,
        service.description ?? "",
        service.default_image ?? "",
        String(service.default_port ?? ""),
        String(service.owner_id)
      ]
        .join(" ")
        .toLowerCase()
        .includes(query)
    );
  }, [search, services]);

  const columns: Column<ServiceDefinition>[] = [
    {
      key: "service",
      header: t("applications.domain.fields.name"),
      render: (service) => (
        <div className="max-w-[280px]">
          <p className="font-medium text-white">{service.name}</p>
          <p className="mt-1 line-clamp-2 text-xs text-slate-500">
            {service.description || t("applications.domain.noDescription")}
          </p>
        </div>
      )
    },
    {
      key: "image",
      header: t("applications.domain.fields.defaultImage"),
      render: (service) =>
        service.default_image ? (
          <span className="break-all font-mono text-xs text-cyan-100">{service.default_image}</span>
        ) : (
          <span className="text-slate-500">{t("applications.domain.notSet")}</span>
        )
    },
    {
      key: "replicas",
      header: t("applications.domain.fields.defaultReplicas"),
      render: (service) => <span className="font-mono text-xs">{service.default_replicas}</span>
    },
    {
      key: "port",
      header: t("applications.domain.fields.defaultPort"),
      render: (service) => (
        <span className="font-mono text-xs">{service.default_port ?? t("applications.domain.notSet")}</span>
      )
    },
    {
      key: "owner",
      header: t("applications.domain.fields.owner"),
      render: (service) =>
        service.owner_id === user?.id ? user.username : `${t("common.user")} #${service.owner_id}`
    },
    {
      key: "updated",
      header: t("applications.domain.fields.updated"),
      render: (service) => formatDate(service.updated_at)
    }
  ];

  const emptyTitle = servicesQuery.isLoading
    ? t("common.loading")
    : services.length
      ? t("applications.domain.emptyNoResultsTitle")
      : t("applications.domain.emptyTitle");
  const emptyDescription = servicesQuery.isError
    ? t("applications.domain.loadError")
    : services.length
      ? t("applications.domain.emptyNoResultsDescription")
      : t("applications.domain.emptyDescription");

  return (
    <div>
      <PageHeader
        actions={
          <div className="flex flex-wrap gap-3">
            <Button
              disabled={servicesQuery.isFetching}
              variant="outline"
              onClick={() => void servicesQuery.refetch()}
            >
              <RefreshCw className={servicesQuery.isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
              {t("common.refresh")}
            </Button>
            <Button onClick={() => setCreateModalOpen(true)}>
              <Plus className="h-4 w-4" />
              {t("applications.domain.newService")}
            </Button>
          </div>
        }
        description={t("applications.domain.description")}
        title={t("applications.title")}
      />

      <Card>
        <CardContent className="space-y-5 pt-5">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
            <Input
              className="pl-10"
              placeholder={t("applications.domain.searchPlaceholder")}
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </div>

          <DataTable
            columns={columns}
            data={filteredServices}
            emptyState={
              <EmptyState
                action={{ label: t("applications.domain.newService"), onClick: () => setCreateModalOpen(true) }}
                description={emptyDescription}
                icon={<Boxes className="h-5 w-5" />}
                title={emptyTitle}
              />
            }
            getRowKey={(service) => String(service.id)}
          />
        </CardContent>
      </Card>

      <CreateServiceDefinitionModal
        isSubmitting={createMutation.isPending}
        open={createModalOpen}
        onCreate={(input) => createMutation.mutateAsync(input)}
        onOpenChange={setCreateModalOpen}
      />
    </div>
  );
}
