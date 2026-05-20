import { useTranslation } from "react-i18next";
import { Badge } from "@/components/ui/badge";
import type { Environment } from "@/types";

const variantMap = {
  production: "danger",
  staging: "warning",
  development: "info"
} as const;

export function EnvironmentBadge({ environment }: { environment: Environment }) {
  const { t } = useTranslation();
  return <Badge variant={variantMap[environment]}>{t(`environment.${environment}`)}</Badge>;
}
