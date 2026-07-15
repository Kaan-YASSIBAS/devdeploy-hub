import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("../src/app/ProtectedRoute.tsx", import.meta.url), "utf8");

test("backend platform readiness is authoritative when browser setup state is absent", () => {
  assert.match(source, /queryFn:\s*platformApi\.clusterHealth/);
  assert.match(source, /platformReadiness\.data\?\.platform_ready === true/);
  assert.doesNotMatch(source, /isSetupCompleted|setup-state|localStorage/);
});

test("genuine backend unready state remains gated", () => {
  assert.match(source, /if \(!setupGateSatisfied && !onSetupRoute\)/);
  assert.match(source, /to="\/setup"/);
  assert.match(source, /if \(setupGateSatisfied && onSetupRoute\)/);
  assert.match(source, /to="\/dashboard"/);
});
