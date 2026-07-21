import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const createModal = source("../src/components/deployments/CreateGitOpsAppModal.tsx");
const statusCard = source("../src/components/deployments/GitOpsDeployStatusCard.tsx");
const timeline = source("../src/components/deployments/GitOpsOperationTimeline.tsx");
const deployments = source("../src/features/deployments/DeploymentsPage.tsx");
const english = JSON.parse(source("../src/i18n/locales/en.json"));
const turkish = JSON.parse(source("../src/i18n/locales/tr.json"));

function sourceBlock(sourceText, startNeedle, endNeedle) {
  const start = sourceText.indexOf(startNeedle);
  const end = sourceText.indexOf(endNeedle, start);
  assert.ok(start >= 0, `missing start needle ${startNeedle}`);
  assert.ok(end > start, `missing end needle ${endNeedle}`);
  return sourceText.slice(start, end);
}

const destroyMutation = sourceBlock(
  deployments,
  "const destroyMutation = useMutation",
  "const openDestroyDialog"
);
const destroySuccess = sourceBlock(destroyMutation, "onSuccess: async", "onError: () =>");

const cleanupEffect = sourceBlock(
  deployments,
  "const pendingDeleteRuntimeKey",
  "const filteredRecords"
);

test("create flow shows GitOps operation progress while submit is in progress", () => {
  assert.match(createModal, /isSubmitting \? <GitOpsOperationTimeline activeStep=\{1\} kind="create" \/> : null/);
  assert.match(createModal, /disabled=\{isSubmitting\} type="submit"/);
  assert.equal(
    english.deployments.gitopsDeploy.operationDescription,
    "This operation includes a Git commit, Argo CD sync, and Kubernetes rollout. It usually finishes quickly, but may occasionally take a bit longer."
  );
  assert.deepEqual(Object.values(english.deployments.gitopsDeploy.progressSteps), [
    "Preparing GitOps request",
    "Writing desired state to Git",
    "Waiting for Argo CD sync",
    "Waiting for Kubernetes rollout",
    "Service is becoming ready",
    "Completed"
  ]);
  assert.ok(turkish.deployments.gitopsDeploy.operationDescription.includes("Git commit"));
});

test("accepted create flow keeps showing progress and neutral timeout copy", () => {
  assert.match(statusCard, /createProgressStep\(status\)/);
  assert.match(statusCard, /timedOut=\{timedOut && status !== "deployed" && status !== "degraded"\}/);
  assert.match(timeline, /deployments\.gitopsDeploy\.pollingTimedOut/);
  assert.equal(
    english.deployments.gitopsDeploy.pollingTimedOut,
    "The operation may still be continuing in the background. You can refresh shortly to check the latest status."
  );
  assert.ok(turkish.deployments.gitopsDeploy.pollingTimedOut.includes("arka planda devam ediyor olabilir"));
});

test("delete progress survives API success and waits for cleanup evidence", () => {
  assert.match(destroyMutation, /phase: "requesting"/);
  assert.match(destroyMutation, /phase: "cleanup_pending"/);
  assert.doesNotMatch(destroySuccess, /setDestroyInProgress\(null\)/);
  assert.match(cleanupEffect, /activeRecordExists/);
  assert.match(cleanupEffect, /runtimeResourceExists/);
  assert.match(cleanupEffect, /recordsQuery\.isSuccess/);
  assert.match(cleanupEffect, /recordsQuery\.dataUpdatedAt >= destroyInProgress\.startedAt/);
  assert.match(cleanupEffect, /untrackedQuery\.isSuccess/);
  assert.match(cleanupEffect, /untrackedQuery\.dataUpdatedAt >= destroyInProgress\.startedAt/);
  assert.match(cleanupEffect, /phase: "completed"/);
});

