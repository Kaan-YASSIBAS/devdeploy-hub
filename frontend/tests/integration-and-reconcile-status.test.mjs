import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const settingsSource = readFileSync(
  new URL("../src/features/settings/SettingsPage.tsx", import.meta.url),
  "utf8"
);
const deploymentsSource = readFileSync(
  new URL("../src/features/deployments/DeploymentsPage.tsx", import.meta.url),
  "utf8"
);
const dashboardSource = readFileSync(
  new URL("../src/features/dashboard/DashboardPage.tsx", import.meta.url),
  "utf8"
);
const typesSource = readFileSync(new URL("../src/types/index.ts", import.meta.url), "utf8");
const english = JSON.parse(
  readFileSync(new URL("../src/i18n/locales/en.json", import.meta.url), "utf8")
);

test("Argo CD integration renders healthy, degraded, and unavailable states", () => {
  assert.match(typesSource, /"connected"[\s\S]*"degraded"[\s\S]*"unavailable"/);
  assert.match(settingsSource, /status === "error" \|\| status === "unavailable"/);
  assert.match(settingsSource, /status === "optional" \|\| status === "degraded"/);
  assert.equal(english.settings.integrations.details.argocd.connected.includes("Synced"), true);
  assert.ok(english.settings.integrations.details.argocd.degraded);
  assert.ok(english.settings.integrations.details.argocd.unavailable);
});

test("Dashboard maps the same canonical Argo CD states as Settings", () => {
  for (const state of ["healthy", "degraded", "unavailable", "not_configured"]) {
    assert.ok(english.dashboard.clusterHealthStatus[state]);
    assert.ok(english.dashboard.clusterHealthDetails.argocd[state]);
  }
  assert.match(dashboardSource, /clusterHealthVariant\(item\.status\)/);
  assert.match(dashboardSource, /clusterHealthStatus\.\$\{item\.status\}/);
  assert.match(dashboardSource, /clusterHealthDetails\.\$\{item\.key\}\.\$\{item\.status\}/);
  assert.equal(
    english.dashboard.clusterHealthDetails.argocd.healthy.includes("Synced and Healthy"),
    true
  );
  assert.equal(
    english.dashboard.clusterHealthDetails.argocd.not_configured.includes("Root Application"),
    true
  );
});

test("deployment reconcile field renders all canonical reconcile states", () => {
  for (const state of ["synced", "progressing", "degraded", "drifted", "unknown"]) {
    assert.ok(english.deployments.records.reconcileState[state]);
  }
  assert.match(deploymentsSource, /record\.reconcile_status/);
  assert.match(deploymentsSource, /reconcileVariant\(reconcile\.status\)/);
  assert.match(deploymentsSource, /reconcileState\.\$\{reconcile\.status\}/);
});
