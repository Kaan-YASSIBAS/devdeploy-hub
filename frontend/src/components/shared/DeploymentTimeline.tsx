import { CheckCircle2, CircleDashed, Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { DeploymentEvent } from "@/types";
import { cn } from "@/lib/utils";

type DeploymentTimelineProps = {
  events: DeploymentEvent[];
};

export function DeploymentTimeline({ events }: DeploymentTimelineProps) {
  const { t } = useTranslation();

  return (
    <div className="space-y-4">
      {events.map((event, index) => {
        const isLast = index === events.length - 1;
        const Icon = event.status === "complete" ? CheckCircle2 : event.status === "current" ? Loader2 : CircleDashed;

        return (
          <div key={event.id} className="relative flex gap-4">
            {!isLast ? <div className="absolute left-4 top-8 h-full w-px bg-white/10" /> : null}
            <div
              className={cn(
                "relative z-10 flex h-8 w-8 items-center justify-center rounded-full border bg-slate-950",
                event.status === "complete" && "border-emerald-300/40 text-emerald-200",
                event.status === "current" && "border-cyan-300/40 text-cyan-200",
                event.status === "pending" && "border-white/10 text-slate-500"
              )}
            >
              <Icon className={cn("h-4 w-4", event.status === "current" && "animate-spin")} />
            </div>
            <div className="min-w-0 flex-1 pb-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="font-medium text-white">{t(event.labelKey)}</p>
                <span className="text-xs text-slate-500">{event.timestamp}</span>
              </div>
              <p className="mt-1 text-sm leading-6 text-slate-400">{t(event.descriptionKey)}</p>
            </div>
          </div>
        );
      })}
    </div>
  );
}
