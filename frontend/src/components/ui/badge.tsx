import * as React from "react";
import { cn } from "@/lib/utils";

type BadgeVariant = "default" | "success" | "warning" | "danger" | "info" | "muted";

const variants: Record<BadgeVariant, string> = {
  default: "border-white/10 bg-white/[0.06] text-slate-200",
  success: "border-emerald-300/20 bg-emerald-400/10 text-emerald-200",
  warning: "border-amber-300/20 bg-amber-400/10 text-amber-200",
  danger: "border-red-300/20 bg-red-400/10 text-red-200",
  info: "border-cyan-300/20 bg-cyan-400/10 text-cyan-200",
  muted: "border-slate-300/10 bg-slate-500/10 text-slate-300"
};

export type BadgeProps = React.HTMLAttributes<HTMLSpanElement> & {
  variant?: BadgeVariant;
};

export function Badge({ className, variant = "default", ...props }: BadgeProps) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-medium",
        variants[variant],
        className
      )}
      {...props}
    />
  );
}
