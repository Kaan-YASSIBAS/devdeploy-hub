import axios, { AxiosError } from "axios";
import type {
  Application,
  ApplicationCreateInput,
  ApplicationUpdateInput,
  ApiToken,
  ApiTokenCreateInput,
  ApiTokenCreateResponse,
  ArchiveFilter,
  ClusterMetrics,
  ClusterSummary,
  DashboardSummary,
  Deployment,
  DeploymentCreateInput,
  DeploymentListItem,
  DeploymentRecord,
  DeploymentAccess,
  DeploymentRecordDestroyResponse,
  DeploymentRecordRecoverResponse,
  DeploymentRecordUpdateInput,
  DeploymentStatusUpdateInput,
  GitOpsDeploymentCreateInput,
  GitOpsDeploymentDeleteResponse,
  GitOpsDeploymentResponse,
  GitOpsAppDeployInput,
  GitOpsAppDeployResponse,
  GitOpsAppStatusResponse,
  KubernetesDeployment,
  KubernetesNamespace,
  KubernetesPod,
  KubernetesService,
  LogEntry,
  MetricsTimeSeries,
  ObservabilityHealth,
  ObservabilityStatus,
  PlatformClusterHealthResponse,
  IntegrationStatusItem,
  ProfileSettings,
  ProfileSettingsUpdateInput,
  ServiceDefinition,
  ServiceDefinitionUpdateInput,
  SetupPreflightResponse,
  UntrackedDeploymentListResponse,
  UntrackedServiceListResponse,
  User,
  UserSummary,
  WorkspaceSettings,
  WorkspaceSettingsUpdateInput
} from "@/types";

export const AUTH_TOKEN_KEY = "devdeploy-token";
export const AUTH_USER_KEY = "devdeploy-user";

export type TokenResponse = {
  access_token: string;
  token_type: "bearer" | string;
};

export type LoginInput = {
  email: string;
  password: string;
};

export type RegisterInput = LoginInput & {
  username: string;
};

const baseURL = import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8000/api/v1";

export const apiClient = axios.create({
  baseURL,
  withCredentials: true,
  headers: {
    "Content-Type": "application/json"
  }
});

export function getStoredToken() {
  return localStorage.getItem(AUTH_TOKEN_KEY);
}

export function setStoredToken(token: string) {
  localStorage.setItem(AUTH_TOKEN_KEY, token);
}

export function clearStoredAuth() {
  localStorage.removeItem(AUTH_TOKEN_KEY);
  localStorage.removeItem(AUTH_USER_KEY);
}

apiClient.interceptors.request.use((config) => {
  const token = getStoredToken();

  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }

  return config;
});

apiClient.interceptors.response.use(
  (response) => response,
  (error: AxiosError) => {
    if (error.response?.status === 401) {
      clearStoredAuth();

      if (!["/login", "/register", "/"].includes(window.location.pathname)) {
        window.dispatchEvent(new CustomEvent("devdeploy:session-expired"));
      }
    }

    return Promise.reject(error);
  }
);

export function getApiErrorMessage(error: unknown) {
  if (axios.isAxiosError(error)) {
    const detail = error.response?.data?.detail;

    if (typeof detail === "string") {
      return detail;
    }

    if (Array.isArray(detail) && detail.length > 0 && typeof detail[0]?.msg === "string") {
      return detail[0].msg;
    }

    return error.message;
  }

  return error instanceof Error ? error.message : "Unknown error";
}

export function getApiErrorStatus(error: unknown) {
  return axios.isAxiosError(error) ? error.response?.status : undefined;
}

export const authApi = {
  async login(input: LoginInput) {
    const { data } = await apiClient.post<TokenResponse>("/auth/login", input);
    return data;
  },
  async register(input: RegisterInput) {
    const { data } = await apiClient.post<User>("/auth/register", input);
    return data;
  },
  async me() {
    const { data } = await apiClient.get<User>("/auth/me");
    return data;
  }
};

export const usersApi = {
  async summary() {
    const { data } = await apiClient.get<UserSummary>("/users/me/summary");
    return data;
  }
};

export const dashboardApi = {
  async summary() {
    const { data } = await apiClient.get<DashboardSummary>("/dashboard/summary");
    return data;
  }
};

export const setupApi = {
  async preflight() {
    const { data } = await apiClient.get<SetupPreflightResponse>("/setup/preflight");
    return data;
  }
};

