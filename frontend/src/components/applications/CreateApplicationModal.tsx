import { FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { environments } from "@/lib/mock-data";
import type { Application } from "@/types";

type CreateApplicationModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreate: (application: Application) => void;
};

export function CreateApplicationModal({ open, onOpenChange, onCreate }: CreateApplicationModalProps) {
  const { t } = useTranslation();

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    const application: Application = {
      id: `app-${crypto.randomUUID()}`,
      name: String(formData.get("name")),
      image: String(formData.get("image")),
      environment: formData.get("environment") as Application["environment"],
      owner: String(formData.get("owner")),
      repository: String(formData.get("repository")),
      namespace: String(formData.get("namespace")),
      replicas: Number(formData.get("replicas")),
      lastDeployment: new Date().toISOString().slice(0, 16).replace("T", " "),
      health: "healthy",
      healthScore: 100
    };

    onCreate(application);
    toast.success(t("applications.modal.success"));
    onOpenChange(false);
    event.currentTarget.reset();
  };

  return (
    <Dialog
      closeLabel={t("common.close")}
      description={t("applications.modal.description")}
      open={open}
      title={t("applications.modal.title")}
      onOpenChange={onOpenChange}
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="app-name">{t("applications.modal.name")}</Label>
            <Input id="app-name" name="name" required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="app-owner">{t("applications.modal.owner")}</Label>
            <Input id="app-owner" name="owner" required />
          </div>
        </div>
        <div className="space-y-2">
          <Label htmlFor="app-image">{t("applications.modal.image")}</Label>
          <Input id="app-image" name="image" required />
        </div>
        <div className="space-y-2">
          <Label htmlFor="app-repository">{t("common.repository")}</Label>
          <Input id="app-repository" name="repository" required />
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-2">
            <Label htmlFor="app-environment">{t("applications.modal.environment")}</Label>
            <Select
              id="app-environment"
              name="environment"
              options={environments.map((environment) => ({
                value: environment,
                label: t(`environment.${environment}`)
              }))}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="app-namespace">{t("applications.modal.namespace")}</Label>
            <Input id="app-namespace" name="namespace" required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="app-replicas">{t("applications.modal.replicas")}</Label>
            <Input id="app-replicas" min={1} name="replicas" required type="number" />
          </div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button type="submit">{t("applications.modal.submit")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
