import { Bell, LogOut, Menu, Search, UserCircle } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { LanguageSwitcher } from "@/components/layout/LanguageSwitcher";
import { useAuth } from "@/features/auth/useAuth";

type TopbarProps = {
  onMenuClick?: () => void;
};

export function Topbar({ onMenuClick }: TopbarProps) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { logout, user } = useAuth();

  const handleLogout = () => {
    logout();
    navigate("/login");
  };

  return (
    <header className="sticky top-0 z-30 border-b border-white/10 bg-slate-950/66 backdrop-blur-xl">
      <div className="flex h-20 items-center gap-3 px-4 lg:px-6">
        <Button aria-label={t("nav.main")} className="lg:hidden" size="icon" variant="ghost" onClick={onMenuClick}>
          <Menu className="h-5 w-5" />
        </Button>

        <div className="relative hidden flex-1 md:block">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
          <Input className="h-11 max-w-xl pl-10" placeholder={t("topbar.searchPlaceholder")} />
        </div>

        <div className="ml-auto flex items-center gap-2">
          <LanguageSwitcher compact />
          <Button aria-label={t("topbar.notifications")} size="icon" variant="outline">
            <Bell className="h-4 w-4" />
          </Button>
          <div className="hidden items-center gap-3 rounded-2xl border border-white/10 bg-white/[0.04] px-3 py-2 xl:flex">
            <UserCircle className="h-7 w-7 text-cyan-200" />
            <div>
              <p className="text-sm font-medium text-white">
                {user?.display_name || user?.username || t("topbar.profile")}
              </p>
              <p className="text-xs text-slate-500">{user?.role ?? t("topbar.demoUser")}</p>
            </div>
          </div>
          <Button aria-label={t("auth.logout")} size="icon" variant="outline" onClick={handleLogout}>
            <LogOut className="h-4 w-4" />
          </Button>
        </div>
      </div>
    </header>
  );
}
