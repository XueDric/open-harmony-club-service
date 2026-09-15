/**
 * 启动页 + 路由守卫（美化版）
 * App 启动 → 读 token → GET /auth/me → 判断跳转
 */
import { AuthApi } from '../api/AuthApi';
import { TokenStore } from '../store/TokenStore';
import { PermissionStore } from '../store/PermissionStore';
import { ApiRequestError } from '../api/HttpClient';
import { replaceTo } from '../utils/RouterUtils';

// ─── 开发预览开关（调试用，正式发布前请改回 ''） ───
// 设为空字符串走正常路由守卫；
// 想直接预览某个页面，改成对应路径即可，例如：
//   'pages/Index'
//   'pages/ProfilePage'
//   'pages/PendingWaitPage'
const PREVIEW_PAGE: string = '';

// ─── 设计令牌 ───
class Colors {
  static readonly primary: string = '#0A59F7';
  static readonly primaryBg: string = '#EEF3FF';
  static readonly bg: string = '#FFFFFF';
  static readonly textPrimary: string = '#1A1A2E';
  static readonly textSecondary: string = '#666666';
  static readonly textTertiary: string = '#999999';
  static readonly danger: string = '#E84026';
}

class Font {
  static readonly appName: number = 34;
  static readonly subtitle: number = 15;
  static readonly caption: number = 13;
}

@Entry
@Component
struct SplashPage {
  @State statusText: string = '加载中...';
  @State showRetry: boolean = false;
  @State loading: boolean = true;

  private authApi: AuthApi = new AuthApi();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private permStore: PermissionStore = PermissionStore.getInstance();

  aboutToAppear(): void {
    this.checkAuth();
  }

  build() {
    Column() {
      // ─── Logo 区域 ───
      Column() {
        // 图标背景
        Stack() {
          Circle()
            .width(96)
            .height(96)
            .fill(Colors.primaryBg)

          Text('🏫')
            .fontSize(48)
        }
        .width(96)
        .height(96)

        Text('社团管家')
          .fontSize(Font.appName)
          .fontWeight(FontWeight.Bold)
          .fontColor(Colors.primary)
          .margin({ top: 20 })

        Text('高效管理社团事务')
          .fontSize(Font.subtitle)
          .fontColor(Colors.textTertiary)
          .margin({ top: 8 })

        // ─── 加载指示器 ───
        if (!this.showRetry) {
          Column() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(Colors.primary)
              .margin({ bottom: 12 })

            Text(this.statusText)
              .fontSize(Font.caption)
              .fontColor(Colors.textTertiary)
          }
          .margin({ top: 80 })
        }

        // ─── 重试按钮 ───
        if (this.showRetry) {
          Column() {
            Text(this.statusText)
              .fontSize(Font.caption)
              .fontColor(Colors.danger)
              .margin({ bottom: 16 })

            Button() {
              Text('重新加载')
                .fontSize(Font.subtitle)
                .fontWeight(FontWeight.Medium)
                .fontColor(Colors.primary)
            }
            .width(160)
            .height(44)
            .backgroundColor(Colors.primaryBg)
            .borderRadius(22)
            .onClick(() => {
              this.showRetry = false;
              this.statusText = '加载中...';
              this.checkAuth();
            })
          }
          .margin({ top: 80 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)

      // ─── 底部版本信息 ───
      Text('v1.0 · 鸿蒙俱乐部')
        .fontSize(11)
        .fontColor(Colors.textTertiary)
        .margin({ bottom: 40 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Colors.bg)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  async checkAuth(): Promise<void> {
    // 开发预览模式：直接跳转到指定页面，跳过登录校验
    if (PREVIEW_PAGE !== '') {
      this.navigateTo(PREVIEW_PAGE);
      return;
    }

    try {
      const hasToken = await this.tokenStore.isLoggedIn();

      if (!hasToken) {
        this.navigateTo('pages/LoginPage');
        return;
      }

      const resp = await this.authApi.me();

      if (resp.ok && resp.data) {
        this.permStore.update({
          user: resp.data.member,
          permissions: resp.data.permissions,
        });

        if (resp.data.permissions.view_scope === 'none') {
          this.navigateTo('pages/PendingWaitPage');
        } else {
          this.navigateTo('pages/Index');
        }
      } else {
        await this.tokenStore.clearToken();
        this.navigateTo('pages/LoginPage');
      }
    } catch (err) {
      if (err instanceof ApiRequestError) {
        if (err.code === 'AUTH_TOKEN_EXPIRED' || err.code === 'AUTH_TOKEN_INVALID') {
          await this.tokenStore.clearToken();
          this.permStore.clear();
          this.navigateTo('pages/LoginPage');
          return;
        }
        this.statusText = '网络连接失败，请检查网络';
        this.showRetry = true;
      } else {
        this.statusText = '加载失败，请重试';
        this.showRetry = true;
      }
    } finally {
      this.loading = false;
    }
  }

  private navigateTo(url: string): void {
    setTimeout(() => {
      replaceTo(url);
    }, 800);
  }
}
