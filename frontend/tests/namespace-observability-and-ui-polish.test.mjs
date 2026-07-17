import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const dashboard = source("../src/features/dashboard/DashboardPage.tsx");
const services = source("../src/features/applications/ApplicationsPage.tsx");
const settings = source("../src/features/settings/SettingsPage.tsx");
const topbar = source("../src/components/layout/Topbar.tsx");
const cluster = source("../src/features/cluster/ClusterPage.tsx");
const monitoring = source("../src/features/monitoring/MonitoringPage.tsx");
const logs = source("../src/features/monitoring/LogsPage.tsx");
const metricChart = source("../src/components/shared/MetricChart.tsx");
const deployments = source("../src/features/deployments/DeploymentsPage.tsx");
const english = JSON.parse(source("../src/i18n/locales/en.json"));
const turkish = JSON.parse(source("../src/i18n/locales/tr.json"));

test("Dashboard service action opens Services and empty action columns are omitted", () => {
  assert.match(dashboard, /to="\/applications"/);
  assert.match(dashboard, /dashboard\.actions\.viewServices/);
  assert.equal(english.dashboard.actions.viewServices, "View services");
  assert.equal(turkish.dashboard.actions.viewServices, "Servisleri görüntüle");
  assert.match(services, /filteredServices\.some\(/);
  assert.match(services, /\? \[\{[\s\S]*key: "actions"/);
});

test("profile save refreshes the canonical auth user used by the header", () => {
  assert.match(settings, /const \{ getCurrentUser, user \} = useAuth\(\)/);
  assert.match(settings, /await getCurrentUser\(\)/);
  assert.match(settings, /setQueryData\(\["settings", "profile"\], profile\)/);
  assert.match(topbar, /user\?\.display_name \|\| user\?\.username/);
});

test("Cluster, Monitoring, and Logs use the discovered selected namespace", () => {
  for (const page of [cluster, monitoring, logs]) {
    assert.doesNotMatch(page, /DEFAULT_NAMESPACE|devdeploy-apps/);
    assert.match(page, /setNamespace\(namespaces\[0\]\.name\)/);
  }
  assert.match(monitoring, /\["observability", "metrics", "timeseries", namespace, range\]/);
  assert.match(logs, /\["observability", "logs", namespace, pod, limit\]/);
  assert.match(logs, /observabilityApi\.logs\(\{ namespace/);
  assert.equal((cluster.match(/detail=\{namespace\}/g) ?? []).length >= 3, true);
  assert.match(monitoring, /monitoring\.metrics\.clusterScope/);
});

test("connected empty metric series keep their chart frames", () => {
  assert.match(monitoring, /series\?\.status === "unavailable"/);
  assert.match(monitoring, /emptyMessage=\{isLoading/);
  assert.match(metricChart, /emptyMessage/);
  assert.equal(english.monitoring.empty.noDataInRange, "No data in this time range.");
  assert.equal(turkish.monitoring.empty.noDataInRange, "Bu zaman aralığında veri yok.");
});

test("reconcile cells use compact canonical states with full detail on hover", () => {
  assert.match(deployments, /title=\{reconcile\.message\}/);
  assert.match(deployments, /reconcileSummary\.\$\{reconcile\.status\}/);
  for (const status of ["synced", "progressing", "degraded", "drifted", "unknown"]) {
    assert.ok(english.deployments.records.reconcileSummary[status]);
    assert.ok(turkish.deployments.records.reconcileSummary[status]);
  }
});
