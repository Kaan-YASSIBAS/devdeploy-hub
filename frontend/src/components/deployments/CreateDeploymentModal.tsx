import { FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import type { Application, DeploymentCreateInput, DeploymentStrategy, Environment } from "@/types";

type CreateDeploymentModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  applications: Application[];
  onCreate: (deployment: DeploymentCreateInput) => Promise<void> | void;
  isSubmitting?: boolean;
};

const environments: Environment[] = ["dev", "staging", "prod"];
const strategies: DeploymentStrategy[] = ["rolling", "recreate"];

export function CreateDeploymentModal({
  applications,
  open,
  onOpenChange,
  onCreate,
  isSubmitting = false
}: CreateDeploymentModalProps) {
  const { t } = useTranslation();

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const form = event.currentTarget;
    const formData = new FormData(form);
    const deployment: DeploymentCreateInput = {
      application_id: Number(formData.get("application_id")),
      environment: formData.get("environment") as Environment,
      image_tag: String(formData.get("image_tag")),
      replica_count: Number(formData.get("replica_count")),
      strategy: formData.get("strategy") as DeploymentStrategy
    };

    try {
      await onCreate(deployment);
      onOpenChange(false);
      form.reset();
    } catch {
      // Parent mutation owns translated error toast.
    }
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
              name="application_id"
              options={applications.map((application) => ({ value: String(application.id), label: application.name }))}
              required
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
            <Input id="deployment-image-tag" name="image_tag" placeholder={t("deployments.modal.imageTagPlaceholder")} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="deployment-replicas">{t("deployments.modal.replicas")}</Label>
            <Input id="deployment-replicas" defaultValue={2} min={1} name="replica_count" required type="number" />
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
          <Button disabled={isSubmitting} variant="ghost" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button disabled={isSubmitting || applications.length === 0} type="submit">
            {isSubmitting ? t("common.loading") : t("deployments.modal.submit")}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
