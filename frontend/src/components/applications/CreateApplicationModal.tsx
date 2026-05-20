import { FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import type { ApplicationCreateInput, Environment } from "@/types";

type CreateApplicationModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreate: (application: ApplicationCreateInput) => Promise<void> | void;
  isSubmitting?: boolean;
};

const environments: Environment[] = ["dev", "staging", "prod"];

export function CreateApplicationModal({ open, onOpenChange, onCreate, isSubmitting = false }: CreateApplicationModalProps) {
  const { t } = useTranslation();

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const form = event.currentTarget;
    const formData = new FormData(form);
    const application: ApplicationCreateInput = {
      name: String(formData.get("name")),
      description: String(formData.get("description") ?? "") || null,
      repository_url: String(formData.get("repository_url") ?? "") || null,
      image_name: String(formData.get("image_name")),
      container_port: Number(formData.get("container_port")),
      default_environment: formData.get("default_environment") as Environment
    };

    try {
      await onCreate(application);
      onOpenChange(false);
      form.reset();
    } catch {
      // Parent mutation owns translated error toast.
    }
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
            <Label htmlFor="app-port">{t("applications.modal.containerPort")}</Label>
            <Input id="app-port" min={1} name="container_port" required type="number" defaultValue={8000} />
          </div>
        </div>
        <div className="space-y-2">
          <Label htmlFor="app-description">{t("common.description")}</Label>
          <Input id="app-description" name="description" placeholder={t("applications.modal.descriptionPlaceholder")} />
        </div>
        <div className="space-y-2">
          <Label htmlFor="app-repository">{t("common.repository")}</Label>
          <Input id="app-repository" name="repository_url" placeholder={t("applications.modal.repositoryPlaceholder")} />
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="app-image">{t("applications.modal.imageName")}</Label>
            <Input id="app-image" name="image_name" placeholder={t("applications.modal.imagePlaceholder")} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="app-environment">{t("applications.modal.defaultEnvironment")}</Label>
            <Select
              id="app-environment"
              name="default_environment"
              options={environments.map((environment) => ({
                value: environment,
                label: t(`environment.${environment}`)
              }))}
            />
          </div>
        </div>
        <DialogFooter>
          <Button disabled={isSubmitting} variant="ghost" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button disabled={isSubmitting} type="submit">
            {isSubmitting ? t("common.loading") : t("applications.modal.submit")}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
