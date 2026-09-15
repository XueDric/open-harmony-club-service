/**
 * 成员相关 API
 * 后端 Part 3.2–3.5：成员名录、待分配、授权、会长移交、注册配置
 * 后端来源：backend-src/h_member.cj · h_auth.cj · views.cj
 */
import { HttpClient, ApiResponse } from './HttpClient';
import type { MemberBrief, DeptBrief } from './AuthApi';

// ─── 扩展类型 ───

/** 待分配成员视图 = MemberBrief + dept_hint + registered_at */
export interface PendingMemberView extends MemberBrief {
  dept_hint: DeptBrief | null;
  registered_at: number;
}

/** GET /api/v1/members/{id} 响应 */
export interface MemberDetailResponse {
  member: MemberBrief;
  stats: {
    owned_tasks: number;
    open_tasks: number;
    owned_plans: number;
  };
}

/** 注册口令配置 */
export interface RegisterCodeConfig {
  code: string;
  updated_at: number;
  updated_by: MemberBrief | null;
}

/** 批量分配失败记录 */
export interface BatchFailItem {
  id: number;
  code: string;
}

/** 批量分配响应 */
export interface AssignBatchResponse {
  succeeded: number[];
  failed: BatchFailItem[];
}

/** GET /api/v1/members 响应 */
export interface MemberListResponse {
  items: MemberBrief[];
}

/** GET /api/v1/members/pending 响应 */
export interface PendingMemberListResponse {
  items: PendingMemberView[];
}

/** 会长移交响应 */
export interface TransferPresidencyResponse {
  president: MemberBrief;
  previous: MemberBrief;
}

// ─── 请求类型 ───

export interface AssignRequest {
  dept_id: number;
  role: string;
}

export interface AssignBatchRequest {
  dept_id: number;
  role: string;
  member_ids: number[];
}

export interface UpdateMemberRequest {
  name?: string;
  dept_id?: number;
  role?: string;
}

export interface TransferPresidencyRequest {
  /** 原会长降为什么角色，默认 "vice_president" */
  self_role?: string;
}

export interface SetRegisterCodeRequest {
  code: string;
}

// ─── API 类 ───

export class MemberApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  /** GET /api/v1/members — 成员名录（可按部门/状态筛选） */
  async list(params?: {
    dept_id?: number;
    status?: 'active' | 'pending' | 'disabled';
  }): Promise<ApiResponse<MemberListResponse>> {
    const query = new URLSearchParams();
    if (params?.dept_id) query.set('dept_id', String(params.dept_id));
    if (params?.status) query.set('status', params.status);
    const qs = query.toString();
    return this.client.get<MemberListResponse>(`/members${qs ? '?' + qs : ''}`);
  }

  /** GET /api/v1/members/pending — 待分配成员列表 */
  async pending(): Promise<ApiResponse<PendingMemberListResponse>> {
    return this.client.get<PendingMemberListResponse>('/members/pending');
  }

  /** GET /api/v1/members/{id} — 成员详情（含统计数据） */
  async detail(id: number): Promise<ApiResponse<MemberDetailResponse>> {
    return this.client.get<MemberDetailResponse>(`/members/${id}`);
  }

  /** POST /api/v1/members/{id}/assign — 分配部门与角色 */
  async assign(id: number, data: AssignRequest): Promise<ApiResponse<MemberBrief>> {
    return this.client.post<MemberBrief>(`/members/${id}/assign`, data);
  }

  /** POST /api/v1/members/assign-batch — 批量分配 */
  async assignBatch(data: AssignBatchRequest): Promise<ApiResponse<AssignBatchResponse>> {
    return this.client.post<AssignBatchResponse>('/members/assign-batch', data);
  }

  /** PATCH /api/v1/members/{id} — 编辑成员（姓名/部门/角色，全部可选） */
  async update(id: number, data: UpdateMemberRequest): Promise<ApiResponse<MemberBrief>> {
    return this.client.patch<MemberBrief>(`/members/${id}`, data);
  }

  /** POST /api/v1/members/{id}/transfer-presidency — 会长移交 */
  async transferPresidency(id: number, data?: TransferPresidencyRequest): Promise<ApiResponse<TransferPresidencyResponse>> {
    return this.client.post<TransferPresidencyResponse>(`/members/${id}/transfer-presidency`, data ?? {});
  }

  /** GET /api/v1/auth/register-code — 获取注册口令 */
  async getRegisterCode(): Promise<ApiResponse<RegisterCodeConfig>> {
    return this.client.get<RegisterCodeConfig>('/auth/register-code');
  }

  /** POST /api/v1/auth/register-code — 设置注册口令 */
  async setRegisterCode(data: SetRegisterCodeRequest): Promise<ApiResponse<RegisterCodeConfig>> {
    return this.client.post<RegisterCodeConfig>('/auth/register-code', data);
  }
}