export const platformApi = {
  async clusterHealth() {
    const { data } = await apiClient.get<PlatformClusterHealthResponse>("/platform/cluster-health");
    return data;
  }
};

export const applicationsApi = {
  async list() {
    const { data } = await apiClient.get<Application[]>("/applications");
    return data;
  },
  async get(id: number) {
    const { data } = await apiClient.get<Application>(`/applications/${id}`);
    return data;
  },
  async create(input: ApplicationCreateInput) {
    const { data } = await apiClient.post<Application>("/applications", input);
    return data;
  },
  async update(id: number, input: ApplicationUpdateInput) {
    const { data } = await apiClient.put<Application>(`/applications/${id}`, input);
    return data;
  },
  async remove(id: number) {
    await apiClient.delete(`/applications/${id}`);
  }
};

export const serviceDefinitionsApi = {
  async list(options?: { archiveFilter?: ArchiveFilter }) {
    const { data } = await apiClient.get<ServiceDefinition[]>("/services", {
      params: options?.archiveFilter
        ? { archive_filter: options.archiveFilter }
        : undefined
    });
    return data;
  },
  async get(id: number) {
    const { data } = await apiClient.get<ServiceDefinition>(`/services/${id}`);
    return data;
  },
  async listUntracked() {
    const { data } = await apiClient.get<UntrackedServiceListResponse>("/services/untracked");
    return data;
  },
  async update(id: number, input: ServiceDefinitionUpdateInput) {
    const { data } = await apiClient.patch<ServiceDefinition>(`/services/${id}`, input);
    return data;
  },
  async archive(id: number) {
    const { data } = await apiClient.post<ServiceDefinition>(`/services/${id}/archive`);
    return data;
  },
  async remove(id: number) {
    await apiClient.delete(`/services/${id}`);
  }
};

export const deploymentRecordsApi = {
  async list(options?: { archiveFilter?: ArchiveFilter }) {
    const { data } = await apiClient.get<DeploymentRecord[]>("/deployment-records", {
      params: options?.archiveFilter
        ? { archive_filter: options.archiveFilter }
        : undefined
    });
    return data;
  },
  async get(id: number) {
    const { data } = await apiClient.get<DeploymentRecord>(`/deployment-records/${id}`);
    return data;
  },
  async access(id: number) {
    const { data } = await apiClient.get<DeploymentAccess>(`/deployment-records/${id}/access`);
    return data;
  },
  previewUrl(path: string) {
    if (!/^\/api\/v1\/deployment-records\/[1-9][0-9]*\/preview\/$/.test(path)) {
      throw new Error("Invalid deployment preview URL.");
    }
    const apiOrigin = new URL(baseURL, window.location.origin).origin;
    return new URL(path, apiOrigin).toString();
  },
  async listUntracked() {
    const { data } = await apiClient.get<UntrackedDeploymentListResponse>(
      "/deployment-records/untracked"
    );
    return data;
  },
  async update(id: number, input: DeploymentRecordUpdateInput) {
    const { data } = await apiClient.patch<DeploymentRecord>(`/deployment-records/${id}`, input);
    return data;
  },
  async archive(id: number) {
    const { data } = await apiClient.post<DeploymentRecord>(`/deployment-records/${id}/archive`);
    return data;
  },
  async recover(id: number) {
    const { data } = await apiClient.post<DeploymentRecordRecoverResponse>(
      `/deployment-records/${id}/recover`
    );
    return data;
  },
  async reconcile(id: number) {
    const { data } = await apiClient.post<DeploymentRecordRecoverResponse>(
      `/deployment-records/${id}/reconcile`
    );
    return data;
  },
  async destroy(id: number) {
    const { data } = await apiClient.post<DeploymentRecordDestroyResponse>(
      `/deployment-records/${id}/destroy`
    );
    return data;
  },
  async remove(id: number) {
    await apiClient.delete(`/deployment-records/${id}`);
  }
};

