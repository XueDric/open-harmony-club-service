/**
 * 部门/组织相关 API
 * 后端 Part 3.1：部门 CRUD + Part 3.7：招募链接
 * 后端来源：backend-src/h_dept.cj · h_link.cj · views.cj
 */
import { HttpClient, ApiResponse } from './HttpClient';
import type { MemberBrief, DeptBrief } from './AuthApi';

// ─── 部门类型 ───

/** DeptView — views.cj:deptView */
export interface DeptView {
  id: number;
  name: string;
  sort: number;
  lead: MemberBrief | null;
  member_count: number;
}

/** InviteLinkView — views.cj:inviteLinkView */
export interface InviteLinkView {
  token: string;
  /** 完整的落地页 URL（由服务端拼 Host 头生成） */
  url: string;
  dept: DeptBrief;
  enabled: boolean;
  created_at: number;
}

/** GET /api/v1/depts 响应 */
export interface DeptListResponse {
  items: DeptView[];
}

/** GET /api/v1/depts/{id}/links 响应 */
export interface DeptLinksResponse {
  items: InviteLinkView[];
}

// ─── 请求类型 ───

export interface CreateDeptRequest {
  name: string;
  sort?: number;
}

export interface UpdateDeptRequest {
  name?: string;
  sort?: number;
}

// ─── API 类 ───

export class DeptApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  /** GET /api/v1/depts — 获取所有部门 */
  async list(): Promise<ApiResponse<DeptListResponse>> {
    return this.client.get<DeptListResponse>('/depts');
  }

  /** POST /api/v1/depts — 创建部门 */
  async create(data: CreateDeptRequest): Promise<ApiResponse<DeptView>> {
    return this.client.post<DeptView>('/depts', data);
  }

  /** PATCH /api/v1/depts/{id} — 更新部门 */
  async update(id: number, data: UpdateDeptRequest): Promise<ApiResponse<DeptView>> {
    return this.client.patch<DeptView>(`/depts/${id}`, data);
  }

  /** DELETE /api/v1/depts/{id} — 删除部门（需无成员） */
  async delete_(id: number): Promise<ApiResponse<Record<string, never>>> {
    return this.client.delete_<Record<string, never>>(`/depts/${id}`);
  }

  /** GET /api/v1/depts/{id}/links — 获取部门的所有招募链接 */
  async listLinks(deptId: number): Promise<ApiResponse<DeptLinksResponse>> {
    return this.client.get<DeptLinksResponse>(`/depts/${deptId}/links`);
  }

  /** POST /api/v1/depts/{id}/links — 创建招募链接 */
  async createLink(deptId: number): Promise<ApiResponse<InviteLinkView>> {
    return this.client.post<InviteLinkView>(`/depts/${deptId}/links`);
  }

  /** PATCH /api/v1/links/{token}/toggle — 启用/禁用招募链接 */
  async toggleLink(token: string): Promise<ApiResponse<InviteLinkView>> {
    return this.client.patch<InviteLinkView>(`/links/${token}/toggle`);
  }
}
