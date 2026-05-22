import { useEffect, useMemo, useState } from "react";
import {
  CheckCircle2,
  Copy,
  Github,
  KeyRound,
  LoaderCircle,
  MonitorCog,
  Plus,
  RefreshCw,
  Save,
  ShieldCheck,
  Trash2,
  UserRound,
  Workflow
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { getApiErrorMessage, settingsApi } from "@/api/client";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmptyState } from "@/components/shared/EmptyState";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { ApiToken, IntegrationStatus, IntegrationStatusItem } from "@/types";

const integrationIcons = {
  github: Github,
  argocd: Workflow,
  kubernetes: ShieldCheck,
  grafana: MonitorCog
} satisfies Record<IntegrationStatusItem["key"], typeof Github>;

function formatDate(value: string | null) {
  if (!value) {
    return "-";
  }

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function integrationVariant(status: IntegrationStatus) {
  if (status === "connected") {
    return "success";
  }

  if (status === "error") {
    return "danger";
  }

  return "muted";
}

function tokenDisplay(token: ApiToken) {
  return `${token.prefix}...${token.last_four}`;
}

export function SettingsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [profileName, setProfileName] = useState("");
  const [workspaceName, setWorkspaceName] = useState("");
  const [tokenModalOpen, setTokenModalOpen] = useState(false);
  const [tokenName, setTokenName] = useState("");
  const [createdToken, setCreatedToken] = useState<string | null>(null);

  const profileQuery = useQuery({ queryKey: ["settings", "profile"], queryFn: settingsApi.profile });
  const workspaceQuery = useQuery({ queryKey: ["settings", "workspace"], queryFn: settingsApi.workspace });
  const tokensQuery = useQuery({ queryKey: ["settings", "api-tokens"], queryFn: settingsApi.apiTokens });
  const integrationsQuery = useQuery({ queryKey: ["settings", "integrations"], queryFn: settingsApi.integrations });

  const isInitialLoading = profileQuery.isLoading || workspaceQuery.isLoading || tokensQuery.isLoading || integrationsQuery.isLoading;
  const hasError = profileQuery.isError || workspaceQuery.isError || tokensQuery.isError || integrationsQuery.isError;
  const apiTokens = useMemo(() => tokensQuery.data ?? [], [tokensQuery.data]);
  const integrations = useMemo(() => integrationsQuery.data ?? [], [integrationsQuery.data]);

  useEffect(() => {
    if (profileQuery.data) {
      setProfileName(profileQuery.data.display_name);
    }
  }, [profileQuery.data]);

  useEffect(() => {
    if (workspaceQuery.data) {
      setWorkspaceName(workspaceQuery.data.name);
    }
  }, [workspaceQuery.data]);

  const refreshSettings = async () => {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["settings", "profile"] }),
      queryClient.invalidateQueries({ queryKey: ["settings", "workspace"] }),
      queryClient.invalidateQueries({ queryKey: ["settings", "api-tokens"] }),
      queryClient.invalidateQueries({ queryKey: ["settings", "integrations"] })
    ]);
  };

  const profileMutation = useMutation({
    mutationFn: () => settingsApi.updateProfile({ display_name: profileName.trim() }),
    onSuccess: async () => {
      toast.success(t("settings.profile.saved"));
      await queryClient.invalidateQueries({ queryKey: ["settings", "profile"] });
    },
    onError: (error) => toast.error(getApiErrorMessage(error) || t("api.errors.settingsSaveFailed"))
  });

  const workspaceMutation = useMutation({
    mutationFn: () => settingsApi.updateWorkspace({ name: workspaceName.trim() }),
    onSuccess: async () => {
      toast.success(t("settings.workspace.saved"));
      await queryClient.invalidateQueries({ queryKey: ["settings", "workspace"] });
    },
    onError: (error) => toast.error(getApiErrorMessage(error) || t("api.errors.settingsSaveFailed"))
  });

  const createTokenMutation = useMutation({
    mutationFn: () => settingsApi.createApiToken({ name: tokenName.trim() }),
    onSuccess: async (response) => {
      setCreatedToken(response.token);
      toast.success(t("settings.apiTokens.created"));
      await queryClient.invalidateQueries({ queryKey: ["settings", "api-tokens"] });
    },
    onError: (error) => toast.error(getApiErrorMessage(error) || t("api.errors.apiTokenCreateFailed"))
  });

  const revokeTokenMutation = useMutation({
    mutationFn: (id: number) => settingsApi.revokeApiToken(id),
    onSuccess: async () => {
      toast.success(t("settings.apiTokens.revoked"));
      await queryClient.invalidateQueries({ queryKey: ["settings", "api-tokens"] });
    },
    onError: () => toast.error(t("api.errors.apiTokenRevokeFailed"))
  });

  const deleteTokenMutation = useMutation({
    mutationFn: (id: number) => settingsApi.deleteApiToken(id),
    onSuccess: async () => {
      toast.success(t("settings.apiTokens.deleted"));
      await queryClient.invalidateQueries({ queryKey: ["settings", "api-tokens"] });
    },
    onError: () => toast.error(t("api.errors.apiTokenDeleteFailed"))
  });

  const confirmRevokeToken = (token: ApiToken) => {
    if (window.confirm(t("settings.apiTokens.revokeConfirm", { name: token.name }))) {
      revokeTokenMutation.mutate(token.id);
    }
  };

  const confirmDeleteToken = (token: ApiToken) => {
    if (window.confirm(t("settings.apiTokens.deleteConfirm", { name: token.name }))) {
      deleteTokenMutation.mutate(token.id);
    }
  };

  const handleOpenTokenModal = () => {
    setTokenName("");
    setCreatedToken(null);
    setTokenModalOpen(true);
  };

  const handleCopyCreatedToken = async () => {
    if (!createdToken) {
      return;
    }
    await navigator.clipboard.writeText(createdToken);
    toast.success(t("settings.apiTokens.copied"));
  };

  if (isInitialLoading) {
    return (
      <div>
        <PageHeader description={t("settings.description")} title={t("settings.title")} />
        <Card>
          <CardContent className="flex min-h-[360px] items-center justify-center gap-3 text-sm text-slate-300">
            <LoaderCircle className="h-5 w-5 animate-spin text-cyan-200" />
            {t("settings.loading")}
          </CardContent>
        </Card>
      </div>
    );
  }

  if (hasError) {
    return (
      <div>
        <PageHeader description={t("settings.description")} title={t("settings.title")} />
        <EmptyState
          action={{ label: t("common.refresh"), onClick: () => void refreshSettings() }}
          description={t("settings.errorDescription")}
          title={t("settings.errorTitle")}
        />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        actions={
          <Button variant="outline" onClick={() => void refreshSettings()}>
            <RefreshCw className="h-4 w-4" />
            {t("common.refresh")}
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
              <Input id="profile-name" value={profileName} onChange={(event) => setProfileName(event.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="profile-email">{t("settings.profile.email")}</Label>
              <Input id="profile-email" readOnly type="email" value={profileQuery.data?.email ?? ""} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="profile-role">{t("settings.profile.role")}</Label>
              <Input id="profile-role" readOnly value={profileQuery.data?.role ?? ""} />
            </div>
            <Button disabled={!profileName.trim() || profileMutation.isPending} onClick={() => profileMutation.mutate()}>
              <Save className="h-4 w-4" />
              {t("settings.profile.save")}
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("settings.workspace.title")}</CardTitle>
            <CardDescription>{t("settings.workspace.description")}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="workspace-name">{t("settings.workspace.name")}</Label>
              <Input id="workspace-name" value={workspaceName} onChange={(event) => setWorkspaceName(event.target.value)} />
            </div>
            <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <p className="text-xs uppercase text-slate-500">{t("settings.workspace.plan")}</p>
              <p className="mt-2 text-sm font-medium text-white">{workspaceQuery.data?.plan ?? t("common.unavailable")}</p>
            </div>
            <Button disabled={!workspaceName.trim() || workspaceMutation.isPending} onClick={() => workspaceMutation.mutate()}>
              <Save className="h-4 w-4" />
              {t("settings.workspace.save")}
            </Button>
          </CardContent>
        </Card>

        <Card className="xl:col-span-2">
          <CardHeader>
            <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
              <div className="flex items-center gap-3">
                <KeyRound className="h-5 w-5 text-cyan-200" />
                <div>
                  <CardTitle>{t("settings.apiTokens.title")}</CardTitle>
                  <CardDescription>{t("settings.apiTokens.description")}</CardDescription>
                </div>
              </div>
              <Button onClick={handleOpenTokenModal}>
                <Plus className="h-4 w-4" />
                {t("settings.apiTokens.create")}
              </Button>
            </div>
          </CardHeader>
          <CardContent className="space-y-3">
            {apiTokens.length ? (
              apiTokens.map((token) => (
                <div key={token.id} className="flex flex-col gap-4 rounded-2xl border border-white/10 bg-white/[0.035] p-4 md:flex-row md:items-center md:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="font-medium text-white">{token.name}</p>
                      <Badge variant={token.active ? "success" : "muted"}>
                        {token.active ? t("common.active") : t("settings.apiTokens.revokedStatus")}
                      </Badge>
                    </div>
                    <p className="mt-1 font-mono text-xs text-slate-400">{tokenDisplay(token)}</p>
                    <p className="mt-1 text-xs text-slate-500">
                      {t("common.created")}: {formatDate(token.created_at)} · {t("settings.apiTokens.lastUsed")}: {formatDate(token.last_used_at)}
                    </p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {token.active ? (
                      <Button
                        disabled={revokeTokenMutation.isPending}
                        size="sm"
                        variant="outline"
                        onClick={() => confirmRevokeToken(token)}
                      >
                        <ShieldCheck className="h-4 w-4" />
                        {t("settings.apiTokens.revoke")}
                      </Button>
                    ) : null}
                    <Button
                      disabled={deleteTokenMutation.isPending}
                      size="sm"
                      variant="danger"
                      onClick={() => confirmDeleteToken(token)}
                    >
                      <Trash2 className="h-4 w-4" />
                      {t("settings.apiTokens.delete")}
                    </Button>
                  </div>
                </div>
              ))
            ) : (
              <div className="rounded-2xl border border-dashed border-white/12 bg-white/[0.025] p-6 text-sm text-slate-400">
                {t("settings.apiTokens.empty")}
              </div>
            )}
          </CardContent>
        </Card>

        <Card className="xl:col-span-2">
          <CardHeader>
            <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
              <div>
                <CardTitle>{t("settings.integrations.title")}</CardTitle>
                <CardDescription>{t("settings.integrations.description")}</CardDescription>
              </div>
              <Button variant="outline" onClick={() => void queryClient.invalidateQueries({ queryKey: ["settings", "integrations"] })}>
                <RefreshCw className="h-4 w-4" />
                {t("settings.integrations.refresh")}
              </Button>
            </div>
          </CardHeader>
          <CardContent className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            {integrations.map((integration) => {
              const Icon = integrationIcons[integration.key];
              return (
                <div key={integration.key} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
                  <div className="flex items-center justify-between gap-3">
                    <Icon className="h-5 w-5 text-cyan-200" />
                    <Badge variant={integrationVariant(integration.status)}>
                      {t(`settings.integrations.status.${integration.status}`)}
                    </Badge>
                  </div>
                  <p className="mt-4 font-medium text-white">{integration.name}</p>
                  <p className="mt-2 min-h-12 text-sm leading-6 text-slate-400">
                    {t(`settings.integrations.details.${integration.key}.${integration.status}`)}
                  </p>
                  <div className="mt-4 rounded-xl border border-white/10 bg-slate-950/40 p-3 text-xs text-slate-500">
                    {t("settings.integrations.configuredExternally")}
                  </div>
                </div>
              );
            })}
          </CardContent>
        </Card>
      </div>

      <Dialog
        closeLabel={t("common.close")}
        description={t("settings.apiTokens.createDescription")}
        open={tokenModalOpen}
        title={t("settings.apiTokens.createTitle")}
        onOpenChange={setTokenModalOpen}
      >
        <div className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="api-token-name">{t("settings.apiTokens.name")}</Label>
            <Input
              id="api-token-name"
              disabled={Boolean(createdToken)}
              placeholder={t("settings.apiTokens.namePlaceholder")}
              value={tokenName}
              onChange={(event) => setTokenName(event.target.value)}
            />
          </div>

          {createdToken ? (
            <div className="rounded-2xl border border-emerald-300/20 bg-emerald-400/10 p-4">
              <div className="flex items-center gap-2 text-sm font-medium text-emerald-100">
                <CheckCircle2 className="h-4 w-4" />
                {t("settings.apiTokens.createdOnce")}
              </div>
              <div className="mt-3 flex flex-col gap-2 sm:flex-row">
                <Input readOnly className="font-mono text-xs" value={createdToken} />
                <Button variant="outline" onClick={() => void handleCopyCreatedToken()}>
                  <Copy className="h-4 w-4" />
                  {t("common.copy")}
                </Button>
              </div>
              <p className="mt-3 text-xs leading-5 text-emerald-100/80">{t("settings.apiTokens.createdWarning")}</p>
            </div>
          ) : null}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setTokenModalOpen(false)}>
            {t("common.close")}
          </Button>
          {!createdToken ? (
            <Button disabled={!tokenName.trim() || createTokenMutation.isPending} onClick={() => createTokenMutation.mutate()}>
              {t("settings.apiTokens.create")}
            </Button>
          ) : null}
        </DialogFooter>
      </Dialog>
    </div>
  );
}
