import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const createModal = source("../src/components/deployments/CreateGitOpsAppModal.tsx");
const editModal = source("../src/components/deployments/EditGitOpsDeploymentModal.tsx");
const statusCard = source("../src/components/deployments/GitOpsDeployStatusCard.tsx");
const timeline = source("../src/components/deployments/GitOpsOperationTimeline.tsx");
const deployments = source("../src/features/deployments/DeploymentsPage.tsx");
const client = source("../src/api/client.ts");
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
const updateMutation = sourceBlock(
  deployments,
  "const updateMutation = useMutation",
  "const openEditDialog"
);

const cleanupEffect = sourceBlock(
  deployments,
  "const pendingDeleteRuntimeKey",
  "const filteredRecords"
);
const updateEffect = sourceBlock(
  deployments,
  "if (\n      !updateInProgress",
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
test("deployment access actions stay grouped separately from destroy", () => {
  const accessStart = deployments.indexOf('data-testid="deployment-access-actions"');
  const editStart = deployments.indexOf('data-testid="deployment-edit-actions"');
  const dangerStart = deployments.indexOf('data-testid="deployment-danger-actions"');
  assert.ok(accessStart >= 0, "missing access action group");
  assert.ok(editStart > accessStart, "edit action should render after access actions");
  assert.ok(dangerStart > editStart, "danger actions should render after edit actions");

  const accessActions = deployments.slice(accessStart, editStart);
  const editActions = deployments.slice(editStart, dangerStart);
  const dangerActions = sourceBlock(
    deployments,
    'data-testid="deployment-danger-actions"',
    "const untrackedColumns"
  );

  assert.match(accessActions, /deployments\.records\.access\.action/);
  assert.match(accessActions, /deployments\.records\.access\.openAction/);
  assert.doesNotMatch(accessActions, /deployments\.records\.destroy\.action/);
  assert.match(editActions, /deployments\.records\.update\.action/);
  assert.doesNotMatch(editActions, /deployments\.records\.destroy\.action/);
  assert.match(dangerActions, /deployments\.records\.destroy\.dangerLabel/);
  assert.match(dangerActions, /deployments\.records\.destroy\.action/);
  assert.doesNotMatch(dangerActions, /deployments\.records\.access\.openAction/);
});

test("GitOps edit action is limited to active managed deployment records", () => {
  assert.match(deployments, /function canEditGitOps\(record: DeploymentRecord\)/);
  assert.match(deployments, /record\.desired_state === "pending"/);
  assert.match(deployments, /record\.gitops_manifest_path/);
  assert.match(deployments, /!record\.archived_at/);
  assert.match(deployments, /const editEligible = canEditGitOps\(record\)/);
  assert.match(deployments, /openEditDialog\(record\)/);
});

test("edit modal pre-fills current deployment values and sends only changed fields", () => {
  assert.match(editModal, /setImage\(deployment\.image\)/);
  assert.match(editModal, /setReplicas\(String\(deployment\.replicas\)\)/);
  assert.match(editModal, /setContainerPort\(String\(deployment\.container_port\)\)/);
  assert.match(editModal, /setServicePort\(String\(deployment\.service_port\)\)/);
  assert.match(editModal, /setPreviewPath\(deployment\.preview_path \|\| "\/"\)/);
  assert.match(editModal, /function changedPayload/);
  assert.match(editModal, /if \(values\.replicas !== deployment\.replicas\) payload\.replicas = values\.replicas/);
  assert.match(editModal, /if \(values\.preview_path !== deployment\.preview_path\) payload\.preview_path = values\.preview_path/);
  assert.match(editModal, /Object\.keys\(payload\)\.length === 0/);
  assert.match(editModal, /deployments\.records\.update\.noChanges/);
});

test("edit modal validation reuses safe preview path and port constraints", () => {
  assert.match(editModal, /import \{ normalizePreviewPath \} from "@\/lib\/preview-path"/);
  assert.match(editModal, /normalizePreviewPath\(previewPath\) === null/);
  assert.match(editModal, /replicaCount < 1 \|\| replicaCount > 20/);
  assert.match(editModal, /parsedContainerPort < 1 \|\| parsedContainerPort > 65535/);
  assert.match(editModal, /parsedServicePort < 1 \|\| parsedServicePort > 65535/);
});

test("deployment update calls backend GitOps PATCH endpoint", () => {
  assert.match(client, /updateGitOps\(id: number, input: DeploymentRecordGitOpsUpdateInput\)/);
  assert.match(client, /apiClient\.patch<DeploymentRecordGitOpsUpdateResponse>\(\s*`\/deployment-records\/\$\{id\}\/gitops`/);
  assert.match(updateMutation, /deploymentRecordsApi\.updateGitOps\(record\.id, input\)/);
});

test("update progress stays visible until refreshed record runtime and reconcile match", () => {
  assert.match(updateMutation, /phase: "requesting"/);
  assert.match(updateMutation, /phase: "waiting_reconcile"/);
  assert.match(deployments, /updateInProgress \? \(/);
  assert.match(deployments, /updateProgressStep\(updateInProgress\.phase\)/);
  assert.match(deployments, /kind="update"/);
  assert.match(updateEffect, /recordsQuery\.dataUpdatedAt >= updateInProgress\.startedAt/);
  assert.match(updateEffect, /record\.image === updateInProgress\.expected\.image/);
  assert.match(updateEffect, /runtime\.desired_replicas === updateInProgress\.expected\.replicas/);
  assert.match(updateEffect, /servicePortMatches/);
  assert.match(updateEffect, /record\.reconcile_status\?\.status === "synced"/);
  assert.match(updateEffect, /phase: "completed"/);
});

test("update flow invalidates product dashboard and runtime data", () => {
  for (const key of [
    "deployment-records",
    "service-definitions",
    "untracked-deployments",
    "untracked-services",
    "dashboard-summary",
    "user-summary"
  ]) {
    assert.match(updateMutation, new RegExp(`queryKey: \\["${key}"\\]`));
  }
});

test("update timeline and translations are wired", () => {
  assert.match(timeline, /kind: "create" \| "delete" \| "update"/);
  assert.match(timeline, /UPDATE_STEPS/);
  assert.deepEqual(Object.values(english.deployments.records.update.progressSteps), [
    "Preparing update request",
    "Writing update to Git",
    "Waiting for Argo CD sync",
    "Waiting for Kubernetes rollout",
    "Completed"
  ]);
  assert.equal(english.deployments.records.update.action, "Edit");
  assert.ok(turkish.deployments.records.update.action);
});

test("destroy confirmation copy uses exact normal-cased deployment name", () => {
  assert.equal(english.deployments.records.destroy.dangerLabel, "Dangerous action");
  assert.equal(english.deployments.records.destroy.confirmLabel, "Type {{name}} to confirm.");
  assert.equal(turkish.deployments.records.destroy.dangerLabel, "Tehlikeli işlem");
  assert.equal(turkish.deployments.records.destroy.confirmLabel, "Onaylamak için {{name}} yaz.");

  const destroyDialogStart = deployments.indexOf('title={t("deployments.records.destroy.title")}');
  const destroyDialogEnd = deployments.indexOf("      </Dialog>", destroyDialogStart);
  assert.ok(destroyDialogStart >= 0, "missing destroy dialog start");
  assert.ok(destroyDialogEnd > destroyDialogStart, "missing destroy dialog end");
  const destroyDialog = deployments.slice(destroyDialogStart, destroyDialogEnd);

  assert.match(destroyDialog, /<Label className="normal-case" htmlFor="destroy-confirm-name">/);
  assert.match(destroyDialog, /confirmLabel", \{ name: destroyTarget\.app_name \}/);
  assert.match(destroyDialog, /destroyConfirmName\.trim\(\) !== destroyTarget\.app_name/);
  assert.match(destroyDialog, /destroyMutation\.mutate\(destroyTarget\)/);
  assert.doesNotMatch(destroyDialog, /toUpperCase|text-transform|uppercase/);
});
