import { useEffect, useMemo, useRef } from "react";
import { useTranslation } from "react-i18next";
import { StatusBadge } from "@/components/shared/StatusBadge";
import type { MockLogEntry } from "@/types";
import { cn } from "@/lib/utils";

type TerminalLogsProps = {
  logs: MockLogEntry[];
  compact?: boolean;
  autoScroll?: boolean;
};

export function TerminalLogs({ logs, compact = false, autoScroll = false }: TerminalLogsProps) {
  const { t } = useTranslation();
  const containerRef = useRef<HTMLDivElement>(null);
  const rows = useMemo(
    () =>
      logs.map((entry) => ({
        ...entry,
        message: t(entry.messageKey, entry.values)
      })),
    [logs, t]
  );

  useEffect(() => {
    if (autoScroll && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
    }
  }, [autoScroll, rows.length]);

  return (
    <div
      ref={containerRef}
      className={cn(
        "scrollbar-soft overflow-auto rounded-2xl border border-white/10 bg-slate-950/80 font-mono text-xs shadow-inner",
        compact ? "max-h-[320px]" : "max-h-[560px]"
      )}
    >
      <div className="min-w-[820px] divide-y divide-white/[0.06]">
        {rows.length ? rows.map((entry) => (
          <div key={entry.id} className="grid grid-cols-[180px_90px_180px_1fr] gap-3 px-4 py-3 text-slate-300">
            <span className="text-slate-500">{entry.timestamp}</span>
            <StatusBadge type="log" status={entry.level} />
            <span className="truncate text-cyan-200">{entry.pod}</span>
            <span className="truncate">{entry.message}</span>
          </div>
        )) : (
          <div className="px-4 py-8 text-center text-sm text-slate-500">{t("empty.title")}</div>
        )}
      </div>
    </div>
  );
}
