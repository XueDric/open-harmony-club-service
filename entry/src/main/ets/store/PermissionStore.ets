/**
 * 权限状态管理
 * 存储 /auth/me 返回的用户信息与权限
 */
import type { MemberSelf, UserPermissions } from '../api/AuthApi';

// update 方法的参数接口
export interface UpdateData {
  user: MemberSelf;
  permissions: UserPermissions;
}

export class PermissionStore {
  private static instance: PermissionStore;

  userInfo: MemberSelf | null = null;
  permissions: UserPermissions | null = null;
  isLoggedIn: boolean = false;

  private constructor() {
    // 单例
  }

  static getInstance(): PermissionStore {
    if (!PermissionStore.instance) {
      PermissionStore.instance = new PermissionStore();
    }
    return PermissionStore.instance;
  }

  /** 保存登录后的用户信息与权限 */
  update(data: UpdateData): void {
    this.userInfo = data.user;
    this.permissions = data.permissions;
    this.isLoggedIn = true;
  }

  /** 清除用户信息（退出登录） */
  clear(): void {
    this.userInfo = null;
    this.permissions = null;
    this.isLoggedIn = false;
  }

  /** 是否为会长 */
  get isPresident(): boolean {
    return this.userInfo?.role === 'president';
  }

  /** 是否为副会长 */
  get isVicePresident(): boolean {
    return this.userInfo?.role === 'vice_president';
  }

  /** 是否为部长 */
  get isLead(): boolean {
    return this.userInfo?.role === 'lead';
  }

  /** 是否为副部长 */
  get isViceLead(): boolean {
    return this.userInfo?.role === 'vice_lead';
  }

  /** 是否为普通成员 */
  get isMember(): boolean {
    return this.userInfo?.role === 'member';
  }

  /** 是否为待分配成员 */
  get isPending(): boolean {
    return this.userInfo?.status === 'pending';
  }

  /** 是否为活跃成员 */
  get isActive(): boolean {
    return this.userInfo?.status === 'active';
  }
}
