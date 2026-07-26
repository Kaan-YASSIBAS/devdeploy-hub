import {
  Activity,
  Boxes,
  Gauge,
  LayoutDashboard,
  Rocket,
  ScrollText,
  Settings,
  ShipWheel
} from "lucide-react";
import { NavLink } from "react-router";
import { useTranslation } from "react-i18next";
import { cn } from "@/lib/utils";

const groups = [
  {
    labelKey: "nav.main",
    items: [{ labelKey: "nav.dashboard", path: "/dashboard", icon: LayoutDashboard }]
  },
  {
    labelKey: "nav.platform",
    items: [
      { labelKey: "nav.applications", path: "/applications", icon: Boxes },
      { labelKey: "nav.deployments", path: "/deployments", icon: Rocket },
      { labelKey: "nav.cluster", path: "/cluster", icon: ShipWheel }
    ]
  },
  {
    labelKey: "nav.operations",
    items: [
      { labelKey: "nav.logs", path: "/logs", icon: ScrollText },
      { labelKey: "nav.monitoring", path: "/monitoring", icon: Activity },
      { labelKey: "nav.settings", path: "/settings", icon: Settings }
    ]
  }
];

type SidebarProps = {
  mobile?: boolean;
  onNavigate?: () => void;
};

export function Sidebar({ mobile = false, onNavigate }: SidebarProps) {
  const { t } = useTranslation();

  return (
    <aside
      className={cn(
        mobile
          ? "block h-full w-full"
          : "fixed inset-y-0 left-0 z-40 hidden w-72 border-r border-white/10 bg-slate-950/76 backdrop-blur-xl lg:block"
      )}
    >
      <div className="flex h-full flex-col">
        <div className="flex h-20 items-center gap-3 px-5">
          <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-cyan-300 text-slate-950 shadow-glow">
            <Gauge className="h-5 w-5" />
          </div>
          <div>
            <p className="font-semibold text-white">{t("product.name")}</p>
            <p className="text-xs text-slate-500">{t("product.shortName")}</p>
          </div>
        </div>

        <nav className="scrollbar-soft flex-1 space-y-7 overflow-y-auto px-3 pb-6">
          {groups.map((group) => (
            <div key={group.labelKey}>
              <p className="mb-2 px-3 text-xs font-medium uppercase text-slate-600">{t(group.labelKey)}</p>
              <div className="space-y-1">
                {group.items.map((item) => (
                  <NavLink
                    key={item.path}
                    className={({ isActive }) =>
                      cn(
                        "flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium text-slate-400 transition hover:bg-white/[0.06] hover:text-white",
                        isActive && "bg-cyan-300/10 text-cyan-100 ring-1 ring-cyan-300/20"
                      )
                    }
                    onClick={onNavigate}
                    to={item.path}
                  >
                    <item.icon className="h-4 w-4" />
                    <span>{t(item.labelKey)}</span>
                  </NavLink>
                ))}
              </div>
            </div>
          ))}
        </nav>
      </div>
    </aside>
  );
}
