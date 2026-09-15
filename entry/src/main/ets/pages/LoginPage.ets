/**
 * 登录页（美化版）
 * 手机号 + 密码登录 → 根据权限跳转首页/等待页
 */
import { AuthApi, LoginRequest } from '../api/AuthApi';
import { TokenStore } from '../store/TokenStore';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { ApiRequestError } from '../api/HttpClient';
import { replaceTo, pushTo } from '../utils/RouterUtils';

// ─── 设计令牌 ───
class Colors {
  static readonly primary: string = '#0A59F7';
  static readonly primaryDark: string = '#0845C4';
  static readonly primaryBg: string = '#EEF3FF';
  static readonly bg: string = '#F5F7FA';
  static readonly card: string = '#FFFFFF';
  static readonly textPrimary: string = '#1A1A2E';
  static readonly textSecondary: string = '#666666';
  static readonly textTertiary: string = '#999999';
  static readonly inputBg: string = '#F2F4F7';
  static readonly border: string = '#E8ECF0';
  static readonly danger: string = '#E84026';
  static readonly white: string = '#FFFFFF';
}

class Font {
  static readonly title: number = 28;
  static readonly subtitle: number = 15;
  static readonly body: number = 16;
  static readonly caption: number = 13;
  static readonly small: number = 12;
}

class Radius {
  static readonly input: number = 12;
  static readonly button: number = 12;
  static readonly card: number = 16;
}

@Entry
@Component
struct LoginPage {
  @State phone: string = '';
  @State password: string = '';
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State passwordVisible: boolean = false;

  private authApi: AuthApi = new AuthApi();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private permStore: PermissionStore = PermissionStore.getInstance();

  build() {
    Column() {
      // ─── 顶部装饰区域 ───
      Column() {
        // 图标
        Stack() {
          Circle()
            .width(72)
            .height(72)
            .fill(Colors.primaryBg)
          Text('🏫')
            .fontSize(36)
        }
        .width(72)
        .height(72)
        .margin({ top: 60 })

        Text('社团管家')
          .fontSize(Font.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Colors.textPrimary)
          .margin({ top: 16 })

        Text('登录你的账号，开始管理社团事务')
          .fontSize(Font.subtitle)
          .fontColor(Colors.textSecondary)
          .margin({ top: 8 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      // ─── 表单卡片 ───
      Column() {
        // 手机号输入
        Column() {
          Text('手机号')
            .fontSize(Font.caption)
            .fontColor(Colors.textSecondary)
            .margin({ bottom: 8 })

          TextInput({ placeholder: '请输入手机号', text: this.phone })
            .type(InputType.PhoneNumber)
            .maxLength(11)
            .onChange((val: string) => {
              this.phone = val;
              this.errorMsg = '';
            })
            .padding({ left: 16, right: 16 })
            .height(50)
            .backgroundColor(Colors.inputBg)
            .borderRadius(Radius.input)
            .placeholderColor(Colors.textTertiary)
            .fontSize(Font.body)
        }
        .width('100%')

        // 密码输入
        Column() {
          Text('密码')
            .fontSize(Font.caption)
            .fontColor(Colors.textSecondary)
            .margin({ top: 20, bottom: 8 })

          Row() {
            TextInput({ placeholder: '请输入密码', text: this.password })
              .type(this.passwordVisible ? InputType.Normal : InputType.Password)
              .maxLength(32)
              .onChange((val: string) => {
                this.password = val;
                this.errorMsg = '';
              })
              .layoutWeight(1)
              .padding({ left: 16, right: 8 })
              .height(50)
              .backgroundColor(Colors.inputBg)
              .borderRadius(Radius.input)
              .placeholderColor(Colors.textTertiary)
              .fontSize(Font.body)

            // 密码可见切换
            Text(this.passwordVisible ? '🙈' : '👁')
              .fontSize(18)
              .padding({ right: 16 })
              .onClick(() => {
                this.passwordVisible = !this.passwordVisible;
              })
          }
          .width('100%')
          .backgroundColor(Colors.inputBg)
          .borderRadius(Radius.input)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')

        // 错误提示
        if (this.errorMsg.length > 0) {
          Row() {
            Text('⚠ ')
              .fontSize(Font.caption)
              .fontColor(Colors.danger)
            Text(this.errorMsg)
              .fontSize(Font.caption)
              .fontColor(Colors.danger)
          }
          .width('100%')
          .padding({ left: 4, top: 10 })
        }

        // 登录按钮
        Button() {
          if (this.loading) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(Colors.white)
          } else {
            Text('登 录')
              .fontSize(Font.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(Colors.white)
          }
        }
        .width('100%')
        .height(50)
        .backgroundColor(Colors.primary)
        .borderRadius(Radius.button)
        .margin({ top: 28 })
        .enabled(!this.loading)
        .onClick(() => this.handleLogin())

        // ─── 分隔线 ───
        Row() {
          Divider()
            .height(1)
            .color(Colors.border)
            .layoutWeight(1)
          Text('或')
            .fontSize(Font.caption)
            .fontColor(Colors.textTertiary)
            .margin({ left: 16, right: 16 })
          Divider()
            .height(1)
            .color(Colors.border)
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 24 })
        .alignItems(VerticalAlign.Center)

        // 注册入口
        Text('还没有账号？立即注册')
          .fontSize(Font.subtitle)
          .fontColor(Colors.primary)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 20 })
          .onClick(() => {
            pushTo('pages/RegisterPage');
          })

        // 忘记密码提示
        Text('忘记密码？请联系会长重置')
          .fontSize(Font.small)
          .fontColor(Colors.textTertiary)
          .margin({ top: 16 })
      }
      .width('100%')
      .padding({ left: 28, right: 28, top: 36, bottom: 24 })
      .margin({ top: 32 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Colors.bg)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
  }

  async handleLogin(): Promise<void> {
    if (!this.phone || this.phone.length !== 11) {
      this.errorMsg = '请输入正确的手机号';
      return;
    }
    if (!this.password || this.password.length < 6) {
      this.errorMsg = '密码至少6位';
      return;
    }

    this.loading = true;
    this.errorMsg = '';

    try {
      const req: LoginRequest = { phone: this.phone, password: this.password };
      const resp = await this.authApi.login(req);

      if (resp.ok && resp.data) {
        await this.tokenStore.setToken(resp.data.token);
        const updateData: UpdateData = {
          user: resp.data.member,
          permissions: resp.data.permissions,
        };
        this.permStore.update(updateData);

        if (this.permStore.isPending) {
          replaceTo('pages/PendingWaitPage');
        } else {
          replaceTo('pages/Index');
        }
      }
    } catch (err) {
      if (err instanceof ApiRequestError) {
        this.errorMsg = err.message;
      } else {
        this.errorMsg = '登录失败，请检查网络后重试';
      }
    } finally {
      this.loading = false;
    }
  }
}
