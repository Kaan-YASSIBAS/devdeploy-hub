import { useMemo, useState } from "react";
import { Boxes, RefreshCw, Search } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { serviceDefinitionsApi } from "@/api/client";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { useAuth } from "@/features/auth/useAuth";
import type {
  RuntimeServicePort,
  ServiceDefinition,
  ServiceRuntimeStatus,
  UntrackedServiceRuntime
} from "@/types";

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function runtimeVariant(status: ServiceRuntimeStatus["display_status"] | UntrackedServiceRuntime["display_status"]) {
  if (status === "ready") return "success";
  if (status === "not_found") return "warning";
  return "muted";
}

function runtimePorts(ports: RuntimeServicePort[] | null) {
  return ports?.map((port) => `${port.port}/${port.protocol ?? "TCP"}`).join(", ") ?? "-";
}

export function ApplicationsPage() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const [search, setSearch] = useState("");
  const servicesQuery = useQuery({
    queryKey: ["service-definitions"],
    queryFn: serviceDefinitionsApi.list
  });
  const untrackedQuery = useQuery({
    queryKey: ["untracked-services"],
    queryFn: serviceDefinitionsApi.listUntracked
  });
  const services = useMemo(() => servicesQuery.data ?? [], [servicesQuery.data]);
  const untrackedServices = useMemo(() => untrackedQuery.data?.items ?? [], [untrackedQuery.data]);

  const filteredServices = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return services;
    return services.filter((service) =>
      [
        service.name,
        service.description ?? "",
        service.default_image ?? "",
        service.runtime_status?.display_status ?? "",
        service.runtime_status?.cluster_ip ?? "",
        String(service.default_port ?? ""),
        String(service.owner_id)
      ]
        .join(" ")
        .toLowerCase()
        .includes(query)
    );
  }, [search, services]);

  const filteredUntracked = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return untrackedServices;
    return untrackedServices.filter((service) =>
      [service.name, service.namespace, service.display_status, service.service_type ?? "", service.cluster_ip ?? ""]
        .join(" ")
        .toLowerCase()
        .includes(query)
    );
  }, [search, untrackedServices]);

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
      key: "runtime",
      header: t("applications.domain.fields.runtime"),
      render: (service) => {
        const runtime = service.runtime_status;
        if (!runtime) return <Badge variant="muted">{t("runtimeStatus.unknown")}</Badge>;
        return (
          <div className="space-y-1.5">
            <Badge variant={runtimeVariant(runtime.display_status)}>
              {t(`runtimeStatus.${runtime.display_status}`)}
            </Badge>
            <p className="font-mono text-xs text-slate-500">
              {runtime.service_type ?? "-"} / {runtime.cluster_ip ?? "-"}
            </p>
            <p className="font-mono text-xs text-slate-500">{runtimePorts(runtime.ports)}</p>
          </div>
        );
      }
    },
    {
      key: "defaults",
      header: t("applications.domain.fields.defaults"),
      render: (service) => (
        <span className="whitespace-nowrap font-mono text-xs">
          {service.default_replicas} x :{service.default_port ?? "-"}
        </span>
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

  const untrackedColumns: Column<UntrackedServiceRuntime>[] = [
    {
      key: "service",
      header: t("applications.domain.fields.name"),
      render: (service) => (
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <p className="font-medium text-white">{service.name}</p>
            <Badge variant="warning">{t("untracked.badge")}</Badge>
          </div>
          <p className="text-xs text-slate-500">{service.namespace}</p>
        </div>
      )
    },
    {
      key: "status",
      header: t("applications.domain.fields.runtime"),
      render: (service) => (
        <Badge variant={runtimeVariant(service.display_status)}>
          {t(`runtimeStatus.${service.display_status}`)}
        </Badge>
      )
    },
    {
      key: "network",
      header: t("untracked.network"),
      render: (service) => (
        <div className="space-y-1 font-mono text-xs">
          <p>{service.service_type ?? "-"} / {service.cluster_ip ?? "-"}</p>
          <p className="text-slate-500">{runtimePorts(service.ports)}</p>
        </div>
      )
    },
    {
      key: "related",
      header: t("untracked.relatedDeployment"),
      render: (service) =>
        service.related_deployment_found
          ? t(`runtimeStatus.${service.related_deployment_status ?? "unknown"}`)
          : t("runtimeStatus.not_found")
    },
    {
      key: "observed",
      header: t("untracked.observed"),
      render: (service) => formatDate(service.observed_at)
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
  const showManaged =
    filteredServices.length > 0 ||
    filteredUntracked.length === 0 ||
    servicesQuery.isLoading ||
    servicesQuery.isError;
  const untrackedUnavailable = untrackedQuery.isError || untrackedQuery.data?.runtime_available === false;

  return (
    <div>
      <PageHeader
        actions={
          <Button
            disabled={servicesQuery.isFetching || untrackedQuery.isFetching}
            variant="outline"
            onClick={() => void Promise.all([servicesQuery.refetch(), untrackedQuery.refetch()])}
          >
            <RefreshCw className={servicesQuery.isFetching || untrackedQuery.isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
            {t("common.refresh")}
          </Button>
        }
        description={t("applications.domain.description")}
        title={t("applications.title")}
      />

      <div className="relative mb-5">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
        <Input
          className="pl-10"
          placeholder={t("applications.domain.searchPlaceholder")}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
      </div>

      <div className="space-y-5">
        {showManaged ? (
          <Card>
            <CardContent className="space-y-4 pt-5">
              {filteredServices.length ? (
                <div>
                  <h2 className="text-sm font-semibold text-white">{t("untracked.managedServices")}</h2>
                  <p className="mt-1 text-xs text-slate-500">{t("untracked.managedDescription")}</p>
                </div>
              ) : null}
              <DataTable
                columns={columns}
                data={filteredServices}
                emptyState={
                  <EmptyState
                    description={emptyDescription}
                    icon={<Boxes className="h-5 w-5" />}
                    title={emptyTitle}
                  />
                }
                getRowKey={(service) => String(service.id)}
              />
            </CardContent>
          </Card>
        ) : null}

        {filteredUntracked.length ? (
          <Card className="border-amber-300/20">
            <CardContent className="space-y-4 pt-5">
              <div>
                <h2 className="text-sm font-semibold text-amber-100">{t("untracked.servicesTitle")}</h2>
                <p className="mt-1 text-xs text-slate-400">{t("untracked.description")}</p>
                <p className="mt-1 text-xs text-slate-500">{t("untracked.importLater")}</p>
              </div>
              <DataTable
                columns={untrackedColumns}
                data={filteredUntracked}
                getRowKey={(service) => `${service.namespace}/${service.name}`}
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
    </div>
  );
}
