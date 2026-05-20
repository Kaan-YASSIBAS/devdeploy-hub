import type { ReactNode } from "react";
import { ArrowUpRight } from "lucide-react";
import { Card } from "@/components/ui/card";
import { cn } from "@/lib/utils";

type StatCardProps = {
  label: string;
  value: string;
  detail: string;
  icon: ReactNode;
  tone?: "cyan" | "violet" | "emerald" | "amber" | "red";
};

const tones = {
  cyan: "from-cyan-300/18 text-cyan-200",
  violet: "from-violet-300/18 text-violet-200",
  emerald: "from-emerald-300/18 text-emerald-200",
  amber: "from-amber-300/18 text-amber-200",
  red: "from-red-300/18 text-red-200"
};

export function StatCard({ label, value, detail, icon, tone = "cyan" }: StatCardProps) {
  return (
    <Card className="group relative overflow-hidden p-5 transition hover:-translate-y-0.5 hover:border-white/20">
      <div className={cn("absolute inset-x-0 top-0 h-px bg-gradient-to-r to-transparent", tones[tone])} />
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-3">
          <p className="text-sm text-slate-400">{label}</p>
          <div className="text-2xl font-semibold text-white">{value}</div>
        </div>
        <div className={cn("flex h-11 w-11 items-center justify-center rounded-2xl bg-gradient-to-br to-white/[0.045]", tones[tone])}>
          {icon}
        </div>
      </div>
      <div className="mt-5 flex items-center gap-2 text-xs text-slate-500">
        <ArrowUpRight className="h-3.5 w-3.5 text-emerald-300" />
        <span>{detail}</span>
      </div>
    </Card>
  );
}
