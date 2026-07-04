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
import type { ServiceDefinition, ServiceRuntimeStatus } from "@/types";

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function runtimeVariant(status: ServiceRuntimeStatus["display_status"]) {
  if (status === "ready") return "success";
  if (status === "not_found") return "warning";
  return "muted";
}

function runtimePorts(runtime: ServiceRuntimeStatus) {
  return runtime.ports?.map((port) => `${port.port}/${port.protocol ?? "TCP"}`).join(", ") ?? "-";
}

export function ApplicationsPage() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const [search, setSearch] = useState("");
  const servicesQuery = useQuery({
    queryKey: ["service-definitions"],
    queryFn: serviceDefinitionsApi.list
  });
  const services = useMemo(() => servicesQuery.data ?? [], [servicesQuery.data]);

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
        if (!runtime) {
          return <Badge variant="muted">{t("runtimeStatus.unknown")}</Badge>;
        }
        return (
          <div className="space-y-1.5">
            <Badge variant={runtimeVariant(runtime.display_status)}>
              {t(`runtimeStatus.${runtime.display_status}`)}
            </Badge>
            <p className="font-mono text-xs text-slate-500">
              {runtime.service_type ?? "-"} · {runtime.cluster_ip ?? "-"}
            </p>
            <p className="font-mono text-xs text-slate-500">{runtimePorts(runtime)}</p>
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
          <Button disabled={servicesQuery.isFetching} variant="outline" onClick={() => void servicesQuery.refetch()}>
            <RefreshCw className={servicesQuery.isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
            {t("common.refresh")}
          </Button>
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
                description={emptyDescription}
                icon={<Boxes className="h-5 w-5" />}
                title={emptyTitle}
              />
            }
            getRowKey={(service) => String(service.id)}
          />
        </CardContent>
      </Card>
    </div>
  );
}
