import * as React from "react";
import { cn } from "@/lib/utils";

type Tab = {
  value: string;
  label: string;
};

type TabsProps = {
  tabs: Tab[];
  value: string;
  onValueChange: (value: string) => void;
};

export function Tabs({ tabs, value, onValueChange }: TabsProps) {
  return (
    <div className="scrollbar-soft flex gap-2 overflow-x-auto rounded-2xl border border-white/10 bg-white/[0.035] p-1">
      {tabs.map((tab) => (
        <button
          key={tab.value}
          className={cn(
            "min-h-10 whitespace-nowrap rounded-xl px-3 text-sm font-medium text-slate-400 transition hover:text-white",
            value === tab.value && "bg-white/10 text-white shadow-sm"
          )}
          onClick={() => onValueChange(tab.value)}
          type="button"
        >
          {tab.label}
        </button>
      ))}
    </div>
  );
}
