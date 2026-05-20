import { useMemo } from "react";
import { useTranslation } from "react-i18next";
import { StatusBadge } from "@/components/shared/StatusBadge";
import type { LogEntry } from "@/types";
import { cn } from "@/lib/utils";

type TerminalLogsProps = {
  logs: LogEntry[];
  compact?: boolean;
};

export function TerminalLogs({ logs, compact = false }: TerminalLogsProps) {
  const { t } = useTranslation();
  const rows = useMemo(
    () =>
      logs.map((entry) => ({
        ...entry,
        message: t(entry.messageKey, entry.values)
      })),
    [logs, t]
  );

  return (
    <div
      className={cn(
        "scrollbar-soft overflow-auto rounded-2xl border border-white/10 bg-slate-950/80 font-mono text-xs shadow-inner",
        compact ? "max-h-[320px]" : "max-h-[560px]"
      )}
    >
      <div className="min-w-[820px] divide-y divide-white/[0.06]">
        {rows.map((entry) => (
          <div key={entry.id} className="grid grid-cols-[180px_90px_180px_1fr] gap-3 px-4 py-3 text-slate-300">
            <span className="text-slate-500">{entry.timestamp}</span>
            <StatusBadge type="log" status={entry.level} />
            <span className="truncate text-cyan-200">{entry.pod}</span>
            <span className="truncate">{entry.message}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
