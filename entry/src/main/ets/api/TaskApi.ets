/**
 * 任务相关 API
 * 后端 Part 4：任务 8 个接口
 * 后端来源：backend-src/h_task.cj · views.cj
 */
import { HttpClient, ApiResponse, PagedResponse } from './HttpClient';
import type { MemberBrief, DeptBrief } from './AuthApi';

// ─── 课题简要引用 ───

export interface PlanRef {
  id: number;
  title: string;
}

// ─── 任务类型 ───

export type TaskStatus = 'todo' | 'doing' | 'blocked' | 'done';

/** TaskBrief — views.cj:taskBrief */
export interface TaskBrief {
  id: number;
  title: string;
  status: TaskStatus;
  owner: MemberBrief | null;
  dept: DeptBrief | null;
  plan: PlanRef | null;
  due_at: number;       // 0 = 无截止时间
  is_overdue: boolean;  // 服务端计算的派生量
  blocked: boolean;     // 服务端计算的派生量 (status === 'blocked')
  updated_at: number;
}

/** TaskDetail = TaskBrief + — views.cj:taskDetail */
export interface TaskDetail extends TaskBrief {
  desc: string;
  blocker: string;         // blocked 时填值，否则 ""
  plan_path: PlanRef[];    // 课题祖先链（从根到直属）
  created_by: MemberBrief | null;
  created_at: number;
  completed_at: number;    // 未完成 = 0
}

// ─── 请求类型 ───

export interface CreateTaskRequest {
  title: string;
  owner_id: number;
  desc?: string;
  plan_id?: number;
  due_at?: number;
  /** 客户端生成的幂等 token，防重复提交 */
  client_token?: string;
}

export interface UpdateTaskRequest {
  title?: string;
  owner_id?: number;
  desc?: string;
  plan_id?: number;
  due_at?: number;
}

export interface UpdateTaskStatusRequest {
  status: TaskStatus;
  /** status=blocked 时必填 */
  blocker?: string;
}

export interface TaskLookupRequest {
  task_ids: number[];
}

/** POST /api/v1/tasks/lookup 响应 */
export interface TaskLookupResponse {
  items: TaskBrief[];
  missing: number[];
}

/** GET /api/v1/tasks/mine 响应 — MineGroups */
export interface MineGroups {
  overdue: TaskBrief[];
  blocked: TaskBrief[];
  due_today: TaskBrief[];
  due_week: TaskBrief[];
  later: TaskBrief[];
  no_due: TaskBrief[];
  counts: {
    overdue: number;
    blocked: number;
    open_total: number;
  };
}

// ─── API 类 ───

export class TaskApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  /** GET /api/v1/tasks/mine — 我的任务分组 */
  async mine(): Promise<ApiResponse<MineGroups>> {
    return this.client.get<MineGroups>('/tasks/mine');
  }

  /** GET /api/v1/tasks — 任务列表（筛选 + 分页） */
  async list(params?: {
    dept_id?: number;
    owner_id?: number;
    status?: TaskStatus;
    plan_id?: number;
    overdue?: boolean;
    include_subplans?: boolean;
    page?: number;
    per_page?: number;
  }): Promise<ApiResponse<PagedResponse<TaskBrief>>> {
    const query = new URLSearchParams();
    if (params?.dept_id) query.set('dept_id', String(params.dept_id));
    if (params?.owner_id) query.set('owner_id', String(params.owner_id));
    if (params?.status) query.set('status', params.status);
    if (params?.plan_id) query.set('plan_id', String(params.plan_id));
    if (params?.overdue !== undefined) query.set('overdue', String(params.overdue));
    if (params?.include_subplans !== undefined) query.set('include_subplans', String(params.include_subplans));
    if (params?.page) query.set('page', String(params.page));
    if (params?.per_page) query.set('per_page', String(params.per_page));
    const qs = query.toString();
    return this.client.get<PagedResponse<TaskBrief>>(`/tasks${qs ? '?' + qs : ''}`);
  }

  /** GET /api/v1/tasks/{id} — 任务详情 */
  async detail(id: number): Promise<ApiResponse<TaskDetail>> {
    return this.client.get<TaskDetail>(`/tasks/${id}`);
  }

  /** POST /api/v1/tasks — 创建任务 */
  async create(data: CreateTaskRequest): Promise<ApiResponse<TaskDetail>> {
    return this.client.post<TaskDetail>('/tasks', data);
  }

  /** PATCH /api/v1/tasks/{id} — 更新任务（只改传了的值） */
  async update(id: number, data: UpdateTaskRequest): Promise<ApiResponse<TaskDetail>> {
    return this.client.patch<TaskDetail>(`/tasks/${id}`, data);
  }

  /** POST /api/v1/tasks/{id}/status — 改状态 */
  async updateStatus(id: number, data: UpdateTaskStatusRequest): Promise<ApiResponse<TaskDetail>> {
    return this.client.post<TaskDetail>(`/tasks/${id}/status`, data);
  }

  /** POST /api/v1/tasks/{id}/delete — 删除任务 */
  async delete_(id: number): Promise<ApiResponse<Record<string, never>>> {
    return this.client.post<Record<string, never>>(`/tasks/${id}/delete`);
  }

  /** POST /api/v1/tasks/lookup — 批量查询任务（日历同步用） */
  async lookup(data: TaskLookupRequest): Promise<ApiResponse<TaskLookupResponse>> {
    return this.client.post<TaskLookupResponse>('/tasks/lookup', data);
  }
}
