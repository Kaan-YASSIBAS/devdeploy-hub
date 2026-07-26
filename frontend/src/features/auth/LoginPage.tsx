import { FormEvent, useState } from "react";
import { ArrowLeft, ShieldCheck } from "lucide-react";
import { Link, useLocation, useNavigate } from "react-router";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { LanguageSwitcher } from "@/components/layout/LanguageSwitcher";
import { useAuth } from "@/features/auth/useAuth";

export function LoginPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const location = useLocation();
  const { login } = useAuth();
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    const email = String(formData.get("email"));
    const password = String(formData.get("password"));
    const redirectTo = (location.state as { from?: { pathname?: string } } | null)?.from?.pathname ?? "/dashboard";

    try {
      setIsSubmitting(true);
      await login(email, password);
      toast.success(t("auth.login.success"));
      navigate(redirectTo, { replace: true });
    } catch {
      toast.error(t("api.errors.loginFailed"));
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="grid min-h-screen lg:grid-cols-[1fr_1.1fr]">
      <section className="relative hidden overflow-hidden border-r border-white/10 bg-slate-950/70 p-10 lg:flex lg:flex-col lg:justify-between">
        <div className="premium-grid absolute inset-0 opacity-40" />
        <Link className="relative z-10 flex items-center gap-3" to="/">
          <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-cyan-300 text-slate-950 shadow-glow">
            <ShieldCheck className="h-5 w-5" />
          </div>
          <div>
            <p className="font-semibold text-white">{t("product.name")}</p>
            <p className="text-xs text-slate-500">{t("product.shortName")}</p>
          </div>
        </Link>
        <div className="relative z-10 max-w-lg">
          <h1 className="text-4xl font-semibold leading-tight text-gradient">{t("auth.visualTitle")}</h1>
          <p className="mt-4 text-base leading-7 text-slate-300">{t("auth.visualDescription")}</p>
        </div>
      </section>

      <section className="flex min-h-screen flex-col p-4 sm:p-6">
        <div className="flex items-center justify-between">
          <Button asChild variant="ghost">
            <Link to="/">
              <ArrowLeft className="h-4 w-4" />
              {t("auth.backHome")}
            </Link>
          </Button>
          <LanguageSwitcher />
        </div>
        <div className="flex flex-1 items-center justify-center py-10">
          <Card className="w-full max-w-md p-6">
            <div className="mb-6">
              <h1 className="text-2xl font-semibold text-white">{t("auth.login.title")}</h1>
              <p className="mt-2 text-sm leading-6 text-slate-400">{t("auth.login.subtitle")}</p>
            </div>
            <form className="space-y-4" onSubmit={handleSubmit}>
              <div className="space-y-2">
                <Label htmlFor="email">{t("auth.fields.email")}</Label>
                <Input id="email" name="email" placeholder={t("auth.placeholders.email")} required type="email" />
              </div>
              <div className="space-y-2">
                <Label htmlFor="password">{t("auth.fields.password")}</Label>
                <Input id="password" name="password" placeholder={t("auth.placeholders.password")} required type="password" />
              </div>
              <p className="text-xs text-slate-500">{t("auth.backendHint")}</p>
              <Button className="w-full" disabled={isSubmitting} type="submit">
                {isSubmitting ? t("common.loading") : t("auth.login.button")}
              </Button>
            </form>
            <p className="mt-6 text-center text-sm text-slate-400">
              {t("auth.login.switchText")}{" "}
              <Link className="font-medium text-cyan-200 hover:text-cyan-100" to="/register">
                {t("auth.login.switchLink")}
              </Link>
            </p>
          </Card>
        </div>
      </section>
    </div>
  );
}
