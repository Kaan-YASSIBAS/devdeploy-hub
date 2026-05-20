export type Environment = "production" | "staging" | "development";

export type DeploymentStatus = "pending" | "running" | "success" | "failed";

export type HealthStatus = "healthy" | "degraded" | "critical";

export type LogLevel = "info" | "warn" | "error" | "debug";

export type User = {
  id: string;
  name: string;
  email: string;
  role: string;
  organization: string;
};

export type Application = {
  id: string;
  name: string;
  image: string;
  environment: Environment;
  owner: string;
  repository: string;
  lastDeployment: string;
  health: HealthStatus;
  healthScore: number;
  replicas: number;
  namespace: string;
};

export type Deployment = {
  id: string;
  applicationId: string;
  applicationName: string;
  imageTag: string;
  environment: Environment;
  status: DeploymentStatus;
  owner: string;
  strategy: "rolling" | "blueGreen" | "canary";
  createdAt: string;
  duration: string;
  commit: string;
};

export type DeploymentEvent = {
  id: string;
  deploymentId: string;
  labelKey: string;
  descriptionKey: string;
  timestamp: string;
  status: "complete" | "current" | "pending";
};

export type Pod = {
  id: string;
  applicationId: string;
  name: string;
  namespace: string;
  status: HealthStatus;
  restarts: number;
  cpu: number;
  memory: number;
  age: string;
};

export type Node = {
  id: string;
  name: string;
  status: HealthStatus;
  cpu: number;
  memory: number;
  pods: number;
  version: string;
  zone: string;
};

export type MetricPoint = {
  time: string;
  cpu: number;
  memory: number;
  requests: number;
  errors: number;
  restarts: number;
  deployments: number;
};

export type LogEntry = {
  id: string;
  timestamp: string;
  level: LogLevel;
  app: string;
  pod: string;
  messageKey: string;
  values?: Record<string, string | number>;
};
