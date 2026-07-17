import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const pageSource = readFileSync(new URL("../src/features/cluster/ClusterPage.tsx", import.meta.url), "utf8");
const clientSource = readFileSync(new URL("../src/api/client.ts", import.meta.url), "utf8");

test("cluster summary follows the selected managed workload namespace", () => {
  assert.doesNotMatch(pageSource, /DEFAULT_NAMESPACE|devdeploy-apps/);
  assert.match(pageSource, /setNamespace\(namespaces\[0\]\.name\)/);
  assert.match(pageSource, /\["observability", "cluster-summary", namespace\]/);
  assert.match(pageSource, /observabilityApi\.clusterSummary\(namespace\)/);
  assert.match(pageSource, /enabled: Boolean\(namespace\)/);
  assert.match(clientSource, /async clusterSummary\(namespace: string\)/);
  assert.match(clientSource, /params: \{ namespace \}/);
});
