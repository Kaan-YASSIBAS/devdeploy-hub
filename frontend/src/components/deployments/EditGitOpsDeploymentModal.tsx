import { useEffect, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { GitOpsOperationTimeline } from "@/components/deployments/GitOpsOperationTimeline";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { normalizePreviewPath } from "@/lib/preview-path";
import type { DeploymentRecord, DeploymentRecordGitOpsUpdateInput } from "@/types";

type EditGitOpsDeploymentModalProps = {
  deployment: DeploymentRecord | null;
  open: boolean;
  isSubmitting: boolean;
  onOpenChange: (open: boolean) => void;
  onUpdate: (deployment: DeploymentRecord, input: DeploymentRecordGitOpsUpdateInput) => Promise<unknown>;
};

function changedPayload(
  deployment: DeploymentRecord,
  values: {
    image: string;
    replicas: number;
    container_port: number;
    service_port: number;
    preview_path: string;
  }
): DeploymentRecordGitOpsUpdateInput {
  const payload: DeploymentRecordGitOpsUpdateInput = {};
  if (values.image !== deployment.image) payload.image = values.image;
  if (values.replicas !== deployment.replicas) payload.replicas = values.replicas;
  if (values.container_port !== deployment.container_port) payload.container_port = values.container_port;
  if (values.service_port !== deployment.service_port) payload.service_port = values.service_port;
  if (values.preview_path !== deployment.preview_path) payload.preview_path = values.preview_path;
  return payload;
}

export function EditGitOpsDeploymentModal({
  deployment,
  open,
  isSubmitting,
  onOpenChange,
  onUpdate
}: EditGitOpsDeploymentModalProps) {
  const { t } = useTranslation();
  const [image, setImage] = useState("");
  const [replicas, setReplicas] = useState("1");
  const [containerPort, setContainerPort] = useState("80");
  const [servicePort, setServicePort] = useState("80");
  const [previewPath, setPreviewPath] = useState("/");
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    if (!open || !deployment) return;
    setImage(deployment.image);
    setReplicas(String(deployment.replicas));
    setContainerPort(String(deployment.container_port));
    setServicePort(String(deployment.service_port));
    setPreviewPath(deployment.preview_path || "/");
    setMessage(null);
  }, [deployment, open]);

  const validate = () => {
    const replicaCount = Number(replicas);
    const parsedContainerPort = Number(containerPort);
    const parsedServicePort = Number(servicePort);

    if (!image.trim()) {
      return t("deployments.records.update.validation.required");
    }
    if (/\s/.test(image.trim())) {
      return t("deployments.records.update.validation.image");
    }
    if (!Number.isInteger(replicaCount) || replicaCount < 1 || replicaCount > 20) {
      return t("deployments.records.update.validation.replicas");
    }
    if (!Number.isInteger(parsedContainerPort) || parsedContainerPort < 1 || parsedContainerPort > 65535) {
      return t("deployments.records.update.validation.containerPort");
    }
    if (!Number.isInteger(parsedServicePort) || parsedServicePort < 1 || parsedServicePort > 65535) {
      return t("deployments.records.update.validation.servicePort");
    }
    if (normalizePreviewPath(previewPath) === null) {
      return t("deployments.records.update.validation.previewPath");
    }
    return null;
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!deployment) return;

    const validationError = validate();
    if (validationError) {
      setMessage(validationError);
      return;
    }

    const normalizedPreviewPath = normalizePreviewPath(previewPath) ?? "/";
    const payload = changedPayload(deployment, {
      image: image.trim(),
      replicas: Number(replicas),
      container_port: Number(containerPort),
      service_port: Number(servicePort),
      preview_path: normalizedPreviewPath
    });

    if (Object.keys(payload).length === 0) {
      setMessage(t("deployments.records.update.noChanges"));
      return;
    }

    try {
      await onUpdate(deployment, payload);
      setMessage(null);
    } catch {
      // The page owns API-specific error messaging.
    }
  };

  const setOpen = (nextOpen: boolean) => {
    if (!isSubmitting) onOpenChange(nextOpen);
  };

  return (
    <Dialog
      closeLabel={t("common.close")}
      description={deployment ? t("deployments.records.update.description", { name: deployment.app_name }) : undefined}
      open={open}
      title={t("deployments.records.update.title")}
      onOpenChange={setOpen}
    >
      {deployment ? (
        <form className="space-y-4" onSubmit={handleSubmit}>
          <div className="space-y-2">
            <Label htmlFor="edit-deployment-image">{t("deployments.gitopsDeploy.image")}</Label>
            <Input
              autoComplete="off"
              id="edit-deployment-image"
              required
              value={image}
              onChange={(event) => setImage(event.target.value)}
            />
          </div>

          <div className="grid gap-4 sm:grid-cols-3">
            <div className="space-y-2">
              <Label htmlFor="edit-deployment-replicas">{t("deployments.gitopsDeploy.replicas")}</Label>
              <Input
                id="edit-deployment-replicas"
                max={20}
                min={1}
                required
                type="number"
                value={replicas}
                onChange={(event) => setReplicas(event.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="edit-deployment-container-port">{t("deployments.gitopsDeploy.containerPort")}</Label>
              <Input
                id="edit-deployment-container-port"
                max={65535}
                min={1}
                required
                type="number"
                value={containerPort}
                onChange={(event) => setContainerPort(event.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="edit-deployment-service-port">{t("deployments.gitopsDeploy.servicePort")}</Label>
              <Input
                id="edit-deployment-service-port"
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
            <Label htmlFor="edit-deployment-preview-path">
              {t("deployments.gitopsDeploy.previewPath")}{" "}
              <span className="normal-case text-slate-500">({t("common.optional")})</span>
            </Label>
            <Input
              autoComplete="off"
              id="edit-deployment-preview-path"
              placeholder={t("deployments.gitopsDeploy.previewPathPlaceholder")}
              value={previewPath}
              onChange={(event) => setPreviewPath(event.target.value)}
            />
            <p className="text-xs leading-5 text-slate-500">
              {t("deployments.gitopsDeploy.previewPathHelper")}
            </p>
          </div>

          {message ? (
            <p className="rounded-lg border border-amber-300/20 bg-amber-500/10 px-3 py-2 text-sm text-amber-100" role="alert">
              {message}
            </p>
          ) : null}

          {isSubmitting ? <GitOpsOperationTimeline activeStep={1} kind="update" /> : null}

          <DialogFooter>
            <Button disabled={isSubmitting} variant="ghost" onClick={() => setOpen(false)}>
              {t("common.cancel")}
            </Button>
            <Button disabled={isSubmitting} type="submit">
              {isSubmitting ? t("deployments.records.update.submitting") : t("deployments.records.update.confirmAction")}
            </Button>
          </DialogFooter>
        </form>
      ) : null}
    </Dialog>
  );
}
