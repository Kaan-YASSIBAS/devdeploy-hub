export type PlatformEnvironment = "production" | "staging" | "development";

export type Environment = "dev" | "staging" | "prod";

export type DeploymentStatus = "pending" | "running" | "progressing" | "success" | "failed" | "unknown";

export type DeploymentStrategy = "rolling" | "recreate";

export type HealthStatus = "healthy" | "degraded" | "critical";

export type LogLevel = "info" | "warn" | "error" | "debug";

export type User = {
  id: number;
  email: string;
  username: string;
  display_name?: string | null;
  role: "admin" | "developer" | string;
  is_active: boolean;
  created_at: string;
  updated_at: string | null;
};

export type Application = {
  id: number;
  name: string;
  slug: string;
  description: string | null;
  repository_url: string | null;
  image_name: string;
  container_port: number;
  default_environment: Environment;
  owner_id: number;
  created_at: string;
  updated_at: string | null;
};

export type ApplicationCreateInput = {
  name: string;
  description?: string | null;
  repository_url?: string | null;
  image_name: string;
  container_port: number;
  default_environment: Environment;
};

export type ApplicationUpdateInput = Partial<ApplicationCreateInput>;

export type MockApplication = {
  id: string;
  name: string;
  image: string;
  environment: PlatformEnvironment;
  owner: string;
  repository: string;
  lastDeployment: string;
  health: HealthStatus;
  healthScore: number;
  replicas: number;
  namespace: string;
};

export type Deployment = {
  id: number;
  application_id: number;
  environment: Environment;
  image_tag: string;
  replica_count: number;
  strategy: DeploymentStrategy;
  status: DeploymentStatus;
  requested_by_id: number;
  created_at: string;
  updated_at: string | null;
  events?: DeploymentEvent[];
};

export type DeploymentCreateInput = {
  application_id: number;
  environment: Environment;
  image_tag: string;
  replica_count: number;
  strategy: DeploymentStrategy;
};

export type GitOpsDeploymentStatus = "pending" | "pending_manual_trigger" | "workflow_triggered" | "pr_opened" | "failed";

export type GitOpsDeploymentCreateInput = {
  application_id?: number | null;
  app_name: string;
  image: string;
  tag: string;
  namespace: string;
  container_port: number;
  replicas: number;
  ingress_host?: string | null;
};

export type GitOpsDeploymentRequest = GitOpsDeploymentCreateInput & {
  id: number;
  application_id: number | null;
  ingress_host: string | null;
  status: GitOpsDeploymentStatus;
  workflow_run_url: string | null;
  pull_request_url: string | null;
  error_message: string | null;
  created_by_id: number;
  created_at: string;
  updated_at: string | null;
};

export type GitOpsDeploymentResponse = {
  request: GitOpsDeploymentRequest;
  workflow_triggered: boolean;
  message: string;
  manual_workflow: string | null;
  manual_inputs: Record<string, string>;
};

export type DeploymentListSource = "gitops" | "cluster" | "legacy";

export type DeploymentListItem = {
  id: number | null;
  gitops_request_id: number | null;
  legacy_deployment_id: number | null;
  application_id: number | null;
  name: string;
  app_name: string;
  namespace: string;
  image: string | null;
  tag: string | null;
  environment: string;
  replicas: number;
  available_replicas: number;
  updated_replicas: number;
  status: DeploymentStatus;
  source: DeploymentListSource;
  created_at: string | null;
  updated_at: string | null;
};

export type DeploymentStatusUpdateInput = {
  status: DeploymentStatus;
  message: string;
};

export type DeploymentEvent = {
  id: number;
  deployment_id: number;
  event_type: string;
  level: "info" | "warning" | "error" | "success";
  message: string;
  created_at: string;
};

export type UserSummary = {
  total_applications: number;
  total_deployments: number;
  pending_deployments: number;
  running_deployments: number;
  successful_deployments: number;
  failed_deployments: number;
};

export type MockDeployment = {
  id: string;
  applicationId: string;
  applicationName: string;
  imageTag: string;
  environment: PlatformEnvironment;
  status: DeploymentStatus;
  owner: string;
  strategy: "rolling" | "blueGreen" | "canary";
  createdAt: string;
  duration: string;
  commit: string;
};

