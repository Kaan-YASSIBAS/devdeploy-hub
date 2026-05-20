import { Github, KeyRound, MonitorCog, PlugZap, Save, ShieldCheck, UserRound } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { PageHeader } from "@/components/layout/PageHeader";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { Badge } from "@/components/ui/badge";
import { mockUser } from "@/lib/mock-data";

const integrations = [
  { name: "GitHub", icon: Github, connected: true },
  { name: "Argo CD", icon: PlugZap, connected: true },
  { name: "Kubernetes", icon: ShieldCheck, connected: true },
  { name: "Grafana", icon: MonitorCog, connected: false }
];

export function SettingsPage() {
  const { t } = useTranslation();

  return (
    <div>
      <PageHeader
        actions={
          <Button>
            <Save className="h-4 w-4" />
            {t("common.save")}
          </Button>
        }
        description={t("settings.description")}
        title={t("settings.title")}
      />

      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader>
            <div className="flex items-center gap-3">
              <UserRound className="h-5 w-5 text-cyan-200" />
              <div>
                <CardTitle>{t("settings.profile.title")}</CardTitle>
                <CardDescription>{t("settings.profile.description")}</CardDescription>
              </div>
            </div>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="profile-name">{t("settings.profile.name")}</Label>
              <Input id="profile-name" defaultValue={mockUser.name} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="profile-email">{t("settings.profile.email")}</Label>
              <Input id="profile-email" defaultValue={mockUser.email} type="email" />
            </div>
            <div className="space-y-2">
              <Label htmlFor="profile-role">{t("settings.profile.role")}</Label>
              <Input id="profile-role" defaultValue={t("topbar.demoUser")} />
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("settings.organization.title")}</CardTitle>
            <CardDescription>{t("settings.organization.description")}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="organization-name">{t("settings.organization.name")}</Label>
              <Input id="organization-name" defaultValue={mockUser.organization} />
            </div>
            <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <p className="text-xs uppercase text-slate-500">{t("settings.organization.plan")}</p>
              <p className="mt-2 text-sm font-medium text-white">{t("settings.organization.planValue")}</p>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("settings.appearance.title")}</CardTitle>
            <CardDescription>{t("settings.appearance.description")}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex items-center justify-between rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <div>
                <p className="text-sm font-medium text-white">{t("settings.appearance.theme")}</p>
                <p className="text-xs text-slate-500">{t("settings.appearance.dark")}</p>
              </div>
              <StatusBadge status="healthy" type="health" />
            </div>
            <label className="flex items-center justify-between rounded-2xl border border-white/10 bg-white/[0.035] p-4 text-sm text-white">
              {t("settings.appearance.compactMode")}
              <input className="accent-cyan-300" type="checkbox" />
            </label>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <div className="flex items-center gap-3">
              <KeyRound className="h-5 w-5 text-cyan-200" />
              <div>
                <CardTitle>{t("settings.apiTokens.title")}</CardTitle>
                <CardDescription>{t("settings.apiTokens.description")}</CardDescription>
              </div>
            </div>
          </CardHeader>
          <CardContent className="space-y-3">
            {["deploy-readonly", "cluster-observer"].map((token) => (
              <div key={token} className="flex items-center justify-between rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <div>
                  <p className="font-mono text-sm text-white">{token}</p>
                  <p className="text-xs text-slate-500">{t("settings.apiTokens.lastUsed")}: 2026-05-20</p>
                </div>
                <Badge variant="muted">{t("common.active")}</Badge>
              </div>
            ))}
            <Button variant="outline">{t("settings.apiTokens.create")}</Button>
          </CardContent>
        </Card>

        <Card className="xl:col-span-2">
          <CardHeader>
            <CardTitle>{t("settings.integrations.title")}</CardTitle>
            <CardDescription>{t("settings.integrations.description")}</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            {integrations.map((integration) => (
              <div key={integration.name} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                <div className="flex items-center justify-between gap-3">
                  <integration.icon className="h-5 w-5 text-cyan-200" />
                  <Badge variant={integration.connected ? "success" : "muted"}>
                    {integration.connected ? t("settings.integrations.connected") : t("settings.integrations.mocked")}
                  </Badge>
                </div>
                <p className="mt-4 font-medium text-white">{integration.name}</p>
                <Button className="mt-4 w-full" variant="outline">
                  {t("settings.integrations.configure")}
                </Button>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
