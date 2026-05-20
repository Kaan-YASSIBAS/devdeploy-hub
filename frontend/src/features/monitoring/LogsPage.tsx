import { useMemo, useState } from "react";
import { Clipboard, Search } from "lucide-react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/layout/PageHeader";
import { TerminalLogs } from "@/components/shared/TerminalLogs";
import { applications, logs } from "@/lib/mock-data";
import type { LogLevel } from "@/types";

export function LogsPage() {
  const { t } = useTranslation();
  const [application, setApplication] = useState("all");
  const [pod, setPod] = useState("all");
  const [level, setLevel] = useState<LogLevel | "all">("all");
  const [query, setQuery] = useState("");
  const [autoScroll, setAutoScroll] = useState(true);

  const podOptions = useMemo(() => Array.from(new Set(logs.map((entry) => entry.pod))), []);
  const filteredLogs = useMemo(
    () =>
      logs.filter((entry) => {
        const translatedMessage = t(entry.messageKey, entry.values).toLowerCase();
        const matchesApplication = application === "all" || entry.app === application;
        const matchesPod = pod === "all" || entry.pod === pod;
        const matchesLevel = level === "all" || entry.level === level;
        const matchesQuery = !query || translatedMessage.includes(query.toLowerCase()) || entry.pod.toLowerCase().includes(query.toLowerCase());
        return matchesApplication && matchesPod && matchesLevel && matchesQuery;
      }),
    [application, level, pod, query, t]
  );

  const handleCopy = () => {
    const content = filteredLogs
      .map((entry) => `${entry.timestamp} ${t(`logs.level.${entry.level}`)} ${entry.pod} ${t(entry.messageKey, entry.values)}`)
      .join("\n");
    void navigator.clipboard.writeText(content);
    toast.success(t("logs.copied"));
  };

  return (
    <div>
      <PageHeader
        actions={
          <Button variant="outline" onClick={handleCopy}>
            <Clipboard className="h-4 w-4" />
            {t("logs.copyLogs")}
          </Button>
        }
        description={t("logs.description")}
        title={t("logs.title")}
      />

      <Card className="mb-6">
        <CardContent className="grid gap-3 pt-5 lg:grid-cols-[180px_1fr_160px_1.2fr_auto]">
          <Select
            aria-label={t("logs.filters.app")}
            options={[{ value: "all", label: t("common.all") }, ...applications.map((item) => ({ value: item.name, label: item.name }))]}
            value={application}
            onChange={(event) => setApplication(event.target.value)}
          />
          <Select
            aria-label={t("logs.filters.pod")}
            options={[{ value: "all", label: t("common.all") }, ...podOptions.map((item) => ({ value: item, label: item }))]}
            value={pod}
            onChange={(event) => setPod(event.target.value)}
          />
          <Select
            aria-label={t("logs.filters.level")}
            options={[
              { value: "all", label: t("common.all") },
              { value: "info", label: t("logs.level.info") },
              { value: "warn", label: t("logs.level.warn") },
              { value: "error", label: t("logs.level.error") },
              { value: "debug", label: t("logs.level.debug") }
            ]}
            value={level}
            onChange={(event) => setLevel(event.target.value as LogLevel | "all")}
          />
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
            <Input className="pl-10" placeholder={t("logs.filters.search")} value={query} onChange={(event) => setQuery(event.target.value)} />
          </div>
          <label className="flex h-11 items-center gap-2 rounded-xl border border-white/10 bg-white/[0.045] px-3 text-sm text-slate-300">
            <input checked={autoScroll} className="accent-cyan-300" type="checkbox" onChange={(event) => setAutoScroll(event.target.checked)} />
            {t("logs.autoScroll")}
          </label>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("logs.terminalTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <TerminalLogs logs={filteredLogs} />
        </CardContent>
      </Card>
    </div>
  );
}
