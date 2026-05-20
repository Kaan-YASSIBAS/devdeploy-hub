import type {
  LogEntry,
  MetricPoint,
  MockApplication,
  MockDeployment,
  MockDeploymentEvent,
  Node,
  Pod
} from "@/types";

export const environments = ["production", "staging", "development"] as const;

export const applications: MockApplication[] = [
  {
    id: "app-payments",
    name: "payments-api",
    image: "registry.devdeploy.local/payments-api:v2.8.4",
    environment: "production",
    owner: "Payments Squad",
    repository: "github.com/acme/payments-api",
    lastDeployment: "2026-05-20 14:24",
    health: "healthy",
    healthScore: 98,
    replicas: 6,
    namespace: "payments"
  },
  {
    id: "app-checkout",
    name: "checkout-web",
    image: "registry.devdeploy.local/checkout-web:v1.19.0",
    environment: "production",
    owner: "Growth Platform",
    repository: "github.com/acme/checkout-web",
    lastDeployment: "2026-05-20 13:12",
    health: "degraded",
    healthScore: 83,
    replicas: 4,
    namespace: "commerce"
  },
  {
    id: "app-orders",
    name: "orders-worker",
    image: "registry.devdeploy.local/orders-worker:v3.4.1",
    environment: "staging",
    owner: "Core Commerce",
    repository: "github.com/acme/orders-worker",
    lastDeployment: "2026-05-19 21:47",
    health: "healthy",
    healthScore: 95,
    replicas: 3,
    namespace: "orders"
  },
  {
    id: "app-identity",
    name: "identity-service",
    image: "registry.devdeploy.local/identity-service:v4.1.8",
    environment: "development",
    owner: "Platform Identity",
    repository: "github.com/acme/identity-service",
    lastDeployment: "2026-05-19 18:02",
    health: "critical",
    healthScore: 62,
    replicas: 2,
    namespace: "identity"
  },
  {
    id: "app-notifications",
    name: "notifications-api",
    image: "registry.devdeploy.local/notifications-api:v1.7.2",
    environment: "staging",
    owner: "Messaging",
    repository: "github.com/acme/notifications-api",
    lastDeployment: "2026-05-18 16:39",
    health: "healthy",
    healthScore: 91,
    replicas: 3,
    namespace: "messaging"
  }
];

export const deployments: MockDeployment[] = [
  {
    id: "dep-1042",
    applicationId: "app-payments",
    applicationName: "payments-api",
    imageTag: "v2.8.4",
    environment: "production",
    status: "success",
    owner: "Mina Yilmaz",
    strategy: "rolling",
    createdAt: "2026-05-20 14:24",
    duration: "4m 12s",
    commit: "8f4c2a9"
  },
  {
    id: "dep-1041",
    applicationId: "app-checkout",
    applicationName: "checkout-web",
    imageTag: "v1.19.0",
    environment: "production",
    status: "running",
    owner: "Eren Kaya",
    strategy: "canary",
    createdAt: "2026-05-20 13:12",
    duration: "9m 03s",
    commit: "b6e2a11"
  },
  {
    id: "dep-1040",
    applicationId: "app-identity",
    applicationName: "identity-service",
    imageTag: "v4.1.8",
    environment: "development",
    status: "failed",
    owner: "Aylin Demir",
    strategy: "blueGreen",
    createdAt: "2026-05-20 10:51",
    duration: "2m 49s",
    commit: "fc72d88"
  },
  {
    id: "dep-1039",
    applicationId: "app-orders",
    applicationName: "orders-worker",
    imageTag: "v3.4.1",
    environment: "staging",
    status: "success",
    owner: "Can Oz",
    strategy: "rolling",
    createdAt: "2026-05-19 21:47",
    duration: "5m 30s",
    commit: "49cf0e3"
  },
  {
    id: "dep-1038",
    applicationId: "app-notifications",
    applicationName: "notifications-api",
    imageTag: "v1.7.2",
    environment: "staging",
    status: "pending",
    owner: "Selin Arslan",
    strategy: "rolling",
    createdAt: "2026-05-19 18:30",
    duration: "0m 00s",
    commit: "aa90b31"
  }
];

