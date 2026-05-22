import { FormEvent, useState } from "react";
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
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const form = event.currentTarget;
    const formData = new FormData(form);
    const name = String(formData.get("name") ?? "").trim();
    const imageName = String(formData.get("image_name") ?? "").trim();
    const repositoryUrl = String(formData.get("repository_url") ?? "").trim();
    const port = Number(formData.get("container_port"));

    if (!name || !imageName) {
      setError(t("applications.modal.validation.required"));
      return;
    }

    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      setError(t("applications.modal.validation.port"));
      return;
    }

    if (repositoryUrl) {
      try {
        const parsedUrl = new URL(repositoryUrl);
        if (!["http:", "https:"].includes(parsedUrl.protocol)) {
          setError(t("applications.modal.validation.repositoryUrl"));
          return;
        }
      } catch {
        setError(t("applications.modal.validation.repositoryUrl"));
        return;
      }
    }

    const application: ApplicationCreateInput = {
      name,
      description: String(formData.get("description") ?? "") || null,
      repository_url: repositoryUrl || null,
      image_name: imageName,
      container_port: port,
      default_environment: formData.get("default_environment") as Environment
    };

    try {
      await onCreate(application);
      onOpenChange(false);
      form.reset();
      setError(null);
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
            <Input id="app-port" max={65535} min={1} name="container_port" required type="number" defaultValue={8000} />
          </div>
        </div>
        <div className="space-y-2">
          <Label htmlFor="app-description">{t("common.description")}</Label>
          <Input id="app-description" name="description" placeholder={t("applications.modal.descriptionPlaceholder")} />
        </div>
        <div className="space-y-2">
          <Label htmlFor="app-repository">{t("common.repository")}</Label>
          <Input id="app-repository" name="repository_url" placeholder={t("applications.modal.repositoryPlaceholder")} type="url" />
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
        {error ? <p className="rounded-xl border border-red-300/20 bg-red-500/10 px-3 py-2 text-sm text-red-200">{error}</p> : null}
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
