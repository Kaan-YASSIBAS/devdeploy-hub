import i18n from "i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import { initReactI18next } from "react-i18next";
import en from "./locales/en.json";
import tr from "./locales/tr.json";

export const supportedLanguages = [
  { code: "en", labelKey: "language.english", shortLabel: "EN" },
  { code: "tr", labelKey: "language.turkish", shortLabel: "TR" }
] as const;

export type SupportedLanguage = (typeof supportedLanguages)[number]["code"];

function updateDocumentLanguage(language: string) {
  if (typeof document !== "undefined") {
    document.documentElement.lang = language.startsWith("tr") ? "tr" : "en";
  }
}

i18n.on("languageChanged", updateDocumentLanguage);

void i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: {
      en: { translation: en },
      tr: { translation: tr }
    },
    fallbackLng: "en",
    supportedLngs: ["en", "tr"],
    defaultNS: "translation",
    interpolation: {
      escapeValue: false
    },
    detection: {
      order: ["localStorage"],
      caches: ["localStorage"],
      lookupLocalStorage: "devdeploy-language"
    }
  })
  .then(() => updateDocumentLanguage(i18n.resolvedLanguage ?? i18n.language));

export default i18n;