export const deploymentEvents: MockDeploymentEvent[] = [
  {
    id: "event-1",
    deploymentId: "dep-1042",
    labelKey: "timeline.requestCreated",
    descriptionKey: "timeline.requestCreatedDescription",
    timestamp: "14:24:03",
    status: "complete"
  },
  {
    id: "event-2",
    deploymentId: "dep-1042",
    labelKey: "timeline.manifestGenerated",
    descriptionKey: "timeline.manifestGeneratedDescription",
    timestamp: "14:24:19",
    status: "complete"
  },
  {
    id: "event-3",
    deploymentId: "dep-1042",
    labelKey: "timeline.appliedToCluster",
    descriptionKey: "timeline.appliedToClusterDescription",
    timestamp: "14:24:44",
    status: "complete"
  },
  {
    id: "event-4",
    deploymentId: "dep-1042",
    labelKey: "timeline.podsScheduled",
    descriptionKey: "timeline.podsScheduledDescription",
    timestamp: "14:26:10",
    status: "complete"
  },
  {
    id: "event-5",
    deploymentId: "dep-1042",
    labelKey: "timeline.healthCheckPassed",
    descriptionKey: "timeline.healthCheckPassedDescription",
    timestamp: "14:28:15",
    status: "complete"
  },
  {
    id: "event-6",
    deploymentId: "dep-1041",
    labelKey: "timeline.requestCreated",
    descriptionKey: "timeline.requestCreatedDescription",
    timestamp: "13:12:11",
    status: "complete"
  },
  {
    id: "event-7",
    deploymentId: "dep-1041",
    labelKey: "timeline.manifestGenerated",
    descriptionKey: "timeline.manifestGeneratedDescription",
    timestamp: "13:12:29",
    status: "complete"
  },
  {
    id: "event-8",
    deploymentId: "dep-1041",
    labelKey: "timeline.appliedToCluster",
    descriptionKey: "timeline.appliedToClusterDescription",
    timestamp: "13:12:58",
    status: "current"
  },
  {
    id: "event-9",
    deploymentId: "dep-1041",
    labelKey: "timeline.podsScheduled",
    descriptionKey: "timeline.podsScheduledDescription",
    timestamp: "--:--",
    status: "pending"
  },
  {
    id: "event-10",
    deploymentId: "dep-1041",
    labelKey: "timeline.healthCheckPassed",
    descriptionKey: "timeline.healthCheckPassedDescription",
    timestamp: "--:--",
    status: "pending"
  }
];

export const pods: Pod[] = [
  {
    id: "pod-1",
    applicationId: "app-payments",
    name: "payments-api-6d98c7f9f4-2mf8p",
    namespace: "payments",
    status: "healthy",
    restarts: 0,
    cpu: 42,
    memory: 58,
    age: "2h 11m"
  },
  {
    id: "pod-2",
    applicationId: "app-payments",
    name: "payments-api-6d98c7f9f4-8p2tl",
    namespace: "payments",
    status: "healthy",
    restarts: 0,
    cpu: 39,
    memory: 54,
    age: "2h 10m"
  },
  {
    id: "pod-3",
    applicationId: "app-checkout",
    name: "checkout-web-79df656c7b-zp9xz",
    namespace: "commerce",
    status: "degraded",
    restarts: 2,
    cpu: 67,
    memory: 74,
    age: "38m"
  },
  {
    id: "pod-4",
    applicationId: "app-identity",
    name: "identity-service-5c9848d96f-q8m4k",
    namespace: "identity",
    status: "critical",
    restarts: 5,
    cpu: 84,
    memory: 91,
    age: "24m"
  },
  {
    id: "pod-5",
    applicationId: "app-orders",
    name: "orders-worker-75fb9878d9-jwz4m",
    namespace: "orders",
    status: "healthy",
    restarts: 1,
    cpu: 46,
    memory: 61,
    age: "18h"
  }
];

