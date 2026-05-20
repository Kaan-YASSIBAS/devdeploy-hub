import { AlertTriangle, CheckCircle2, CircleDashed, Info, Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { DeploymentEvent, DeploymentStatus } from "@/types";
import { cn } from "@/lib/utils";

type ApiDeploymentTimelineProps = {
  events: DeploymentEvent[];
  status?: DeploymentStatus;
};

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

export function ApiDeploymentTimeline({ events, status }: ApiDeploymentTimelineProps) {
  const { t } = useTranslation();

  if (!events.length) {
    return <div className="rounded-2xl border border-dashed border-white/10 bg-white/[0.025] p-6 text-sm text-slate-500">{t("deployments.detail.noEvents")}</div>;
  }

  return (
    <div className="space-y-4">
      {events.map((event, index) => {
        const isLast = index === events.length - 1;
        const Icon =
          event.level === "success"
            ? CheckCircle2
            : event.level === "error"
              ? AlertTriangle
              : event.level === "warning"
                ? CircleDashed
                : status === "running" && isLast
                  ? Loader2
                  : Info;

        return (
          <div key={event.id} className="relative flex gap-4">
            {!isLast ? <div className="absolute left-4 top-8 h-full w-px bg-white/10" /> : null}
            <div
              className={cn(
                "relative z-10 flex h-8 w-8 items-center justify-center rounded-full border bg-slate-950",
                event.level === "success" && "border-emerald-300/40 text-emerald-200",
                event.level === "error" && "border-red-300/40 text-red-200",
                event.level === "warning" && "border-amber-300/40 text-amber-200",
                event.level === "info" && "border-cyan-300/40 text-cyan-200"
              )}
            >
              <Icon className={cn("h-4 w-4", status === "running" && isLast && "animate-spin")} />
            </div>
            <div className="min-w-0 flex-1 pb-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="font-medium text-white">{event.message}</p>
                <span className="text-xs text-slate-500">{formatDate(event.created_at)}</span>
              </div>
              <p className="mt-1 text-xs uppercase tracking-wide text-slate-500">{event.event_type.replace(/_/g, " ")}</p>
            </div>
          </div>
        );
      })}
    </div>
  );
}
