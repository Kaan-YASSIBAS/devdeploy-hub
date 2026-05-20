import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { MetricChart } from "@/components/shared/MetricChart";
import { metrics } from "@/lib/mock-data";

export function MonitoringPage() {
  const { t } = useTranslation();
  const [range, setRange] = useState("sixHours");

  return (
    <div>
      <PageHeader
        actions={
          <Select
            aria-label={t("monitoring.timeRange")}
            className="w-[150px]"
            options={[
              { value: "oneHour", label: t("monitoring.ranges.oneHour") },
              { value: "sixHours", label: t("monitoring.ranges.sixHours") },
              { value: "twentyFourHours", label: t("monitoring.ranges.twentyFourHours") },
              { value: "sevenDays", label: t("monitoring.ranges.sevenDays") }
            ]}
            value={range}
            onChange={(event) => setRange(event.target.value)}
          />
        }
        description={t("monitoring.description")}
        title={t("monitoring.title")}
      />

      <div className="grid gap-6 xl:grid-cols-2">
        <MetricChart color="#22d3ee" data={metrics} dataKey="cpu" label={t("common.cpu")} title={t("monitoring.charts.cpu")} />
        <MetricChart color="#a78bfa" data={metrics} dataKey="memory" label={t("common.memory")} title={t("monitoring.charts.memory")} />
        <MetricChart color="#34d399" data={metrics} dataKey="requests" label={t("monitoring.charts.requests")} title={t("monitoring.charts.requests")} type="bar" />
        <MetricChart color="#f87171" data={metrics} dataKey="errors" label={t("monitoring.charts.errors")} title={t("monitoring.charts.errors")} type="bar" />
        <div className="xl:col-span-2">
          <MetricChart color="#fbbf24" data={metrics} dataKey="restarts" label={t("monitoring.charts.restarts")} title={t("monitoring.charts.restarts")} type="bar" />
        </div>
      </div>
    </div>
  );
}
