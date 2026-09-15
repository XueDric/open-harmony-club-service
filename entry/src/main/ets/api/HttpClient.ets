/**
 * 全局 HTTP 客户端
 * - 自动携带 Authorization: Bearer <token>
 * - 统一错误码映射
 * - 401 自动抛出特定错误
 */
import { http } from '@kit.NetworkKit';
import { TokenStore } from '../store/TokenStore';
import { replaceTo } from '../utils/RouterUtils';

// ─── 请求/响应类型 ───

export interface ApiResponse<T> {
  ok: boolean;
  data?: T;
  error?: ApiError;
}

export interface ApiError {
  code: string;
  message: string;
  fields?: Record<string, string>;
}

/** 后端分页响应格式：{items: [...], total: number} */
export interface PagedResponse<T> {
  items: T[];
  total: number;
}

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface RequestOptions {
  method?: HttpMethod;
  headers?: Record<string, string>;
  body?: object;
}

// ─── 自定义错误 ───

export class ApiRequestError extends Error {
  code: string;
  statusCode: number;
  fields?: Record<string, string>;

  constructor(code: string, message: string, statusCode: number, fields?: Record<string, string>) {
    super(message);
    this.name = 'ApiRequestError';
    this.code = code;
    this.statusCode = statusCode;
    this.fields = fields;
  }
}

// 方法映射（PATCH 不存在于 RequestMethod 枚举中，用字符串代替）
function toMethodStr(method: HttpMethod): string {
  if (method === 'GET') {
    return 'GET';
  } else if (method === 'POST') {
    return 'POST';
  } else if (method === 'PUT') {
    return 'PUT';
  } else if (method === 'PATCH') {
    return 'PATCH';
  }
  return 'DELETE';
}

// ─── 客户端 ───

export class HttpClient {
  private static instance: HttpClient;
  private baseUrl: string;

  private constructor() {
    this.baseUrl = '/api/v1';
  }

  static getInstance(): HttpClient {
    if (!HttpClient.instance) {
      HttpClient.instance = new HttpClient();
    }
    return HttpClient.instance;
  }

  setBaseUrl(url: string): void {
    this.baseUrl = url;
  }

  private async request<T>(path: string, options?: RequestOptions): Promise<ApiResponse<T>> {
    const methodStr = toMethodStr(options?.method ?? 'GET');
    const url = `${this.baseUrl}${path}`;

    const httpRequest = http.createHttp();

    try {
      // 构造请求头（不使用展开运算符，ArkTS 严格模式不允许）
      const headerObj: Record<string, string> = {};
      headerObj['Content-Type'] = 'application/json';
      if (options?.headers) {
        const keys = Object.keys(options.headers);
        for (let i = 0; i < keys.length; i++) {
          headerObj[keys[i]] = options.headers[keys[i]];
        }
      }

      // 自动携带 token
      const token = await TokenStore.getInstance().getToken();
      if (token) {
        headerObj['Authorization'] = `Bearer ${token}`;
      }

      // 请求体
      let extraDataStr: string = '';
      if (options?.body) {
        extraDataStr = JSON.stringify(options.body);
      }

      const resp = await httpRequest.request(url, {
        method: methodStr as http.RequestMethod,
        header: headerObj as Object,
        extraData: extraDataStr,
        expectDataType: http.HttpDataType.OBJECT,
      } as http.HttpRequestOptions);

      const statusCode = resp.responseCode;

      // 处理 result（resp.result 类型为 string | Object）
      let resultData: Record<string, Object> | undefined = undefined;
      const rawResult = resp.result;
      if (typeof rawResult === 'object' && rawResult !== null) {
        resultData = rawResult as Record<string, Object>;
      }

      // 处理错误
      if (statusCode >= 400) {
        return this.handleError<T>(resultData, statusCode);
      }

      // 成功：剥掉服务端信封 {ok, data}，只把 data 交给调用方
      return {
        ok: true,
        data: resultData?.['data'] as T,
      } as ApiResponse<T>;
    } catch (err) {
      // 网络错误等
      const error = err as Error;
      return {
        ok: false,
        error: {
          code: 'NETWORK_ERROR',
          message: error.message || '网络请求失败',
        },
      } as ApiResponse<T>;
    } finally {
      httpRequest.destroy();
    }
  }

  private handleError<T>(result: Record<string, Object> | undefined, statusCode: number): ApiResponse<T> {
    // 后端错误格式：{ok:false, error:{code, message, fields:{字段: 提示}}}
    const errObj = result?.['error'] as Record<string, Object> | undefined;
    const code: string = (errObj?.['code'] as string) ?? 'UNKNOWN_ERROR';
    const message: string = (errObj?.['message'] as string) ?? '请求失败';

    let fields: Record<string, string> | undefined;
    const rawFields = errObj?.['fields'];
    if (rawFields !== undefined && rawFields !== null && !Array.isArray(rawFields)) {
      fields = rawFields as Record<string, string>;
    }

    // 401 自动跳转登录页（排除密码错误场景）
    if (statusCode === 401 && code !== 'AUTH_BAD_CREDENTIALS') {
      replaceTo('pages/LoginPage');
    }

    return {
      ok: false,
      error: { code, message, fields },
    } as ApiResponse<T>;
  }

  // ─── 便捷方法 ───

  async get<T>(path: string): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'GET' });
  }

  async post<T>(path: string, body?: object): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'POST', body });
  }

  async patch<T>(path: string, body?: object): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'PATCH', body });
  }

  async put<T>(path: string, body?: object): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'PUT', body });
  }

  async delete_<T>(path: string): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'DELETE' });
  }
}
