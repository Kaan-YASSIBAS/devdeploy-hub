import { Languages } from "lucide-react";
import { useTranslation } from "react-i18next";
import { supportedLanguages, type SupportedLanguage } from "@/i18n";
import { Select } from "@/components/ui/select";
import { cn } from "@/lib/utils";

type LanguageSwitcherProps = {
  compact?: boolean;
  className?: string;
};

export function LanguageSwitcher({ compact = false, className }: LanguageSwitcherProps) {
  const { i18n, t } = useTranslation();
  const currentLanguage = i18n.resolvedLanguage?.startsWith("tr") ? "tr" : "en";

  const handleChange = (language: string) => {
    localStorage.setItem("devdeploy-language", language);
    void i18n.changeLanguage(language as SupportedLanguage);
  };

  return (
    <div className={cn("flex items-center gap-2", className)}>
      <div className="hidden h-10 w-10 items-center justify-center rounded-xl border border-white/10 bg-white/[0.04] text-slate-300 sm:flex">
        <Languages className="h-4 w-4" />
      </div>
      <Select
        aria-label={t("language.label")}
        className={cn(compact ? "w-[84px]" : "w-[150px]")}
        options={supportedLanguages.map((language) => ({
          value: language.code,
          label: compact ? language.shortLabel : t(language.labelKey)
        }))}
        value={currentLanguage}
        onChange={(event) => handleChange(event.target.value)}
      />
    </div>
  );
}
