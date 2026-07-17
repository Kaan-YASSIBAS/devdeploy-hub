import { Boxes, Database, Layers, Network, RefreshCw, Server, ShipWheel } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { observabilityApi, getApiErrorStatus } from "@/api/client";
import { Badge, type BadgeProps } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EmptyState } from "@/components/shared/EmptyState";
import { StatCard } from "@/components/shared/StatCard";
import type { KubernetesDeployment, KubernetesPod, KubernetesService } from "@/types";

function phaseVariant(phase: string | null): BadgeProps["variant"] {
  switch (phase?.toLowerCase()) {
    case "running":
    case "succeeded":
      return "success";
    case "pending":
      return "warning";
    case "failed":
      return "danger";
    default:
      return "muted";
  }
}

function formatPorts(service: KubernetesService) {
  if (!service.ports.length) {
    return "-";
  }

  return service.ports
    .map((port) => {
      const target = port.target_port === null || port.target_port === undefined ? "" : `:${port.target_port}`;
      const protocol = port.protocol ? `/${port.protocol}` : "";
      return `${port.port}${target}${protocol}`;
    })
    .join(", ");
}

function getErrorKey(status?: number) {
  if (status === 403) {
    return "api.errors.observabilityPermissionDenied";
  }

  if (status === 503) {
    return "api.errors.observabilityUnavailable";
  }

  return "api.errors.observabilityLoadFailed";
}

