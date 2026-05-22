import { useTranslation } from "react-i18next";
import { Badge } from "@/components/ui/badge";
import type { Environment, PlatformEnvironment } from "@/types";

const variantMap = {
  production: "danger",
  staging: "warning",
  development: "info",
  prod: "danger",
  dev: "info",
  release: "success",
  cluster: "muted"
} as const;

export function EnvironmentBadge({ environment }: { environment: Environment | PlatformEnvironment | string }) {
  const { t } = useTranslation();
  const variant = environment in variantMap ? variantMap[environment as keyof typeof variantMap] : "muted";
  return <Badge variant={variant}>{t(`environment.${environment}`, { defaultValue: environment })}</Badge>;
}
