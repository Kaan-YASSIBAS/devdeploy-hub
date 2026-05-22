import axios, { AxiosError } from "axios";
import type {
  Application,
  ApplicationCreateInput,
  ApplicationUpdateInput,
  ApiToken,
  ApiTokenCreateInput,
  ApiTokenCreateResponse,
  ClusterMetrics,
  ClusterSummary,
  DashboardSummary,
  Deployment,
  DeploymentCreateInput,
  DeploymentListItem,
  DeploymentStatusUpdateInput,
  GitOpsDeploymentCreateInput,
  GitOpsDeploymentResponse,
  KubernetesDeployment,
  KubernetesNamespace,
  KubernetesPod,
  KubernetesService,
  LogEntry,
  MetricsTimeSeries,
  ObservabilityHealth,
  IntegrationStatusItem,
  ProfileSettings,
  ProfileSettingsUpdateInput,
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
  async updateStatus(id: number, input: DeploymentStatusUpdateInput) {
    const { data } = await apiClient.patch<Deployment>(`/deployments/${id}/status`, input);
    return data;
  }
};

export const observabilityApi = {
  async health() {
    const { data } = await apiClient.get<ObservabilityHealth>("/observability/health");
    return data;
  },
  async clusterSummary() {
    const { data } = await apiClient.get<ClusterSummary>("/observability/cluster/summary");
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
    await apiClient.delete(`/settings/api-tokens/${id}`);
  },
  async integrations() {
    const { data } = await apiClient.get<IntegrationStatusItem[]>("/settings/integrations");
    return data;
  }
};
