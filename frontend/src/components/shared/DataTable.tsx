import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

export type Column<T> = {
  key: string;
  header: string;
  className?: string;
  render: (row: T) => ReactNode;
};

type DataTableProps<T> = {
  columns: Column<T>[];
  data: T[];
  getRowKey: (row: T) => string;
  emptyState?: ReactNode;
};

export function DataTable<T>({ columns, data, getRowKey, emptyState }: DataTableProps<T>) {
  if (!data.length) {
    return <>{emptyState}</>;
  }

  return (
    <div className="scrollbar-soft overflow-x-auto">
      <table className="w-full min-w-[760px] border-separate border-spacing-0 text-left text-sm">
        <thead>
          <tr className="text-xs uppercase text-slate-500">
            {columns.map((column) => (
              <th key={column.key} className={cn("border-b border-white/10 px-4 py-3 font-medium", column.className)}>
                {column.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.map((row) => (
            <tr key={getRowKey(row)} className="group transition hover:bg-white/[0.035]">
              {columns.map((column) => (
                <td key={column.key} className={cn("border-b border-white/[0.06] px-4 py-4 text-slate-300", column.className)}>
                  {column.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
