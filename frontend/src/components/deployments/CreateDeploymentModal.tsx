import { FormEvent, useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import type { Application, GitOpsDeploymentCreateInput } from "@/types";

type CreateDeploymentModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  applications: Application[];
  onCreate: (deployment: GitOpsDeploymentCreateInput) => Promise<void> | void;
  isSubmitting?: boolean;
};

const defaultNamespace = "devdeploy-workloads";

function toImageRepository(application: Application | undefined) {
  if (!application) {
    return "";
  }

  return application.image_name.startsWith("ghcr.io/") ? application.image_name : `ghcr.io/kaan-yassibas/${application.slug}`;
}

export function CreateDeploymentModal({
  applications,
  open,
  onOpenChange,
  onCreate,
  isSubmitting = false
}: CreateDeploymentModalProps) {
  const { t } = useTranslation();
  const firstApplication = applications[0];
  const [applicationId, setApplicationId] = useState(firstApplication ? String(firstApplication.id) : "");
  const selectedApplication = useMemo(
    () => applications.find((application) => String(application.id) === applicationId),
    [applicationId, applications]
  );
  const [appName, setAppName] = useState(firstApplication?.slug ?? "");
  const [image, setImage] = useState(toImageRepository(firstApplication));
  const [tag, setTag] = useState("");
  const [namespace, setNamespace] = useState(defaultNamespace);
  const [containerPort, setContainerPort] = useState(firstApplication?.container_port ? String(firstApplication.container_port) : "8000");
  const [replicas, setReplicas] = useState("1");
  const [ingressHost, setIngressHost] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      return;
    }

    const application = applications.find((item) => String(item.id) === applicationId);
    if (application) {
      setAppName(application.slug);
      setImage(toImageRepository(application));
      setContainerPort(String(application.container_port));
    }
  }, [applicationId, applications, open]);

  const validate = () => {
    const port = Number(containerPort);
    const replicaCount = Number(replicas);

    if (!appName || !image || !tag || !namespace) {
      return t("deployments.gitops.validation.required");
    }

    if (tag.toLowerCase() === "latest") {
      return t("deployments.gitops.validation.latest");
    }

    if (!image.startsWith("ghcr.io/")) {
      return t("deployments.gitops.validation.registry");
    }

    if (!Number.isInteger(port) || port < 1024 || port > 65535) {
      return t("deployments.gitops.validation.port");
    }

    if (!Number.isInteger(replicaCount) || replicaCount < 1 || replicaCount > 5) {
      return t("deployments.gitops.validation.replicas");
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

    const deployment: GitOpsDeploymentCreateInput = {
      application_id: selectedApplication ? selectedApplication.id : null,
      app_name: appName,
      image,
      tag,
      namespace,
      container_port: Number(containerPort),
      replicas: Number(replicas),
      ingress_host: ingressHost || null
    };

    try {
      await onCreate(deployment);
      onOpenChange(false);
      setTag("");
      setIngressHost("");
      setError(null);
    } catch {
      // Parent mutation owns translated error toast.
    }
  };

  return (
    <Dialog
      closeLabel={t("common.close")}
      description={t("deployments.gitops.description")}
      open={open}
      title={t("deployments.gitops.title")}
      onOpenChange={onOpenChange}
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="space-y-2">
          <Label htmlFor="gitops-application">{t("deployments.gitops.application")}</Label>
          <Select
            id="gitops-application"
            options={[
              { value: "", label: t("deployments.gitops.manualApplication") },
              ...applications.map((application) => ({ value: String(application.id), label: application.name }))
            ]}
            value={applicationId}
            onChange={(event) => setApplicationId(event.target.value)}
          />
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="gitops-app-name">{t("deployments.gitops.appName")}</Label>
            <Input id="gitops-app-name" required value={appName} onChange={(event) => setAppName(event.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="gitops-namespace">{t("deployments.gitops.namespace")}</Label>
            <Input id="gitops-namespace" required value={namespace} onChange={(event) => setNamespace(event.target.value)} />
          </div>
        </div>

        <div className="space-y-2">
          <Label htmlFor="gitops-image">{t("deployments.gitops.image")}</Label>
          <Input
            id="gitops-image"
            placeholder={t("deployments.gitops.imagePlaceholder")}
            required
            value={image}
            onChange={(event) => setImage(event.target.value)}
          />
        </div>

        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-2">
            <Label htmlFor="gitops-tag">{t("deployments.gitops.tag")}</Label>
            <Input id="gitops-tag" placeholder={t("deployments.gitops.tagPlaceholder")} required value={tag} onChange={(event) => setTag(event.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="gitops-container-port">{t("deployments.gitops.containerPort")}</Label>
            <Input id="gitops-container-port" min={1024} max={65535} required type="number" value={containerPort} onChange={(event) => setContainerPort(event.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="gitops-replicas">{t("deployments.gitops.replicas")}</Label>
            <Input id="gitops-replicas" min={1} max={5} required type="number" value={replicas} onChange={(event) => setReplicas(event.target.value)} />
          </div>
        </div>

        <div className="space-y-2">
          <Label htmlFor="gitops-ingress">{t("deployments.gitops.ingressHost")}</Label>
          <Input
            id="gitops-ingress"
            placeholder={t("deployments.gitops.ingressPlaceholder")}
            value={ingressHost}
            onChange={(event) => setIngressHost(event.target.value)}
          />
        </div>

        {error ? <p className="rounded-xl border border-red-300/20 bg-red-500/10 px-3 py-2 text-sm text-red-200">{error}</p> : null}

        <DialogFooter>
          <Button disabled={isSubmitting} variant="ghost" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button disabled={isSubmitting} type="submit">
            {isSubmitting ? t("common.loading") : t("deployments.gitops.submit")}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
