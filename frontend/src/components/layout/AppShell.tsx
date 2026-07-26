import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Outlet } from "react-router";
import { X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Sidebar } from "@/components/layout/Sidebar";
import { Topbar } from "@/components/layout/Topbar";
import { PlatformClusterHealthBanner } from "@/components/layout/PlatformClusterHealthBanner";
import { Button } from "@/components/ui/button";

export function AppShell() {
  const { t } = useTranslation();
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <div className="min-h-screen">
      <Sidebar />
      <AnimatePresence>
        {mobileOpen ? (
          <motion.div animate={{ opacity: 1 }} className="fixed inset-0 z-50 lg:hidden" exit={{ opacity: 0 }} initial={{ opacity: 0 }}>
            <button className="absolute inset-0 bg-slate-950/80 backdrop-blur-sm" onClick={() => setMobileOpen(false)} />
            <motion.div
              animate={{ x: 0 }}
              className="absolute inset-y-0 left-0 w-80 max-w-[86vw] border-r border-white/10 bg-slate-950 p-4"
              exit={{ x: "-100%" }}
              initial={{ x: "-100%" }}
              transition={{ duration: 0.22 }}
            >
              <div className="mb-4 flex justify-end">
                <Button aria-label={t("common.close")} size="icon" variant="ghost" onClick={() => setMobileOpen(false)}>
                  <X className="h-5 w-5" />
                </Button>
              </div>
              <Sidebar mobile onNavigate={() => setMobileOpen(false)} />
            </motion.div>
          </motion.div>
        ) : null}
      </AnimatePresence>

      <div className="lg:pl-72">
        <Topbar onMenuClick={() => setMobileOpen(true)} />
        <main className="px-4 py-6 lg:px-6">
          <PlatformClusterHealthBanner />
          <motion.div animate={{ opacity: 1, y: 0 }} initial={{ opacity: 0, y: 8 }} transition={{ duration: 0.24 }}>
            <Outlet />
          </motion.div>
        </main>
      </div>
    </div>
  );
}
