import { useMemo, useState } from "react";
import { Boxes, Plus, Search } from "lucide-react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
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
import { applications as seedApplications } from "@/lib/mock-data";
import type { Application, HealthStatus } from "@/types";

export function ApplicationsPage() {
  const { t } = useTranslation();
  const [applications, setApplications] = useState<Application[]>(seedApplications);
  const [search, setSearch] = useState("");
  const [health, setHealth] = useState<HealthStatus | "all">("all");
  const [modalOpen, setModalOpen] = useState(false);

  const filteredApplications = useMemo(() => {
    const query = search.toLowerCase();
    return applications.filter((application) => {
      const matchesSearch = [application.name, application.image, application.owner, application.namespace]
        .join(" ")
        .toLowerCase()
        .includes(query);
      const matchesHealth = health === "all" || application.health === health;
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
          <p className="text-xs text-slate-500">{application.namespace}</p>
        </div>
      )
    },
    {
      key: "image",
      header: t("applications.table.image"),
      render: (application) => <span className="font-mono text-xs text-slate-300">{application.image}</span>
    },
    {
      key: "environment",
      header: t("applications.table.environment"),
      render: (application) => <EnvironmentBadge environment={application.environment} />
    },
    {
      key: "owner",
      header: t("applications.table.owner"),
      render: (application) => application.owner
    },
    {
      key: "lastDeployment",
      header: t("applications.table.lastDeployment"),
      render: (application) => application.lastDeployment
    },
    {
      key: "health",
      header: t("applications.table.health"),
      render: (application) => <StatusBadge status={application.health} type="health" />
    },
    {
      key: "actions",
      header: t("applications.table.actions"),
      render: (application) => (
        <Button asChild size="sm" variant="ghost">
          <Link to={`/applications/${application.id}`}>{t("common.viewDetails")}</Link>
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
                description={t("applications.emptyDescription")}
                icon={<Boxes className="h-5 w-5" />}
                title={t("applications.emptyTitle")}
              />
            }
            getRowKey={(application) => application.id}
          />
        </CardContent>
      </Card>

      <CreateApplicationModal
        open={modalOpen}
        onCreate={(application) => setApplications((current) => [application, ...current])}
        onOpenChange={setModalOpen}
      />
    </div>
  );
}