export const nodes: Node[] = [
  {
    id: "node-1",
    name: "gke-prod-pool-a-01",
    status: "healthy",
    cpu: 64,
    memory: 71,
    pods: 42,
    version: "v1.30.2",
    zone: "europe-west1-b"
  },
  {
    id: "node-2",
    name: "gke-prod-pool-a-02",
    status: "healthy",
    cpu: 58,
    memory: 63,
    pods: 39,
    version: "v1.30.2",
    zone: "europe-west1-c"
  },
  {
    id: "node-3",
    name: "gke-prod-pool-b-01",
    status: "degraded",
    cpu: 79,
    memory: 86,
    pods: 47,
    version: "v1.30.2",
    zone: "europe-west1-d"
  },
  {
    id: "node-4",
    name: "gke-jobs-pool-01",
    status: "healthy",
    cpu: 44,
    memory: 52,
    pods: 31,
    version: "v1.30.2",
    zone: "europe-west1-b"
  }
];

export const metrics: MetricPoint[] = [
  { time: "09:00", cpu: 38, memory: 47, requests: 1420, errors: 8, restarts: 1, deployments: 5 },
  { time: "10:00", cpu: 44, memory: 51, requests: 1660, errors: 11, restarts: 0, deployments: 8 },
  { time: "11:00", cpu: 49, memory: 57, requests: 1900, errors: 14, restarts: 1, deployments: 7 },
  { time: "12:00", cpu: 56, memory: 62, requests: 2200, errors: 17, restarts: 2, deployments: 10 },
  { time: "13:00", cpu: 63, memory: 68, requests: 2480, errors: 22, restarts: 3, deployments: 12 },
  { time: "14:00", cpu: 58, memory: 66, requests: 2320, errors: 12, restarts: 1, deployments: 9 },
  { time: "15:00", cpu: 52, memory: 61, requests: 2100, errors: 9, restarts: 0, deployments: 6 }
];

export const logs: LogEntry[] = [
  {
    id: "log-1",
    timestamp: "2026-05-20T14:24:03Z",
    level: "info",
    app: "payments-api",
    pod: "payments-api-6d98c7f9f4-2mf8p",
    messageKey: "logs.messages.deploymentStarted",
    values: { deployment: "dep-1042", image: "v2.8.4" }
  },
  {
    id: "log-2",
    timestamp: "2026-05-20T14:26:12Z",
    level: "info",
    app: "payments-api",
    pod: "payments-api-6d98c7f9f4-8p2tl",
    messageKey: "logs.messages.readinessProbe",
    values: { pod: "payments-api-6d98c7f9f4-8p2tl" }
  },
  {
    id: "log-3",
    timestamp: "2026-05-20T14:28:11Z",
    level: "debug",
    app: "payments-api",
    pod: "payments-api-6d98c7f9f4-2mf8p",
    messageKey: "logs.messages.cacheWarm",
    values: { duration: "824ms" }
  },
  {
    id: "log-4",
    timestamp: "2026-05-20T13:20:22Z",
    level: "warn",
    app: "checkout-web",
    pod: "checkout-web-79df656c7b-zp9xz",
    messageKey: "logs.messages.slowQuery",
    values: { service: "checkout-read-model", duration: "930ms" }
  },
  {
    id: "log-5",
    timestamp: "2026-05-20T13:34:40Z",
    level: "error",
    app: "checkout-web",
    pod: "checkout-web-79df656c7b-zp9xz",
    messageKey: "logs.messages.errorBudget",
    values: { rate: "2.4x" }
  },
  {
    id: "log-6",
    timestamp: "2026-05-20T12:18:06Z",
    level: "info",
    app: "orders-worker",
    pod: "orders-worker-75fb9878d9-jwz4m",
    messageKey: "logs.messages.rolloutComplete",
    values: { image: "v3.4.1" }
  },
  {
    id: "log-7",
    timestamp: "2026-05-20T12:10:14Z",
    level: "debug",
    app: "notifications-api",
    pod: "notifications-api-78df9874c6-h4xtr",
    messageKey: "logs.messages.metricsScraped",
    values: { namespace: "messaging" }
  },
  {
    id: "log-8",
    timestamp: "2026-05-20T10:54:37Z",
    level: "error",
    app: "identity-service",
    pod: "identity-service-5c9848d96f-q8m4k",
    messageKey: "logs.messages.podRestart",
    values: { pod: "identity-service-5c9848d96f-q8m4k" }
  }
];

export const namespaces = ["payments", "commerce", "orders", "identity", "messaging", "observability"];

export const techStack = ["Kubernetes", "Docker", "Terraform", "Argo CD", "Prometheus", "Grafana"];
