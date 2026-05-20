import { Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";

export function RouteLoader() {
  const { t } = useTranslation();

  return (
    <div className="flex min-h-[320px] items-center justify-center">
      <div className="flex items-center gap-3 rounded-2xl border border-white/10 bg-white/[0.045] px-4 py-3 text-sm text-slate-300">
        <Loader2 className="h-4 w-4 animate-spin text-cyan-200" />
        {t("common.loading")}
      </div>
    </div>
  );
}
