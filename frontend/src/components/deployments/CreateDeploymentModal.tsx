import { FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { applications, environments, mockUser } from "@/lib/mock-data";
import type { Deployment } from "@/types";

type CreateDeploymentModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreate: (deployment: Deployment) => void;
};

const strategies = ["rolling", "blueGreen", "canary"] as const;

export function CreateDeploymentModal({ open, onOpenChange, onCreate }: CreateDeploymentModalProps) {
  const { t } = useTranslation();

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    const applicationId = String(formData.get("application"));
    const application = applications.find((item) => item.id === applicationId) ?? applications[0];
    const deployment: Deployment = {
      id: `dep-${crypto.randomUUID().slice(0, 8)}`,
      applicationId: application.id,
      applicationName: application.name,
      environment: formData.get("environment") as Deployment["environment"],
      imageTag: String(formData.get("imageTag")),
      strategy: formData.get("strategy") as Deployment["strategy"],
      status: "pending",
      owner: mockUser.name,
      createdAt: new Date().toISOString().slice(0, 16).replace("T", " "),
      duration: "0m 00s",
      commit: crypto.randomUUID().slice(0, 7)
    };

    onCreate(deployment);
    toast.success(t("deployments.modal.success"));
    onOpenChange(false);
    event.currentTarget.reset();
  };

  return (
    <Dialog
      closeLabel={t("common.close")}
      description={t("deployments.modal.description")}
      open={open}
      title={t("deployments.modal.title")}
      onOpenChange={onOpenChange}
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="deployment-application">{t("deployments.modal.application")}</Label>
            <Select
              id="deployment-application"
              name="application"
              options={applications.map((application) => ({ value: application.id, label: application.name }))}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="deployment-environment">{t("deployments.modal.environment")}</Label>
            <Select
              id="deployment-environment"
              name="environment"
              options={environments.map((environment) => ({
                value: environment,
                label: t(`environment.${environment}`)
              }))}
            />
          </div>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="deployment-image-tag">{t("deployments.modal.imageTag")}</Label>
            <Input id="deployment-image-tag" name="imageTag" required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="deployment-replicas">{t("deployments.modal.replicas")}</Label>
            <Input id="deployment-replicas" min={1} name="replicas" required type="number" />
          </div>
        </div>
        <div className="space-y-2">
          <Label htmlFor="deployment-strategy">{t("deployments.modal.strategy")}</Label>
          <Select
            id="deployment-strategy"
            name="strategy"
            options={strategies.map((strategy) => ({ value: strategy, label: t(`strategy.${strategy}`) }))}
          />
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button type="submit">{t("deployments.modal.submit")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
