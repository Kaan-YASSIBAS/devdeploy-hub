import { useTranslation } from "react-i18next";
import { Badge } from "@/components/ui/badge";
import type { DeploymentStatus, HealthStatus, LogLevel } from "@/types";

type Props =
  | { type: "deployment"; status: DeploymentStatus }
  | { type: "health"; status: HealthStatus }
  | { type: "log"; status: LogLevel };

const variantMap = {
  pending: "warning",
  running: "info",
  progressing: "warning",
  success: "success",
  failed: "danger",
  unknown: "muted",
  healthy: "success",
  degraded: "warning",
  critical: "danger",
  info: "info",
  warn: "warning",
  error: "danger",
  debug: "muted"
} as const;

export function StatusBadge(props: Props) {
  const { t } = useTranslation();
  const label =
    props.type === "deployment"
      ? t(`status.${props.status}`)
      : props.type === "health"
        ? t(`health.${props.status}`)
        : t(`logs.level.${props.status}`);

  return <Badge variant={variantMap[props.status]}>{label}</Badge>;
}
