import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const deployments = source("../src/features/deployments/DeploymentsPage.tsx");
const client = source("../src/api/client.ts");
const monitoring = source("../src/features/monitoring/MonitoringPage.tsx");
const prometheus = source("../../backend/app/services/prometheus_service.py");
const english = JSON.parse(source("../src/i18n/locales/en.json"));
const turkish = JSON.parse(source("../src/i18n/locales/tr.json"));

test("Open app refreshes the preview session before navigating the new tab", () => {
  const blankWindow = deployments.indexOf('window.open("about:blank", "_blank")');
  const sessionRequest = deployments.indexOf("await deploymentRecordsApi.access(deploymentId)");
  const navigation = deployments.indexOf("previewWindow.location.replace");

  assert.ok(blankWindow >= 0);
  assert.ok(sessionRequest > blankWindow);
  assert.ok(navigation > sessionRequest);
  assert.match(deployments, /previewWindow\.opener = null/);
  assert.match(deployments, /previewWindow\.close\(\)/);
  assert.match(deployments, /openingPreviewId/);
});

test("preview URLs stay backend-owned and never carry the main JWT", () => {
  const previewUrlStart = client.indexOf("previewUrl(path: string)");
  const previewUrlEnd = client.indexOf("async listUntracked", previewUrlStart);
  const previewUrlSource = client.slice(previewUrlStart, previewUrlEnd);

  assert.match(previewUrlSource, /deployment-records/);
  assert.match(previewUrlSource, /preview/);
  assert.doesNotMatch(previewUrlSource, /AUTH_TOKEN_KEY|devdeploy-token|searchParams|token=/);
  assert.match(client, /withCredentials: true/);
});

test("Monitoring uses canonical status and renders Grafana health", () => {
  assert.match(monitoring, /queryFn: observabilityApi\.status/);
  assert.match(monitoring, /healthQuery\.data\?\.grafana/);
  assert.match(monitoring, /observability\.grafana/);
  assert.ok(english.observability.status.connected);
  assert.ok(english.observability.status.unavailable);
  assert.ok(english.observability.status.not_configured);
  assert.ok(turkish.observability.status.connected);
  assert.ok(turkish.observability.status.unavailable);
  assert.ok(turkish.observability.status.not_configured);
});

test("restart chart uses namespace-scoped interval increases and remains a bar chart", () => {
  assert.ok(
    prometheus.includes(
      'sum(increase(kube_pod_container_status_restarts_total{{{namespace_selector}}}[5m]))'
    )
  );
  assert.match(monitoring, /key: "pod_restarts"[\s\S]*type: "bar"/);
  assert.match(monitoring, /emptyMessage=\{isLoading/);
});