export function ClusterPage() {
  const { t } = useTranslation();
  const [namespace, setNamespace] = useState("");

  const summaryQuery = useQuery({
    queryKey: ["observability", "cluster-summary", namespace],
    queryFn: () => observabilityApi.clusterSummary(namespace),
    enabled: Boolean(namespace)
  });
  const namespacesQuery = useQuery({ queryKey: ["observability", "namespaces"], queryFn: observabilityApi.namespaces });
  const podsQuery = useQuery({ queryKey: ["observability", "pods", namespace], queryFn: () => observabilityApi.pods(namespace), enabled: Boolean(namespace) });
  const deploymentsQuery = useQuery({
    queryKey: ["observability", "kubernetes-deployments", namespace],
    queryFn: () => observabilityApi.kubernetesDeployments(namespace),
    enabled: Boolean(namespace)
  });
  const servicesQuery = useQuery({ queryKey: ["observability", "services", namespace], queryFn: () => observabilityApi.services(namespace), enabled: Boolean(namespace) });

  const namespaces = useMemo(() => namespacesQuery.data ?? [], [namespacesQuery.data]);
  const pods = podsQuery.data ?? [];
  const deployments = deploymentsQuery.data ?? [];
  const services = servicesQuery.data ?? [];
  const selectedNamespace = namespaces.find((item) => item.name === namespace);
  const namespaceOptions = useMemo(() => {
    const options = namespaces.map((item) => ({ value: item.name, label: item.name }));
    return namespace && !options.some((item) => item.value === namespace)
      ? [{ value: namespace, label: namespace }, ...options]
      : options;
  }, [namespace, namespaces]);

  useEffect(() => {
    if (!namespace && namespaces.length) {
      setNamespace(namespaces[0].name);
    }
  }, [namespace, namespaces]);

  const isLoading = !namespace || summaryQuery.isLoading || podsQuery.isLoading || deploymentsQuery.isLoading || servicesQuery.isLoading;
  const firstError = summaryQuery.error ?? podsQuery.error ?? deploymentsQuery.error ?? servicesQuery.error ?? namespacesQuery.error;
  const errorDescription = firstError ? t(getErrorKey(getApiErrorStatus(firstError))) : t("cluster.emptyDescription");
  const unavailableValue = summaryQuery.isLoading ? "..." : t("common.unavailable");

  const podColumns: Column<KubernetesPod>[] = [
    {
      key: "name",
      header: t("common.name"),
      render: (pod) => (
        <div>
          <p className="font-medium text-white">{pod.name}</p>
          <p className="text-xs text-slate-500">{pod.created_at ? new Date(pod.created_at).toLocaleString() : t("common.unavailable")}</p>
        </div>
      )
    },
    { key: "namespace", header: t("common.namespace"), render: (pod) => pod.namespace },
    {
      key: "phase",
      header: t("cluster.table.phase"),
      render: (pod) => <Badge variant={phaseVariant(pod.phase)}>{pod.phase ?? t("common.unavailable")}</Badge>
    },
    { key: "node", header: t("common.node"), render: (pod) => pod.node_name ?? "-" },
    { key: "restarts", header: t("common.restarts"), render: (pod) => pod.restart_count },
    { key: "containers", header: t("cluster.table.containersReady"), render: (pod) => pod.containers_ready }
  ];

  const deploymentColumns: Column<KubernetesDeployment>[] = [
    {
      key: "name",
      header: t("common.name"),
      render: (deployment) => <span className="font-medium text-white">{deployment.name}</span>
    },
    { key: "namespace", header: t("common.namespace"), render: (deployment) => deployment.namespace },
    {
      key: "replicas",
      header: t("common.replicas"),
      render: (deployment) => `${deployment.ready_replicas}/${deployment.replicas}`
    },
    { key: "available", header: t("cluster.table.availableReplicas"), render: (deployment) => deployment.available_replicas },
    { key: "updated", header: t("cluster.table.updatedReplicas"), render: (deployment) => deployment.updated_replicas }
  ];

  const serviceColumns: Column<KubernetesService>[] = [
    {
      key: "name",
      header: t("common.name"),
      render: (service) => <span className="font-medium text-white">{service.name}</span>
    },
    { key: "type", header: t("cluster.table.type"), render: (service) => service.type ?? "-" },
    { key: "clusterIp", header: t("cluster.table.clusterIp"), render: (service) => service.cluster_ip ?? "-" },
    { key: "ports", header: t("cluster.table.ports"), render: (service) => <span className="font-mono text-xs">{formatPorts(service)}</span> }
  ];

  const refresh = () => {
    void summaryQuery.refetch();
    void namespacesQuery.refetch();
    void podsQuery.refetch();
    void deploymentsQuery.refetch();
    void servicesQuery.refetch();
  };

  return (
    <div>
      <PageHeader
        actions={
          <div className="grid gap-3 sm:grid-cols-[190px_auto]">
            <Select
              aria-label={t("common.namespace")}
              options={namespaceOptions}
              value={namespace}
              onChange={(event) => setNamespace(event.target.value)}
            />
            <Button variant="outline" onClick={refresh}>
              <RefreshCw className="h-4 w-4" />
              {t("common.refresh")}
            </Button>
          </div>
        }
        description={t("cluster.description")}
        title={t("cluster.title")}
      />

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-6">
        <StatCard
          detail={summaryQuery.data?.current_context ?? t("cluster.realData")}
          icon={<Layers className="h-5 w-5" />}
          label={t("cluster.overview.namespaces")}
          tone="violet"
          value={summaryQuery.data ? String(summaryQuery.data.namespaces_count) : unavailableValue}
        />
        <StatCard
          detail={namespace}
          icon={<Boxes className="h-5 w-5" />}
          label={t("cluster.overview.pods")}
          tone="emerald"
          value={summaryQuery.data ? String(summaryQuery.data.pods_count) : unavailableValue}
        />
        <StatCard
          detail={namespace}
          icon={<ShipWheel className="h-5 w-5" />}
          label={t("cluster.overview.deployments")}
          tone="amber"
          value={summaryQuery.data ? String(summaryQuery.data.deployments_count) : unavailableValue}
        />
        <StatCard
          detail={namespace}
          icon={<Network className="h-5 w-5" />}
          label={t("cluster.overview.services")}
          value={summaryQuery.data ? String(summaryQuery.data.services_count) : unavailableValue}
        />
        <StatCard
          detail={t("cluster.readyNodes")}
          icon={<Server className="h-5 w-5" />}
          label={t("cluster.overview.nodes")}
          tone="cyan"
          value={summaryQuery.data ? `${summaryQuery.data.ready_nodes_count}/${summaryQuery.data.nodes_count}` : unavailableValue}
        />
        <StatCard
          detail={selectedNamespace?.status ?? t("cluster.namespaceStatus")}
          icon={<Database className="h-5 w-5" />}
          label={t("common.namespace")}
          tone="violet"
          value={namespace}
        />
      </div>

      {firstError ? (
        <EmptyState className="mt-6" description={errorDescription} title={t("cluster.unavailableTitle")} />
      ) : null}

      <div className="mt-6 grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t("cluster.pods")}</CardTitle>
            <CardDescription>{t("cluster.tableDescription", { namespace })}</CardDescription>
          </CardHeader>
          <CardContent>
            <DataTable
              columns={podColumns}
              data={pods}
              emptyState={<EmptyState description={errorDescription} title={isLoading ? t("common.loading") : t("cluster.emptyPods")} />}
              getRowKey={(pod) => `${pod.namespace}/${pod.name}`}
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("cluster.deployments")}</CardTitle>
            <CardDescription>{t("cluster.tableDescription", { namespace })}</CardDescription>
          </CardHeader>
          <CardContent>
            <DataTable
              columns={deploymentColumns}
              data={deployments}
              emptyState={<EmptyState description={errorDescription} title={isLoading ? t("common.loading") : t("cluster.emptyDeployments")} />}
              getRowKey={(deployment) => `${deployment.namespace}/${deployment.name}`}
            />
          </CardContent>
        </Card>
      </div>

      <Card className="mt-6">
        <CardHeader>
          <CardTitle>{t("cluster.services")}</CardTitle>
          <CardDescription>{t("cluster.tableDescription", { namespace })}</CardDescription>
        </CardHeader>
        <CardContent>
          <DataTable
            columns={serviceColumns}
            data={services}
            emptyState={<EmptyState description={errorDescription} title={isLoading ? t("common.loading") : t("cluster.emptyServices")} />}
            getRowKey={(service) => `${service.namespace}/${service.name}`}
          />
        </CardContent>
      </Card>
    </div>
  );
}