export type MockDeploymentEvent = {
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

export type MockLogEntry = {
  id: string;
  timestamp: string;
  level: LogLevel;
  app: string;
  pod: string;
  messageKey: string;
  values?: Record<string, string | number>;
};

export type ObservabilityComponentHealth = {
  available: boolean;
  detail?: string | null;
};

export type ObservabilityHealth = {
  kubernetes: ObservabilityComponentHealth;
  prometheus: ObservabilityComponentHealth;
  loki: ObservabilityComponentHealth;
};

export type ClusterSummary = {
  current_context: string | null;
  namespaces_count: number;
  pods_count: number;
  deployments_count: number;
  services_count: number;
  nodes_count: number;
  ready_nodes_count: number;
};

export type KubernetesNamespace = {
  name: string;
  status: string | null;
  created_at: string | null;
  labels: Record<string, string>;
};

export type KubernetesPod = {
  namespace: string;
  name: string;
  phase: string | null;
  node_name: string | null;
  restart_count: number;
  containers_ready: string;
  created_at: string | null;
  labels: Record<string, string>;
};

export type KubernetesDeployment = {
  namespace: string;
  name: string;
  replicas: number;
  ready_replicas: number;
  available_replicas: number;
  updated_replicas: number;
  status?: DeploymentStatus;
  image?: string | null;
  tag?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
  labels: Record<string, string>;
};

export type KubernetesServicePort = {
  name: string | null;
  port: number;
  target_port: string | number | null;
  protocol: string | null;
};

export type KubernetesService = {
  namespace: string;
  name: string;
  type: string | null;
  cluster_ip: string | null;
  ports: KubernetesServicePort[];
  labels: Record<string, string>;
};

export type ClusterMetrics = {
  cpu_usage_cores: number;
  memory_working_set_bytes: number;
  pod_count: number;
  restart_count: number;
  deployment_available_replicas: number;
};

export type LogEntry = {
  timestamp: string;
  line: string;
  labels: Record<string, string>;
};

export type ProfileSettings = {
  id: number;
  display_name: string;
  email: string;
  role: "admin" | "developer" | string;
};

export type ProfileSettingsUpdateInput = {
  display_name: string;
};

export type WorkspaceSettings = {
  id: number;
  name: string;
  plan: string;
  created_at: string;
  updated_at: string | null;
};

export type WorkspaceSettingsUpdateInput = {
  name: string;
};

export type ApiToken = {
  id: number;
  name: string;
  prefix: string;
  last_four: string;
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
  active: boolean;
};

export type ApiTokenCreateInput = {
  name: string;
};

export type ApiTokenCreateResponse = {
  token: string;
  item: ApiToken;
};

export type IntegrationStatus = "connected" | "not_configured" | "error";

export type IntegrationStatusItem = {
  key: "github" | "argocd" | "kubernetes" | "grafana";
  name: string;
  status: IntegrationStatus;
  detail: string | null;
};

export type DashboardEnvironmentDistributionItem = {
  environment: string;
  count: number;
};

export type DashboardTimelineEventStatus = "complete" | "current" | "pending" | "failed";

export type DashboardTimelineEvent = {
  id: string;
  deployment_name: string;
  namespace: string;
  event_type: string;
  message: string;
  status: DashboardTimelineEventStatus;
  timestamp: string;
};

export type DashboardClusterHealthStatus = "healthy" | "degraded" | "unavailable" | "not_configured";

export type DashboardClusterHealthItem = {
  key: "kubernetes" | "argocd" | "prometheus" | "loki";
  name: string;
  status: DashboardClusterHealthStatus;
  detail: string | null;
};

export type DashboardSummary = {
  application_count: number;
  deployment_count: number;
  pending_deployment_count: number;
  running_deployment_count: number;
  successful_deployment_count: number;
  failed_deployment_count: number;
  environment_distribution: DashboardEnvironmentDistributionItem[];
  recent_deployments: DeploymentListItem[];
  deployment_timeline: DashboardTimelineEvent[];
  cluster_health: DashboardClusterHealthItem[];
};
