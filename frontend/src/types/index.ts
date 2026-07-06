export type PlatformEnvironment = "production" | "staging" | "development";

export type Environment = "dev" | "staging" | "prod";

export type DeploymentStatus = "pending" | "running" | "progressing" | "success" | "failed" | "stale" | "deletion_requested" | "deleted" | "unknown";

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

export type RuntimeServicePort = {
  name: string | null;
  port: number;
  target_port: number | string | null;
  protocol: string | null;
};

export type ArchiveFilter = "active" | "archived" | "all";

export type ServiceRuntimeStatus = {
  source: "kubernetes";
  display_status: "ready" | "not_found" | "unknown";
  service_found: boolean;
  namespace: string;
  service_type: string | null;
  cluster_ip: string | null;
  ports: RuntimeServicePort[] | null;
  related_deployment_found: boolean | null;
  related_deployment_status: string | null;
  observed_at: string | null;
  message: string | null;
};

export type DeploymentRuntimeStatus = {
  source: "kubernetes";
  display_status: "running" | "progressing" | "not_found" | "unknown";
  deployment_found: boolean;
  service_found: boolean;
  desired_replicas: number | null;
  ready_replicas: number | null;
  available_replicas: number | null;
  updated_replicas: number | null;
  pod_ready_count: number | null;
  pod_total_count: number | null;
  service_type: string | null;
  service_cluster_ip: string | null;
  service_ports: RuntimeServicePort[] | null;
  observed_at: string | null;
  message: string | null;
};

export type DriftDifference = {
  field: string;
  expected: string | number | null;
  actual: string | number | null;
  source: "gitops" | "runtime";
};

export type DriftComparison = {
  status: "aligned" | "drifted" | "missing" | "unknown";
  differences: DriftDifference[];
};

export type DeploymentDriftStatus = {
  status: "aligned" | "drifted" | "gitops_missing" | "runtime_missing" | "unknown";
  db_to_gitops: DriftComparison;
  db_to_runtime: DriftComparison;
  checked_at: string;
  message: string;
};

export type UntrackedDeploymentRuntime = {
  name: string;
  namespace: string;
  source: "kubernetes";
  tracking_status: "untracked";
  display_status: "running" | "progressing" | "unknown";
  desired_replicas: number | null;
  ready_replicas: number | null;
  available_replicas: number | null;
  updated_replicas: number | null;
  pod_ready_count: number | null;
  pod_total_count: number | null;
  service_found: boolean;
  service_ports: RuntimeServicePort[] | null;
  observed_at: string;
  message: string;
};

export type UntrackedServiceRuntime = {
  name: string;
  namespace: string;
  source: "kubernetes";
  tracking_status: "untracked";
  display_status: "ready" | "unknown";
  service_type: string | null;
  cluster_ip: string | null;
  ports: RuntimeServicePort[] | null;
  related_deployment_found: boolean;
  related_deployment_status: string | null;
  observed_at: string;
  message: string;
};

export type UntrackedDeploymentListResponse = {
  items: UntrackedDeploymentRuntime[];
  runtime_available: boolean;
  message: string | null;
};

export type UntrackedServiceListResponse = {
  items: UntrackedServiceRuntime[];
  runtime_available: boolean;
  message: string | null;
};

export type ServiceDefinition = {
  id: number;
  owner_id: number;
  name: string;
  description: string | null;
  default_image: string | null;
  default_replicas: number;
  default_port: number | null;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
  runtime_status: ServiceRuntimeStatus | null;
};

export type ServiceDefinitionUpdateInput = Partial<{
  name: string;
  description: string | null;
  default_image: string | null;
  default_replicas: number;
  default_port: number | null;
}>;

export type DeploymentRecordDesiredState = "draft" | "pending";

export type DeploymentRecord = {
  id: number;
  owner_id: number;
  service_definition_id: number | null;
  app_name: string;
  image: string;
  replicas: number;
  container_port: number;
  service_port: number;
  service_type: "ClusterIP";
  namespace: string;
  gitops_manifest_path: string | null;
  commit_sha: string | null;
  desired_state: DeploymentRecordDesiredState;
  status_summary: string | null;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
  runtime_status: DeploymentRuntimeStatus | null;
  drift_status: DeploymentDriftStatus | null;
};

export type DeploymentRecordUpdateInput = Partial<{
  service_definition_id: number | null;
  app_name: string;
  image: string;
  replicas: number;
  container_port: number;
  service_port: number;
  service_type: "ClusterIP";
  namespace: string;
  desired_state: DeploymentRecordDesiredState;
  gitops_manifest_path: string | null;
  commit_sha: string | null;
  status_summary: string | null;
}>;

