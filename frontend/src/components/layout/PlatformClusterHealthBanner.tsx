import { useQuery } from "@tanstack/react-query";
import { CircleAlert } from "lucide-react";
import { useTranslation } from "react-i18next";
import { platformApi } from "@/api/client";
import type { PlatformClusterHealthItem } from "@/types";

function ClusterWarning({ cluster }: { cluster: PlatformClusterHealthItem }) {
  const { t } = useTranslation();
  const management = cluster.role === "management";

  return (
    <div
      className={`flex items-start gap-3 border px-4 py-3 ${
        management
          ? "border-red-400/30 bg-red-500/10 text-red-100"
          : "border-amber-400/30 bg-amber-500/10 text-amber-100"
      }`}
    >
      <CircleAlert className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <p className="text-sm font-semibold">
            {t(`platformHealth.${cluster.role}.title`)}
          </p>
          <span className="border border-current/25 px-2 py-0.5 text-xs font-medium">
            {t(`platformHealth.status.${cluster.status}`)}
          </span>
        </div>
        <p className="mt-1 text-sm text-current/80">
          {t(`platformHealth.${cluster.role}.description`)}
        </p>
        <details className="mt-2 text-sm text-current/85">
          <summary className="cursor-pointer font-medium">
            {t("platformHealth.recovery.title")}
          </summary>
          <div className="mt-2 space-y-2 border-l border-current/20 pl-3">
            <p>{t(`platformHealth.${cluster.role}.recovery`)}</p>
            <p>{t(`platformHealth.${cluster.role}.impact`)}</p>
            <p className="text-xs text-current/70">
              {t("platformHealth.recovery.guidanceOnly")}
            </p>
          </div>
        </details>
      </div>
    </div>
  );
}

export function PlatformClusterHealthBanner() {
  const { t } = useTranslation();
  const healthQuery = useQuery({
    queryKey: ["platform", "cluster-health"],
    queryFn: platformApi.clusterHealth,
    staleTime: 30_000,
    retry: 1
  });

  if (!healthQuery.data) {
    return null;
  }

  const unhealthyClusters = [healthQuery.data.management, healthQuery.data.workload].filter(
    (cluster) => cluster.status !== "healthy"
  );
  if (unhealthyClusters.length === 0) {
    return null;
  }

  return (
    <section
      aria-label={t("platformHealth.title")}
      className="mb-4 space-y-2"
      role="status"
    >
      {unhealthyClusters.map((cluster) => (
        <ClusterWarning key={cluster.role} cluster={cluster} />
      ))}
    </section>
  );
}