export const deploymentsApi = {
  async list() {
    const { data } = await apiClient.get<Deployment[]>("/deployments");
    return data;
  },
  async listGitOps() {
    const { data } = await apiClient.get<DeploymentListItem[]>("/deployments/gitops");
    return data;
  },
  async get(id: number) {
    const { data } = await apiClient.get<Deployment>(`/deployments/${id}`);
    return data;
  },
  async getGitOps(namespace: string, name: string) {
    const { data } = await apiClient.get<DeploymentListItem>(`/deployments/gitops/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`);
    return data;
  },
  async create(input: DeploymentCreateInput) {
    const { data } = await apiClient.post<Deployment>("/deployments", input);
    return data;
  },
  async createGitOps(input: GitOpsDeploymentCreateInput) {
    const { data } = await apiClient.post<GitOpsDeploymentResponse>("/deployments/gitops", input);
    return data;
  },
  async deleteGitOps(namespace: string, name: string) {
    const { data } = await apiClient.delete<GitOpsDeploymentDeleteResponse>(`/deployments/gitops/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`);
    return data;
  },
  async updateStatus(id: number, input: DeploymentStatusUpdateInput) {
    const { data } = await apiClient.patch<Deployment>(`/deployments/${id}/status`, input);
    return data;
  }
};

export async function deployGitOpsApp(input: GitOpsAppDeployInput) {
  const { data } = await apiClient.post<GitOpsAppDeployResponse>("/gitops/apps", input);
  return data;
}

export async function getGitOpsAppStatus(appName: string, commitSha: string) {
  const { data } = await apiClient.get<GitOpsAppStatusResponse>(
    `/gitops/apps/${encodeURIComponent(appName)}/status`,
    { params: { commit_sha: commitSha } }
  );
  return data;
}

export const observabilityApi = {
  async health() {
    const { data } = await apiClient.get<ObservabilityHealth>("/observability/health");
    return data;
  },
  async status() {
    const { data } = await apiClient.get<ObservabilityStatus>("/observability/status");
    return data;
  },
  async clusterSummary(namespace: string) {
    const { data } = await apiClient.get<ClusterSummary>("/observability/cluster/summary", {
      params: { namespace }
    });
    return data;
  },
  async namespaces() {
    const { data } = await apiClient.get<KubernetesNamespace[]>("/observability/kubernetes/namespaces");
    return data;
  },
  async pods(namespace?: string) {
    const { data } = await apiClient.get<KubernetesPod[]>("/observability/kubernetes/pods", {
      params: { namespace }
    });
    return data;
  },
  async kubernetesDeployments(namespace?: string) {
    const { data } = await apiClient.get<KubernetesDeployment[]>("/observability/kubernetes/deployments", {
      params: { namespace }
    });
    return data;
  },
  async services(namespace?: string) {
    const { data } = await apiClient.get<KubernetesService[]>("/observability/kubernetes/services", {
      params: { namespace }
    });
    return data;
  },
  async clusterMetrics() {
    const { data } = await apiClient.get<ClusterMetrics>("/observability/metrics/cluster");
    return data;
  },
  async namespaceMetrics(namespace: string) {
    const { data } = await apiClient.get<ClusterMetrics>(`/observability/metrics/namespaces/${namespace}`);
    return data;
  },
  async metricsTimeseries(params: { namespace?: string; range?: string; step?: string; metric?: string }) {
    const { data } = await apiClient.get<MetricsTimeSeries>("/observability/metrics/timeseries", { params });
    return data;
  },
  async logs(params: { namespace?: string; pod?: string; limit?: number }) {
    const { data } = await apiClient.get<LogEntry[]>("/observability/logs", { params });
    return data;
  }
};

export const settingsApi = {
  async profile() {
    const { data } = await apiClient.get<ProfileSettings>("/settings/profile");
    return data;
  },
  async updateProfile(input: ProfileSettingsUpdateInput) {
    const { data } = await apiClient.put<ProfileSettings>("/settings/profile", input);
    return data;
  },
  async workspace() {
    const { data } = await apiClient.get<WorkspaceSettings>("/settings/workspace");
    return data;
  },
  async updateWorkspace(input: WorkspaceSettingsUpdateInput) {
    const { data } = await apiClient.put<WorkspaceSettings>("/settings/workspace", input);
    return data;
  },
  async apiTokens() {
    const { data } = await apiClient.get<ApiToken[]>("/settings/api-tokens");
    return data;
  },
  async createApiToken(input: ApiTokenCreateInput) {
    const { data } = await apiClient.post<ApiTokenCreateResponse>("/settings/api-tokens", input);
    return data;
  },
  async revokeApiToken(id: number) {
    await apiClient.post(`/settings/api-tokens/${id}/revoke`);
  },
  async deleteApiToken(id: number) {
    await apiClient.delete(`/settings/api-tokens/${id}`);
  },
  async integrations() {
    const { data } = await apiClient.get<IntegrationStatusItem[]>("/settings/integrations");
    return data;
  }
};
