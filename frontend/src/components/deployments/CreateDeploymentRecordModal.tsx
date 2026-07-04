import { useEffect, useMemo, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import type { DeploymentRecordCreateInput, ServiceDefinition } from "@/types";

type CreateDeploymentRecordModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreate: (input: DeploymentRecordCreateInput) => Promise<unknown>;
  services: ServiceDefinition[];
  isSubmitting: boolean;
};

const APP_NAME_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/;
const NAMESPACE_PATTERN = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;

function toAppName(value: string) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)
    .replace(/-+$/g, "");
}

export function CreateDeploymentRecordModal({
  open,
  onOpenChange,
  onCreate,
  services,
  isSubmitting
}: CreateDeploymentRecordModalProps) {
  const { t } = useTranslation();
  const [serviceId, setServiceId] = useState("");
  const [appName, setAppName] = useState("");
  const [image, setImage] = useState("");
  const [replicas, setReplicas] = useState("1");
  const [containerPort, setContainerPort] = useState("80");
  const [servicePort, setServicePort] = useState("80");
  const [namespace, setNamespace] = useState("devdeploy-apps");
  const [error, setError] = useState<string | null>(null);
  const selectedService = useMemo(
    () => services.find((service) => String(service.id) === serviceId),
    [serviceId, services]
  );

  useEffect(() => {
    if (!open) {
      return;
    }
    setServiceId("");
    setAppName("");
    setImage("");
    setReplicas("1");
    setContainerPort("80");
    setServicePort("80");
    setNamespace("devdeploy-apps");
    setError(null);
  }, [open]);

  useEffect(() => {
    if (!selectedService) {
      return;
    }
    setAppName(toAppName(selectedService.name));
    setImage(selectedService.default_image ?? "");
    setReplicas(String(selectedService.default_replicas));
    setContainerPort(String(selectedService.default_port ?? 80));
  }, [selectedService]);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const replicaCount = Number(replicas);
    const parsedContainerPort = Number(containerPort);
    const parsedServicePort = Number(servicePort);
    if (!APP_NAME_PATTERN.test(appName)) {
      setError(t("deployments.records.validation.appName"));
      return;
    }
    if (!image.trim() || /\s/.test(image)) {
      setError(t("deployments.records.validation.image"));
      return;
    }
    if (!NAMESPACE_PATTERN.test(namespace) || namespace.length > 63) {
      setError(t("deployments.records.validation.namespace"));
      return;
    }
    if (!Number.isInteger(replicaCount) || replicaCount < 1 || replicaCount > 20) {
      setError(t("deployments.records.validation.replicas"));
      return;
    }
    if (!Number.isInteger(parsedContainerPort) || parsedContainerPort < 1 || parsedContainerPort > 65535) {
      setError(t("deployments.records.validation.containerPort"));
      return;
    }
    if (!Number.isInteger(parsedServicePort) || parsedServicePort < 1 || parsedServicePort > 65535) {
      setError(t("deployments.records.validation.servicePort"));
      return;
    }

    try {
      await onCreate({
        service_definition_id: serviceId ? Number(serviceId) : null,
        app_name: appName,
        image: image.trim(),
        replicas: replicaCount,
        container_port: parsedContainerPort,
        service_port: parsedServicePort,
        service_type: "ClusterIP",
        namespace,
        desired_state: "draft"
      });
      onOpenChange(false);
    } catch {
      // The page owns API-specific error messaging.
    }
  };

  return (
    <Dialog
      closeLabel={t("common.close")}
      description={t("deployments.records.createDescription")}
      open={open}
      title={t("deployments.records.createTitle")}
      onOpenChange={(nextOpen) => !isSubmitting && onOpenChange(nextOpen)}
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <p className="rounded-lg border border-amber-300/20 bg-amber-400/10 px-3 py-2 text-sm text-amber-100">
          {t("deployments.records.noDeployNotice")}
        </p>
        <div className="space-y-2">
          <Label htmlFor="deployment-record-service">{t("deployments.records.fields.service")}</Label>
          <Select
            id="deployment-record-service"
            options={[
              { value: "", label: t("deployments.records.noService") },
              ...services.map((service) => ({ value: String(service.id), label: service.name }))
            ]}
            value={serviceId}
            onChange={(event) => setServiceId(event.target.value)}
          />
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="deployment-record-app-name">{t("deployments.records.fields.appName")}</Label>
            <Input
              autoComplete="off"
              id="deployment-record-app-name"
              maxLength={40}
              required
              value={appName}
              onChange={(event) => setAppName(event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="deployment-record-namespace">{t("deployments.records.fields.namespace")}</Label>
            <Input
              id="deployment-record-namespace"
              maxLength={63}
              required
              value={namespace}
              onChange={(event) => setNamespace(event.target.value)}
            />
          </div>
        </div>
        <div className="space-y-2">
          <Label htmlFor="deployment-record-image">{t("deployments.records.fields.image")}</Label>
          <Input
            autoComplete="off"
            id="deployment-record-image"
            maxLength={512}
            required
            value={image}
            onChange={(event) => setImage(event.target.value)}
          />
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-2">
            <Label htmlFor="deployment-record-replicas">{t("deployments.records.fields.replicas")}</Label>
            <Input id="deployment-record-replicas" max={20} min={1} required type="number" value={replicas} onChange={(event) => setReplicas(event.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="deployment-record-container-port">{t("deployments.records.fields.containerPort")}</Label>
            <Input id="deployment-record-container-port" max={65535} min={1} required type="number" value={containerPort} onChange={(event) => setContainerPort(event.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="deployment-record-service-port">{t("deployments.records.fields.servicePort")}</Label>
            <Input id="deployment-record-service-port" max={65535} min={1} required type="number" value={servicePort} onChange={(event) => setServicePort(event.target.value)} />
          </div>
        </div>
        <div className="space-y-2">
          <Label htmlFor="deployment-record-service-type">{t("deployments.records.fields.serviceType")}</Label>
          <Select disabled id="deployment-record-service-type" options={[{ value: "ClusterIP", label: "ClusterIP" }]} value="ClusterIP" />
        </div>
        {error ? (
          <p className="rounded-lg border border-red-300/20 bg-red-500/10 px-3 py-2 text-sm text-red-200" role="alert">
            {error}
          </p>
        ) : null}
        <DialogFooter>
          <Button disabled={isSubmitting} variant="ghost" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button disabled={isSubmitting} type="submit">
            {isSubmitting ? t("common.loading") : t("deployments.records.createAction")}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