export type DeploymentRecordRecoverResponse = {
  status:
    | "pushed_waiting_for_argocd"
    | "no_changes_waiting_for_argocd"
    | "no_changes"
    | "validation_failed"
    | "repo_write_failed"
    | "render_failed"
    | "commit_failed"
    | "push_failed"
    | "internal_error";
  deployment_id: number;
  app_name: string;
  commit_sha: string | null;
  manifest_path: string | null;
  message: string;
  error_code: string | null;
};

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

export type GitOpsDeploymentStatus = "pending" | "pending_manual_trigger" | "workflow_triggered" | "pr_opened" | "failed" | "stale" | "deletion_requested" | "deleted";

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

export type GitOpsDeploymentDeleteResponse = GitOpsDeploymentResponse;

export type GitOpsAppDeployStatus =
  | "pushed_waiting_for_argocd"
  | "argocd_observing"
  | "argocd_synced"
  | "workload_progressing"
  | "deployed"
  | "degraded"
  | "unknown";

export type GitOpsAppDeployInput = {
  app_name: string;
  image: string;
  replicas: number;
  container_port: number;
  service_port: number;
  service_type: "ClusterIP";
};

export type GitOpsAppDeployResponse = {
  status: "pushed_waiting_for_argocd";
  app_name: string;
  namespace: string;
  source_path?: string;
  commit_sha: string | null;
  message: string;
  error_code?: string | null;
};

export type GitOpsRootApplicationStatus = {
  name: string;
  sync_status: string | null;
  health_status: string | null;
  observed_commit_match: boolean;
};

export type GitOpsWorkloadReadiness = {
  deployment_ready: boolean;
  service_ready: boolean;
  pods_ready: boolean;
  desired_replicas: number | null;
  ready_replicas: number | null;
  available_replicas: number | null;
  pod_count: number;
  ready_pod_count: number;
};

export type GitOpsAppStatusResponse = {
  status: GitOpsAppDeployStatus;
  app_name: string;
  namespace: string;
  commit_sha: string;
  observed_revision: string | null;
  root_application: GitOpsRootApplicationStatus;
  workload: GitOpsWorkloadReadiness;
  message: string;
  error_code: string | null;
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
  is_live: boolean;
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

export type MetricSeriesPoint = {
  timestamp: string;
  value: number;
};

export type MetricSeriesStatus = "ok" | "empty" | "unavailable";

export type MetricSeries = {
  key: "cpu_usage" | "memory_working_set" | "pod_restarts" | "request_rate" | "error_rate" | string;
  name: string;
  unit: string;
  status: MetricSeriesStatus;
  detail: string | null;
  points: MetricSeriesPoint[];
};

export type MetricsTimeSeries = {
  namespace: string;
  range: string;
  step: string;
  prometheus_available: boolean;
  series: MetricSeries[];
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

export type SetupPreflightCheckStatus = "ok" | "warning" | "failed";

export type SetupPreflightOverallStatus = "ready" | "warnings" | "blocked";

export type SetupPreflightRuntimeMode = "host" | "kubernetes" | "unknown";

export type SetupPreflightCheck = {
  id: string;
  label: string;
  status: SetupPreflightCheckStatus;
  message: string;
  details: string | null;
};

export type SetupPreflightResponse = {
  runtime_mode: SetupPreflightRuntimeMode;
  runtime_message: string;
  overall_status: SetupPreflightOverallStatus;
  required_contexts: string[];
  detected_contexts: string[];
  required_clusters: string[];
  detected_clusters: string[];
  contexts_ready: boolean;
  clusters_ready: boolean;
  platform_ready: boolean;
  checks: SetupPreflightCheck[];
};

export type PlatformClusterHealthStatus = "healthy" | "degraded" | "unreachable" | "unknown";

export type PlatformClusterHealthReason =
  | "ok"
  | "kubeconfig_unreachable"
  | "api_unreachable"
  | "api_port_unpublished"
  | "unknown";

export type PlatformClusterHealthItem = {
  cluster_name: string;
  context: string;
  role: "management" | "workload";
  status: PlatformClusterHealthStatus;
  api_reachable: boolean;
  reason: PlatformClusterHealthReason;
  message: string;
  recommended_action: string | null;
  checked_at: string;
};

export type PlatformClusterHealthResponse = {
  management: PlatformClusterHealthItem;
  workload: PlatformClusterHealthItem;
};