test("delete flow shows progress steps and disables duplicate destructive submit", () => {
  assert.match(deployments, /destroyInProgress \? \(/);
  assert.match(deployments, /deleteProgressStep\(destroyInProgress\.phase\)/);
  assert.match(deployments, /timedOut=\{destroyInProgress\.phase === "timed_out"\}/);
  assert.match(deployments, /destroyMutation\.isPending \|\| Boolean\(destroyInProgress\)/);
  assert.deepEqual(Object.values(english.deployments.records.destroy.progressSteps), [
    "Preparing delete request",
    "Removing app from Git",
    "Waiting for Argo CD prune",
    "Waiting for workload cleanup",
    "Completed"
  ]);
  assert.ok(turkish.deployments.records.destroy.progressSteps.waitPrune.includes("Argo CD prune"));
});

test("pending-delete runtime resources are hidden from normal untracked deployments", () => {
  assert.match(cleanupEffect, /pendingDeleteRuntimeKey/);
  assert.match(cleanupEffect, /visibleUntrackedDeployments/);
  assert.match(cleanupEffect, /runtimeIdentity\(deployment\.namespace, deployment\.name\) !== pendingDeleteRuntimeKey/);
  assert.match(deployments, /if \(!query\) return visibleUntrackedDeployments/);
  assert.match(deployments, /return visibleUntrackedDeployments\.filter/);
});

test("delete progress completes when managed ServiceDefinition remains without runtime resources", () => {
  assert.match(cleanupEffect, /servicesQuery\.isSuccess/);
  assert.match(cleanupEffect, /servicesQuery\.dataUpdatedAt >= destroyInProgress\.startedAt/);
  assert.match(cleanupEffect, /matchingService\.runtime_status\?\.service_found !== false/);
  assert.match(cleanupEffect, /matchingService\.runtime_status\?\.related_deployment_found !== false/);
  assert.match(cleanupEffect, /managedServiceRuntimeExists/);
  assert.match(cleanupEffect, /!servicesReady \|\|/);
});

test("delete progress does not treat a remaining product ServiceDefinition row as runtime cleanup failure", () => {
  assert.match(deployments, /queryKey: \["service-definitions", "all"\]/);
  assert.match(deployments, /servicesById/);
  assert.match(cleanupEffect, /service\.name\.toLowerCase\(\) === destroyInProgress\.record\.app_name\.toLowerCase\(\)/);
  assert.doesNotMatch(cleanupEffect, /services\.some\(\s*\(service\).*managedServiceRuntimeExists/s);
});

test("delete timeout can recover to completed after later cleanup polling", () => {
  assert.match(deployments, /destroyInProgress\?\.phase === "cleanup_pending" \|\| destroyInProgress\?\.phase === "timed_out"/);
  assert.match(cleanupEffect, /destroyInProgress\.phase !== "cleanup_pending" && destroyInProgress\.phase !== "timed_out"/);
  assert.match(cleanupEffect, /phase: "completed"/);
});
test("delete timeout stays neutral rather than becoming failure", () => {
  assert.match(cleanupEffect, /DELETE_CLEANUP_TIMEOUT_MS/);
  assert.match(cleanupEffect, /phase: "timed_out"/);
  assert.match(cleanupEffect, /toast\.warning\(t\("deployments\.records\.destroy\.timeout"\)/);
  assert.equal(
    english.deployments.records.destroy.timeout,
    "The operation may still be continuing in the background. You can refresh shortly to check the latest status."
  );
  assert.ok(turkish.deployments.records.destroy.timeout.includes("arka planda devam ediyor olabilir"));
});

test("GitOps success and delete paths keep invalidating product dashboard and runtime queries", () => {
  const createSuccess = sourceBlock(
    deployments,
    "const gitOpsMutation = useMutation",
    "const liveStatusQuery"
  );
  for (const key of [
    "deployment-records",
    "service-definitions",
    "untracked-deployments",
    "untracked-services",
    "dashboard-summary",
    "user-summary"
  ]) {
    assert.match(createSuccess, new RegExp(`queryKey: \\["${key}"\\]`));
    assert.match(destroyMutation, new RegExp(`queryKey: \\["${key}"\\]`));
  }
});

test("backend errors continue to use safe existing localized messages", () => {
  assert.match(deployments, /toast\.error\(t\(deployErrorKey\(getApiErrorStatus\(error\)\)\)\)/);
  assert.match(destroyMutation, /toast\.error\(t\("deployments\.records\.destroy\.error"\)/);
  assert.ok(english.deployments.gitopsDeploy.errors.deployFailed);
  assert.ok(english.deployments.records.destroy.error);
});
