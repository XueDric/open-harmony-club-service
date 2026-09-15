/**
 * Token 持久化存储
 * 使用 @kit.ArkData 的 Preferences API
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const TOKEN_KEY = 'auth_token';

export class TokenStore {
  private static instance: TokenStore;
  private preferences_: preferences.Preferences | null = null;
  private cachedToken: string | null = null;

  private constructor() {
    // 单例
  }

  static getInstance(): TokenStore {
    if (!TokenStore.instance) {
      TokenStore.instance = new TokenStore();
    }
    return TokenStore.instance;
  }

  /**
   * 初始化 Preferences，需传入 context
   */
  async init(context: common.Context): Promise<void> {
    if (this.preferences_) {
      return;
    }
    const dataDir = context.preferencesDir;
    this.preferences_ = await preferences.getPreferences(context, 'app_preferences');
    // 启动时读取缓存
    const val = await this.preferences_.get(TOKEN_KEY, '');
    this.cachedToken = val as string || null;
  }

  /**
   * 获取 token
   */
  async getToken(): Promise<string | null> {
    if (this.cachedToken) {
      return this.cachedToken;
    }
    // 未缓存时从持久化读取
    if (!this.preferences_) {
      return null;
    }
    const val = await this.preferences_.get(TOKEN_KEY, '');
    this.cachedToken = val as string || null;
    return this.cachedToken;
  }

  /**
   * 保存 token
   */
  async setToken(token: string): Promise<void> {
    this.cachedToken = token;
    if (!this.preferences_) {
      return;
    }
    await this.preferences_.put(TOKEN_KEY, token);
    await this.preferences_.flush();
  }

  /**
   * 清除 token（退出登录）
   */
  async clearToken(): Promise<void> {
    this.cachedToken = null;
    if (!this.preferences_) {
      return;
    }
    await this.preferences_.delete(TOKEN_KEY);
    await this.preferences_.flush();
  }

  /**
   * 是否已登录（有 token）
   */
  async isLoggedIn(): Promise<boolean> {
    const token = await this.getToken();
    return token !== null && token.length > 0;
  }
}
