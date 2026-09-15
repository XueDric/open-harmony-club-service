/**
 * 注册页（美化版）
 * 注册口令 + 手机号 + 姓名 + 密码 → 注册成功跳等待分配页
 */
import { AuthApi, RegisterRequest } from '../api/AuthApi';
import { TokenStore } from '../store/TokenStore';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { ApiRequestError } from '../api/HttpClient';
import { replaceTo, backPage } from '../utils/RouterUtils';

// ─── 设计令牌（与登录页统一） ───
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
  static readonly success: string = '#34C759';
  static readonly white: string = '#FFFFFF';
}

class Font {
  static readonly title: number = 26;
  static readonly subtitle: number = 15;
  static readonly body: number = 16;
  static readonly caption: number = 13;
  static readonly small: number = 12;
}

class Radius {
  static readonly input: number = 12;
  static readonly button: number = 12;
}

@Entry
@Component
struct RegisterPage {
  @State code: string = '';
  @State phone: string = '';
  @State name: string = '';
  @State password: string = '';
  @State confirmPassword: string = '';
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State passwordVisible: boolean = false;
  @State confirmVisible: boolean = false;

  private authApi: AuthApi = new AuthApi();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private permStore: PermissionStore = PermissionStore.getInstance();

  build() {
    Column() {
      // ─── 顶部导航 ───
      Row() {
        Text('‹ 返回登录')
          .fontSize(Font.body)
          .fontColor(Colors.primary)
          .fontWeight(FontWeight.Medium)
          .onClick(() => backPage())
      }
      .width('100%')
      .padding({ left: 16, top: 16 })

      Scroll() {
        Column() {
          // ─── 标题区域 ───
          Column() {
            Text('加入社团')
              .fontSize(Font.title)
              .fontWeight(FontWeight.Bold)
              .fontColor(Colors.textPrimary)

            Text('填写以下信息完成注册')
              .fontSize(Font.subtitle)
              .fontColor(Colors.textSecondary)
              .margin({ top: 8 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 28, top: 20 })

          // ─── 表单卡片 ───
          Column() {
            // 注册口令
            Column() {
              Text('注册口令')
                .fontSize(Font.caption)
                .fontColor(Colors.textSecondary)
                .margin({ bottom: 8 })

              TextInput({ placeholder: '请输入会长提供的注册口令', text: this.code })
                .maxLength(32)
                .onChange((val: string) => {
                  this.code = val;
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

            // 分割线
            Column()
              .width('100%')
              .height(1)
              .backgroundColor(Colors.border)
              .margin({ top: 24, bottom: 8 })

            // 手机号
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
            .margin({ top: 4 })

            // 姓名
            Column() {
              Text('姓名')
                .fontSize(Font.caption)
                .fontColor(Colors.textSecondary)
                .margin({ bottom: 8 })

              TextInput({ placeholder: '请输入真实姓名', text: this.name })
                .maxLength(20)
                .onChange((val: string) => {
                  this.name = val;
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
            .margin({ top: 20 })

            // 密码
            Column() {
              Text('密码')
                .fontSize(Font.caption)
                .fontColor(Colors.textSecondary)
                .margin({ bottom: 8 })

              Row() {
                TextInput({ placeholder: '至少6位密码', text: this.password })
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
            .margin({ top: 20 })

            // 确认密码
            Column() {
              Text('确认密码')
                .fontSize(Font.caption)
                .fontColor(Colors.textSecondary)
                .margin({ bottom: 8 })

              Row() {
                TextInput({ placeholder: '再次输入密码', text: this.confirmPassword })
                  .type(this.confirmVisible ? InputType.Normal : InputType.Password)
                  .maxLength(32)
                  .onChange((val: string) => {
                    this.confirmPassword = val;
                    this.errorMsg = '';
                  })
                  .layoutWeight(1)
                  .padding({ left: 16, right: 8 })
                  .height(50)
                  .backgroundColor(Colors.inputBg)
                  .borderRadius(Radius.input)
                  .placeholderColor(Colors.textTertiary)
                  .fontSize(Font.body)

                Text(this.confirmVisible ? '🙈' : '👁')
                  .fontSize(18)
                  .padding({ right: 16 })
                  .onClick(() => {
                    this.confirmVisible = !this.confirmVisible;
                  })
              }
              .width('100%')
              .backgroundColor(Colors.inputBg)
              .borderRadius(Radius.input)
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .margin({ top: 20 })

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
              .padding({ left: 4, top: 12 })
            }

            // 注册按钮
            Button() {
              if (this.loading) {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color(Colors.white)
              } else {
                Text('注 册')
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
            .onClick(() => this.handleRegister())
          }
          .width('100%')
          .padding({ left: 28, right: 28, top: 28, bottom: 24 })
          .margin({ top: 8 })
        }
        .width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Colors.bg)
  }

  async handleRegister(): Promise<void> {
    if (!this.code) {
      this.errorMsg = '请输入注册口令';
      return;
    }
    if (!this.phone || this.phone.length !== 11) {
      this.errorMsg = '请输入正确的手机号';
      return;
    }
    if (!this.name) {
      this.errorMsg = '请输入姓名';
      return;
    }
    if (!this.password || this.password.length < 6) {
      this.errorMsg = '密码至少6位';
      return;
    }
    if (this.password !== this.confirmPassword) {
      this.errorMsg = '两次密码输入不一致';
      return;
    }

    this.loading = true;
    this.errorMsg = '';

    try {
      const req: RegisterRequest = {
        code: this.code,
        phone: this.phone,
        name: this.name,
        password: this.password,
      };
      const resp = await this.authApi.register(req);

      if (resp.ok && resp.data) {
        await this.tokenStore.setToken(resp.data.token);
        const updateData: UpdateData = {
          user: resp.data.member,
          permissions: resp.data.permissions,
        };
        this.permStore.update(updateData);

        replaceTo('pages/PendingWaitPage');
      }
    } catch (err) {
      if (err instanceof ApiRequestError) {
        this.errorMsg = err.message;
      } else {
        this.errorMsg = '注册失败，请检查网络后重试';
      }
    } finally {
      this.loading = false;
    }
  }
}
