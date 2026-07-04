import { useEffect, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { ServiceDefinitionCreateInput } from "@/types";

type CreateServiceDefinitionModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreate: (input: ServiceDefinitionCreateInput) => Promise<unknown>;
  isSubmitting: boolean;
};

export function CreateServiceDefinitionModal({
  open,
  onOpenChange,
  onCreate,
  isSubmitting
}: CreateServiceDefinitionModalProps) {
  const { t } = useTranslation();
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [defaultImage, setDefaultImage] = useState("");
  const [defaultReplicas, setDefaultReplicas] = useState("1");
  const [defaultPort, setDefaultPort] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      return;
    }
    setName("");
    setDescription("");
    setDefaultImage("");
    setDefaultReplicas("1");
    setDefaultPort("");
    setError(null);
  }, [open]);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const replicas = Number(defaultReplicas);
    const port = defaultPort ? Number(defaultPort) : null;
    if (name.trim().length < 2) {
      setError(t("applications.domain.validation.name"));
      return;
    }
    if (defaultImage && /\s/.test(defaultImage)) {
      setError(t("applications.domain.validation.image"));
      return;
    }
    if (!Number.isInteger(replicas) || replicas < 1 || replicas > 20) {
      setError(t("applications.domain.validation.replicas"));
      return;
    }
    if (port !== null && (!Number.isInteger(port) || port < 1 || port > 65535)) {
      setError(t("applications.domain.validation.port"));
      return;
    }

    try {
      await onCreate({
        name: name.trim(),
        description: description.trim() || null,
        default_image: defaultImage.trim() || null,
        default_replicas: replicas,
        default_port: port
      });
      onOpenChange(false);
    } catch {
      // The page owns API-specific error messaging.
    }
  };

  return (
    <Dialog
      closeLabel={t("common.close")}
      description={t("applications.domain.createDescription")}
      open={open}
      title={t("applications.domain.createTitle")}
      onOpenChange={(nextOpen) => !isSubmitting && onOpenChange(nextOpen)}
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="space-y-2">
          <Label htmlFor="service-definition-name">{t("applications.domain.fields.name")}</Label>
          <Input
            autoComplete="off"
            id="service-definition-name"
            maxLength={120}
            required
            value={name}
            onChange={(event) => setName(event.target.value)}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="service-definition-description">{t("common.description")}</Label>
          <Input
            id="service-definition-description"
            maxLength={4000}
            placeholder={t("applications.domain.descriptionPlaceholder")}
            value={description}
            onChange={(event) => setDescription(event.target.value)}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="service-definition-image">{t("applications.domain.fields.defaultImage")}</Label>
          <Input
            autoComplete="off"
            id="service-definition-image"
            maxLength={512}
            placeholder={t("applications.domain.imagePlaceholder")}
            value={defaultImage}
            onChange={(event) => setDefaultImage(event.target.value)}
          />
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="service-definition-replicas">{t("applications.domain.fields.defaultReplicas")}</Label>
            <Input
              id="service-definition-replicas"
              max={20}
              min={1}
              required
              type="number"
              value={defaultReplicas}
              onChange={(event) => setDefaultReplicas(event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="service-definition-port">{t("applications.domain.fields.defaultPort")}</Label>
            <Input
              id="service-definition-port"
              max={65535}
              min={1}
              placeholder={t("common.optional")}
              type="number"
              value={defaultPort}
              onChange={(event) => setDefaultPort(event.target.value)}
            />
          </div>
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
            {isSubmitting ? t("common.loading") : t("applications.domain.createAction")}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
