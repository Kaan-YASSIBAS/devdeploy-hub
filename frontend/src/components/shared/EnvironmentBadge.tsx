import { useTranslation } from "react-i18next";
import { Badge } from "@/components/ui/badge";
import type { Environment, PlatformEnvironment } from "@/types";

const variantMap = {
  production: "danger",
  staging: "warning",
  development: "info",
  prod: "danger",
  dev: "info"
} as const;

export function EnvironmentBadge({ environment }: { environment: Environment | PlatformEnvironment }) {
  const { t } = useTranslation();
  return <Badge variant={variantMap[environment]}>{t(`environment.${environment}`)}</Badge>;
}
