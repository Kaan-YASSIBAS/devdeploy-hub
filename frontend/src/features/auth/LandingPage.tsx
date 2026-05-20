import { Activity, ArrowRight, Boxes, GitBranch, Rocket, ShieldCheck } from "lucide-react";
import { motion } from "framer-motion";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { LanguageSwitcher } from "@/components/layout/LanguageSwitcher";
import { EnvironmentBadge } from "@/components/shared/EnvironmentBadge";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { applications, deployments, techStack } from "@/lib/mock-data";

const featureIcons = {
  deployments: Rocket,
  gitops: GitBranch,
  kubernetes: Boxes,
  observability: Activity
};

export function LandingPage() {
  const { t } = useTranslation();
  const featureKeys = ["deployments", "gitops", "kubernetes", "observability"] as const;

  return (
    <div className="min-h-screen overflow-hidden">
      <div className="premium-grid absolute inset-0 opacity-35" />
      <header className="relative z-10 mx-auto flex max-w-7xl items-center justify-between px-4 py-5 sm:px-6 lg:px-8">
        <Link className="flex items-center gap-3" to="/">
          <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-cyan-300 text-slate-950 shadow-glow">
            <ShieldCheck className="h-5 w-5" />
          </div>
          <div>
            <p className="font-semibold text-white">{t("product.name")}</p>
            <p className="text-xs text-slate-500">{t("product.shortName")}</p>
          </div>
        </Link>
        <LanguageSwitcher />
      </header>

      <main className="relative z-10">
        <section className="mx-auto grid max-w-7xl gap-10 px-4 pb-16 pt-12 sm:px-6 md:pt-20 lg:grid-cols-[0.9fr_1.1fr] lg:px-8">
          <motion.div animate={{ opacity: 1, y: 0 }} className="flex flex-col justify-center" initial={{ opacity: 0, y: 14 }} transition={{ duration: 0.35 }}>
            <p className="mb-4 text-xs font-medium uppercase text-cyan-200">{t("landing.eyebrow")}</p>
            <h1 className="max-w-4xl whitespace-pre-line pb-2 text-[2.45rem] font-semibold leading-[1.22] text-gradient sm:text-[2.9rem] md:text-[3.2rem] lg:text-[3.45rem] xl:text-[3.9rem]">
              {t("landing.headline")}
            </h1>
            <p className="mt-6 max-w-2xl text-base leading-8 text-slate-300 sm:text-lg">{t("landing.subheadline")}</p>
            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <Button asChild className="group" size="lg">
                <Link to="/dashboard" onClick={() => localStorage.setItem("devdeploy-token", "demo-token")}>
                  {t("landing.openDashboard")}
                  <ArrowRight className="h-4 w-4 transition group-hover:translate-x-0.5" />
                </Link>
              </Button>
              <Button asChild size="lg" variant="outline">
                <Link to="/register">{t("landing.createAccount")}</Link>
              </Button>
            </div>
          </motion.div>

          <motion.div animate={{ opacity: 1, scale: 1 }} initial={{ opacity: 0, scale: 0.97 }} transition={{ delay: 0.08, duration: 0.4 }}>
            <Card className="overflow-hidden p-4">
              <div className="rounded-2xl border border-white/10 bg-slate-950/72 p-4">
                <div className="mb-5 flex flex-wrap items-start justify-between gap-4">
                  <div>
                    <p className="text-sm font-semibold text-white">{t("landing.previewTitle")}</p>
                    <p className="mt-1 text-sm leading-6 text-slate-400">{t("landing.previewSubtitle")}</p>
                  </div>
                  <StatusBadge status="healthy" type="health" />
                </div>
                <div className="grid gap-3 sm:grid-cols-3">
                  {applications.slice(0, 3).map((app) => (
                    <div key={app.id} className="rounded-2xl border border-white/10 bg-white/[0.04] p-4">
                      <p className="truncate text-sm font-medium text-white">{app.name}</p>
                      <div className="mt-3 flex items-center justify-between gap-2">
                        <EnvironmentBadge environment={app.environment} />
                        <span className="text-xs text-slate-500">{app.healthScore}%</span>
                      </div>
                    </div>
                  ))}
                </div>
                <div className="mt-4 rounded-2xl border border-white/10 bg-white/[0.035]">
                  {deployments.slice(0, 4).map((deployment) => (
                    <div key={deployment.id} className="grid grid-cols-[1fr_auto] gap-3 border-b border-white/[0.06] px-4 py-3 last:border-0">
                      <div className="min-w-0">
                        <p className="truncate text-sm text-white">{deployment.applicationName}</p>
                        <p className="text-xs text-slate-500">{deployment.imageTag}</p>
                      </div>
                      <StatusBadge status={deployment.status} type="deployment" />
                    </div>
                  ))}
                </div>
              </div>
            </Card>
          </motion.div>
        </section>

        <section className="mx-auto max-w-7xl px-4 pb-16 sm:px-6 lg:px-8">
          <div className="mb-7 max-w-3xl">
            <h2 className="text-2xl font-semibold text-white">{t("landing.featuresTitle")}</h2>
            <p className="mt-2 text-sm leading-6 text-slate-400">{t("landing.featuresSubtitle")}</p>
          </div>
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            {featureKeys.map((key) => {
              const Icon = featureIcons[key];
              return (
                <Card key={key} className="p-5 transition hover:-translate-y-0.5 hover:border-cyan-300/20">
                  <div className="mb-4 flex h-11 w-11 items-center justify-center rounded-2xl bg-cyan-300/10 text-cyan-200">
                    <Icon className="h-5 w-5" />
                  </div>
                  <h3 className="font-semibold text-white">{t(`landing.features.${key}.title`)}</h3>
                  <p className="mt-2 text-sm leading-6 text-slate-400">{t(`landing.features.${key}.description`)}</p>
                </Card>
              );
            })}
          </div>
        </section>

        <section className="mx-auto max-w-7xl px-4 pb-16 sm:px-6 lg:px-8">
          <Card className="p-5">
            <p className="mb-4 text-sm font-medium text-slate-300">{t("landing.stackTitle")}</p>
            <div className="flex flex-wrap gap-2">
              {techStack.map((item) => (
                <span key={item} className="rounded-full border border-white/10 bg-white/[0.045] px-3 py-2 text-sm text-slate-300">
                  {item}
                </span>
              ))}
            </div>
          </Card>
        </section>
      </main>

      <footer className="relative z-10 border-t border-white/10 px-4 py-6 sm:px-6 lg:px-8">
        <div className="mx-auto flex max-w-7xl flex-col justify-between gap-2 text-sm text-slate-500 sm:flex-row">
          <span>{t("landing.footerProduct")}</span>
          <span>{t("landing.footerTagline")}</span>
        </div>
      </footer>
    </div>
  );
}
