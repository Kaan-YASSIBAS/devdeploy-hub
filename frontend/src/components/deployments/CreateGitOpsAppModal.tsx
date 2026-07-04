import { useEffect, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import type { GitOpsAppDeployInput } from "@/types";

type CreateGitOpsAppModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDeploy: (input: GitOpsAppDeployInput) => Promise<unknown>;
  isSubmitting: boolean;
};

const APP_NAME_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/;

export function CreateGitOpsAppModal({
  open,
  onOpenChange,
  onDeploy,
  isSubmitting
}: CreateGitOpsAppModalProps) {
  const { t } = useTranslation();
  const [appName, setAppName] = useState("");
  const [image, setImage] = useState("nginx:latest");
  const [replicas, setReplicas] = useState("1");
  const [containerPort, setContainerPort] = useState("80");
  const [servicePort, setServicePort] = useState("80");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      return;
    }

    setAppName("");
    setImage("nginx:latest");
    setReplicas("1");
    setContainerPort("80");
    setServicePort("80");
    setError(null);
  }, [open]);

  const validate = () => {
    const replicaCount = Number(replicas);
    const parsedContainerPort = Number(containerPort);
    const parsedServicePort = Number(servicePort);

    if (!appName.trim() || !image.trim()) {
      return t("deployments.gitopsDeploy.validation.required");
    }
    if (!APP_NAME_PATTERN.test(appName)) {
      return t("deployments.gitopsDeploy.validation.appName");
    }
    if (/\s/.test(image)) {
      return t("deployments.gitopsDeploy.validation.image");
    }
    if (!Number.isInteger(replicaCount) || replicaCount < 1 || replicaCount > 20) {
      return t("deployments.gitopsDeploy.validation.replicas");
    }
    if (!Number.isInteger(parsedContainerPort) || parsedContainerPort < 1 || parsedContainerPort > 65535) {
      return t("deployments.gitopsDeploy.validation.containerPort");
    }
    if (!Number.isInteger(parsedServicePort) || parsedServicePort < 1 || parsedServicePort > 65535) {
      return t("deployments.gitopsDeploy.validation.servicePort");
    }
    return null;
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const validationError = validate();
    if (validationError) {
      setError(validationError);
      return;
    }

    try {
      await onDeploy({
        app_name: appName,
        image: image.trim(),
        replicas: Number(replicas),
        container_port: Number(containerPort),
        service_port: Number(servicePort),
        service_type: "ClusterIP"
      });
      setError(null);
      onOpenChange(false);
    } catch {
      // The page owns API-specific error messaging.
    }
  };

  const setOpen = (nextOpen: boolean) => {
    if (!isSubmitting) {
      onOpenChange(nextOpen);
    }
  };

  return (
    <Dialog
      closeLabel={t("common.close")}
      description={t("deployments.gitopsDeploy.description")}
      open={open}
      title={t("deployments.gitopsDeploy.title")}
      onOpenChange={setOpen}
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="space-y-2">
          <Label htmlFor="gitops-app-name">{t("deployments.gitopsDeploy.appName")}</Label>
          <Input
            autoComplete="off"
            id="gitops-app-name"
            maxLength={40}
            placeholder={t("deployments.gitopsDeploy.appNamePlaceholder")}
            required
            value={appName}
            onChange={(event) => setAppName(event.target.value)}
          />
        </div>

        <div className="space-y-2">
          <Label htmlFor="gitops-app-image">{t("deployments.gitopsDeploy.image")}</Label>
          <Input
            autoComplete="off"
            id="gitops-app-image"
            placeholder={t("deployments.gitopsDeploy.imagePlaceholder")}
            required
            value={image}
            onChange={(event) => setImage(event.target.value)}
          />
        </div>

        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-2">
            <Label htmlFor="gitops-app-replicas">{t("deployments.gitopsDeploy.replicas")}</Label>
            <Input
              id="gitops-app-replicas"
              max={20}
              min={1}
              required
              type="number"
              value={replicas}
              onChange={(event) => setReplicas(event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="gitops-app-container-port">{t("deployments.gitopsDeploy.containerPort")}</Label>
            <Input
              id="gitops-app-container-port"
              max={65535}
              min={1}
              required
              type="number"
              value={containerPort}
              onChange={(event) => setContainerPort(event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="gitops-app-service-port">{t("deployments.gitopsDeploy.servicePort")}</Label>
            <Input
              id="gitops-app-service-port"
              max={65535}
              min={1}
              required
              type="number"
              value={servicePort}
              onChange={(event) => setServicePort(event.target.value)}
            />
          </div>
        </div>

        <div className="space-y-2">
          <Label htmlFor="gitops-app-service-type">{t("deployments.gitopsDeploy.serviceType")}</Label>
          <Select
            disabled
            id="gitops-app-service-type"
            options={[{ value: "ClusterIP", label: "ClusterIP" }]}
            value="ClusterIP"
          />
        </div>

        {error ? (
          <p className="rounded-lg border border-red-300/20 bg-red-500/10 px-3 py-2 text-sm text-red-200" role="alert">
            {error}
          </p>
        ) : null}

        <DialogFooter>
          <Button disabled={isSubmitting} variant="ghost" onClick={() => setOpen(false)}>
            {t("common.cancel")}
          </Button>
          <Button disabled={isSubmitting} type="submit">
            {isSubmitting ? t("deployments.gitopsDeploy.submitting") : t("deployments.gitopsDeploy.submit")}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
