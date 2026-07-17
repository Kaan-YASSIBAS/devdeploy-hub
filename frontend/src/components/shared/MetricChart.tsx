import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis
} from "recharts";
import { useId } from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

type ChartDatum = {
  time: string;
} & Record<string, string | number>;

type MetricChartProps = {
  title: string;
  description?: string;
  data: ChartDatum[];
  dataKey: string;
  label: string;
  color?: string;
  type?: "area" | "bar";
  emptyMessage?: string;
};

export function MetricChart({
  title,
  description,
  data,
  dataKey,
  label,
  color = "#22d3ee",
  type = "area",
  emptyMessage
}: MetricChartProps) {
  const gradientId = useId().replace(/:/g, "");

  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {description ? <CardDescription>{description}</CardDescription> : null}
      </CardHeader>
      <CardContent>
        <div className="relative h-72">
          <ResponsiveContainer width="100%" height="100%">
            {type === "bar" ? (
              <BarChart data={data}>
                <CartesianGrid stroke="rgba(148, 163, 184, 0.12)" vertical={false} />
                <XAxis dataKey="time" stroke="#64748b" tickLine={false} axisLine={false} />
                <YAxis stroke="#64748b" tickLine={false} axisLine={false} />
                <Tooltip
                  cursor={{ fill: "rgba(255,255,255,0.04)" }}
                  contentStyle={{
                    background: "rgba(15, 23, 42, 0.92)",
                    border: "1px solid rgba(255,255,255,0.12)",
                    borderRadius: "14px",
                    color: "#e2e8f0"
                  }}
                />
                <Bar dataKey={dataKey} name={label} fill={color} radius={[8, 8, 2, 2]} />
              </BarChart>
            ) : (
              <AreaChart data={data}>
                <defs>
                  <linearGradient id={`${dataKey}Gradient${gradientId}`} x1="0" x2="0" y1="0" y2="1">
                    <stop offset="5%" stopColor={color} stopOpacity={0.42} />
                    <stop offset="95%" stopColor={color} stopOpacity={0.02} />
                  </linearGradient>
                </defs>
                <CartesianGrid stroke="rgba(148, 163, 184, 0.12)" vertical={false} />
                <XAxis dataKey="time" stroke="#64748b" tickLine={false} axisLine={false} />
                <YAxis stroke="#64748b" tickLine={false} axisLine={false} />
                <Tooltip
                  contentStyle={{
                    background: "rgba(15, 23, 42, 0.92)",
                    border: "1px solid rgba(255,255,255,0.12)",
                    borderRadius: "14px",
                    color: "#e2e8f0"
                  }}
                />
                <Area
                  type="monotone"
                  dataKey={dataKey}
                  name={label}
                  stroke={color}
                  strokeWidth={2}
                  fill={`url(#${dataKey}Gradient${gradientId})`}
                />
              </AreaChart>
            )}
          </ResponsiveContainer>
          {!data.length && emptyMessage ? (
            <div className="pointer-events-none absolute inset-0 flex items-center justify-center px-6 text-center text-sm text-slate-400">
              {emptyMessage}
            </div>
          ) : null}
        </div>
      </CardContent>
    </Card>
  );
}
