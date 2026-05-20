import { Boxes, Cpu, Database, Layers, MemoryStick, Network, Server, ShipWheel } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/layout/PageHeader";
import { DataTable, type Column } from "@/components/shared/DataTable";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatCard } from "@/components/shared/StatCard";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { applications, deployments, namespaces, nodes, pods } from "@/lib/mock-data";
import type { Node } from "@/types";

export function ClusterPage() {
  const { t } = useTranslation();
  const avgCpu = Math.round(nodes.reduce((sum, node) => sum + node.cpu, 0) / nodes.length);
  const avgMemory = Math.round(nodes.reduce((sum, node) => sum + node.memory, 0) / nodes.length);

  const columns: Column<Node>[] = [
    {
      key: "node",
      header: t("cluster.table.node"),
      render: (node) => (
        <div>
          <p className="font-medium text-white">{node.name}</p>
          <p className="text-xs text-slate-500">{node.zone}</p>
        </div>
      )
    },
    { key: "status", header: t("cluster.table.status"), render: (node) => <StatusBadge status={node.status} type="health" /> },
    { key: "cpu", header: t("cluster.table.cpu"), render: (node) => `${node.cpu}%` },
    { key: "memory", header: t("cluster.table.memory"), render: (node) => `${node.memory}%` },
    { key: "pods", header: t("cluster.table.pods"), render: (node) => node.pods },
    { key: "version", header: t("cluster.table.version"), render: (node) => node.version },
    { key: "zone", header: t("cluster.table.zone"), render: (node) => node.zone }
  ];

  return (
    <div>
      <PageHeader description={t("cluster.description")} title={t("cluster.title")} />

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4 2xl:grid-cols-7">
        <StatCard detail={t("dashboard.stats.details.clusterHealth")} icon={<Server className="h-5 w-5" />} label={t("cluster.overview.nodes")} value={String(nodes.length)} />
        <StatCard detail={t("common.active")} icon={<Layers className="h-5 w-5" />} label={t("cluster.overview.namespaces")} tone="violet" value={String(namespaces.length)} />
        <StatCard detail={t("dashboard.stats.details.healthyPods")} icon={<Boxes className="h-5 w-5" />} label={t("cluster.overview.pods")} tone="emerald" value={String(pods.length)} />
        <StatCard detail={t("common.active")} icon={<Network className="h-5 w-5" />} label={t("cluster.overview.services")} tone="cyan" value="18" />
        <StatCard detail={t("common.active")} icon={<ShipWheel className="h-5 w-5" />} label={t("cluster.overview.deployments")} tone="amber" value={String(deployments.length)} />
        <StatCard detail={t("common.cpu")} icon={<Cpu className="h-5 w-5" />} label={t("cluster.overview.cpuUsage")} tone="red" value={`${avgCpu}%`} />
        <StatCard detail={t("common.memory")} icon={<MemoryStick className="h-5 w-5" />} label={t("cluster.overview.memoryUsage")} tone="violet" value={`${avgMemory}%`} />
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-[1.25fr_0.75fr]">
        <Card>
          <CardHeader>
            <CardTitle>{t("cluster.nodes")}</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable columns={columns} data={nodes} getRowKey={(node) => node.id} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("cluster.namespaces")}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {namespaces.map((namespace) => (
              <div key={namespace} className="flex items-center justify-between rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <div className="flex items-center gap-3">
                  <Database className="h-4 w-4 text-cyan-200" />
                  <span className="text-sm font-medium text-white">{namespace}</span>
                </div>
                <span className="text-xs text-slate-500">{pods.filter((pod) => pod.namespace === namespace).length}</span>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>

      <Card className="mt-6">
        <CardHeader>
          <CardTitle>{t("cluster.workloadHealth")}</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {applications.map((application) => (
            <div key={application.id} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <div className="flex items-center justify-between gap-3">
                <p className="font-medium text-white">{application.name}</p>
                <StatusBadge status={application.health} type="health" />
              </div>
              <div className="mt-4 flex items-center justify-between gap-3">
                <EnvironmentBadge environment={application.environment} />
                <span className="text-sm text-slate-400">{application.healthScore}%</span>
              </div>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
