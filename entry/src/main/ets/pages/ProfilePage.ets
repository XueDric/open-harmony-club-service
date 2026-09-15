/**
 * 我的 / 设置页（美化版）
 * 本人信息展示、改密码、退出登录
 */
import { AuthApi, ChangePasswordRequest, UserPermissions } from '../api/AuthApi';
import { TokenStore } from '../store/TokenStore';
import { PermissionStore } from '../store/PermissionStore';
import { ApiRequestError } from '../api/HttpClient';
import { replaceTo } from '../utils/RouterUtils';

// ─── 设计令牌 ───
class Colors {
  static readonly primary: string = '#0A59F7';
  static readonly primaryBg: string = '#EEF3FF';
  static readonly bg: string = '#F5F7FA';
  static readonly card: string = '#FFFFFF';
  static readonly textPrimary: string = '#1A1A2E';
  static readonly textSecondary: string = '#666666';
  static readonly textTertiary: string = '#999999';
  static readonly inputBg: string = '#F2F4F7';
  static readonly border: string = '#E8ECF0';
  static readonly danger: string = '#E84026';
  static readonly dangerBg: string = '#FFF0EE';
  static readonly success: string = '#34C759';
  static readonly successBg: string = '#E8F8EE';
  static readonly white: string = '#FFFFFF';
  static readonly overlay: string = 'rgba(0,0,0,0.45)';
}

class Font {
  static readonly title: number = 20;
  static readonly body: number = 16;
  static readonly subtitle: number = 15;
  static readonly caption: number = 13;
  static readonly small: number = 12;
  static readonly large: number = 22;
}

class Radius {
  static readonly card: number = 14;
  static readonly input: number = 10;
  static readonly button: number = 12;
  static readonly dialog: number = 18;
}

@Entry
@Component
struct ProfilePage {
  @State userName: string = '';
  @State userPhone: string = '';
  @State userDept: string = '';
  @State userRole: string = '';
  @State permissionLabels: string[] = [];

  @State showPwdDialog: boolean = false;
  @State oldPassword: string = '';
  @State newPassword: string = '';
  @State confirmNewPassword: string = '';
  @State pwdError: string = '';
  @State changingPwd: boolean = false;
  @State pwdSuccess: boolean = false;

  private authApi: AuthApi = new AuthApi();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private permStore: PermissionStore = PermissionStore.getInstance();

  aboutToAppear(): void {
    const info = this.permStore.userInfo;
    if (info) {
      this.userName = info.name;
      this.userPhone = info.phone;
      this.userDept = info.dept?.name || '未分配';
      this.userRole = info.role || '未分配';
    }
    const perms = this.permStore.permissions;
    if (perms) {
      this.permissionLabels = this.buildPermissionLabels(perms);
    } else {
      this.permissionLabels = ['暂无权限'];
    }
  }

  build() {
    Column() {
      // ─── 标题栏 ───
      Text('我的')
        .fontSize(Font.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(Colors.textPrimary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 16, bottom: 12 })

      Scroll() {
        Column() {
          // ─── 用户信息卡片 ───
          Column() {
            // 头像
            Stack() {
              Circle()
                .width(72)
                .height(72)
                .fill(Colors.primary)

              Text(this.getFirstChar(this.userName))
                .fontSize(32)
                .fontColor(Colors.white)
                .fontWeight(FontWeight.Bold)
            }
            .width(72)
            .height(72)
            .margin({ top: 28 })

            Text(this.userName)
              .fontSize(Font.large)
              .fontWeight(FontWeight.Bold)
              .fontColor(Colors.textPrimary)
              .margin({ top: 14 })

            // 角色标签
            Row() {
              Text(this.roleLabel(this.userRole))
                .fontSize(Font.caption)
                .fontColor(Colors.primary)
                .fontWeight(FontWeight.Medium)
            }
            .backgroundColor(Colors.primaryBg)
            .borderRadius(12)
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .margin({ top: 8 })

            // 部门 + 手机号
            Column() {
              // 部门行
              Row() {
                Text('🏢')
                  .fontSize(14)
                Text(this.userDept)
                  .fontSize(Font.subtitle)
                  .fontColor(Colors.textSecondary)
                  .margin({ left: 8 })
              }
              .margin({ top: 16 })

              // 手机号行（脱敏显示）
              Row() {
                Text('📱')
                  .fontSize(14)
                Text(this.maskPhone(this.userPhone))
                  .fontSize(Font.subtitle)
                  .fontColor(Colors.textSecondary)
                  .margin({ left: 8 })
              }
              .margin({ top: 8 })
            }
            .padding({ bottom: 24 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(Colors.card)
          .borderRadius(Radius.card)
          .margin({ bottom: 12 })

          // ─── 我的权限卡片 ───
          Column() {
            Row() {
              Text('🔑')
                .fontSize(16)
              Text('我的权限')
                .fontSize(Font.body)
                .fontColor(Colors.textPrimary)
                .fontWeight(FontWeight.Medium)
                .margin({ left: 10 })
            }
            .width('100%')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.permissionLabels, (label: string) => {
                Text(label)
                  .fontSize(Font.small)
                  .fontColor(Colors.primary)
                  .backgroundColor(Colors.primaryBg)
                  .borderRadius(8)
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .margin({ right: 8, top: 10 })
              }, (label: string) => label)
            }
            .width('100%')
            .margin({ top: 12 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Colors.card)
          .borderRadius(Radius.card)
          .margin({ bottom: 12 })

          // ─── 菜单卡片 ───
          Column() {
            // 修改密码
            Row() {
              Stack() {
                Circle()
                  .width(32)
                  .height(32)
                  .fill(Colors.primaryBg)
                Text('🔒')
                  .fontSize(16)
              }
              .width(32)
              .height(32)

              Text('修改密码')
                .fontSize(Font.body)
                .fontColor(Colors.textPrimary)
                .fontWeight(FontWeight.Medium)
                .margin({ left: 12 })

              Blank()

              Text('›')
                .fontSize(22)
                .fontColor(Colors.textTertiary)
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.showPwdDialog = true;
              this.pwdError = '';
              this.pwdSuccess = false;
              this.oldPassword = '';
              this.newPassword = '';
              this.confirmNewPassword = '';
            })
          }
          .width('100%')
          .backgroundColor(Colors.card)
          .borderRadius(Radius.card)
          .margin({ bottom: 12 })

          // ─── 退出登录按钮 ───
          Button() {
            Row() {
              Text('退出登录')
                .fontSize(Font.body)
                .fontWeight(FontWeight.Medium)
                .fontColor(Colors.danger)
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
          }
          .width('100%')
          .height(50)
          .backgroundColor(Colors.card)
          .borderRadius(Radius.button)
          .onClick(() => this.handleLogout())
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 40 })
      }
      .layoutWeight(1)

      // ─── 修改密码弹窗 ───
      if (this.showPwdDialog) {
        Column() {
          Column() {
            // 标题
            Text('修改密码')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(Colors.textPrimary)
              .margin({ top: 28, bottom: 4 })

            Text('请先验证当前密码，再设置新密码')
              .fontSize(Font.caption)
              .fontColor(Colors.textTertiary)
              .margin({ bottom: 20 })

            if (this.pwdSuccess) {
              // ─── 成功提示 ───
              Column() {
                Stack() {
                  Circle()
                    .width(56)
                    .height(56)
                    .fill(Colors.successBg)
                  Text('✓')
                    .fontSize(28)
                    .fontColor(Colors.success)
                    .fontWeight(FontWeight.Bold)
                }
                .width(56)
                .height(56)
                .margin({ top: 8 })

                Text('密码修改成功')
                  .fontSize(Font.body)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Colors.textPrimary)
                  .margin({ top: 16 })

                Button('确 定')
                  .width('100%')
                  .height(46)
                  .backgroundColor(Colors.primary)
                  .borderRadius(Radius.button)
                  .fontColor(Colors.white)
                  .fontSize(Font.body)
                  .fontWeight(FontWeight.Medium)
                  .margin({ top: 24 })
                  .onClick(() => {
                    this.showPwdDialog = false;
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            } else {
              // ─── 表单 ───
              // 当前密码
              TextInput({ placeholder: '当前密码', text: this.oldPassword })
                .type(InputType.Password)
                .onChange((val: string) => {
                  this.oldPassword = val;
                  this.pwdError = '';
                })
                .height(48)
                .backgroundColor(Colors.inputBg)
                .borderRadius(Radius.input)
                .padding({ left: 16 })
                .placeholderColor(Colors.textTertiary)
                .fontSize(Font.body)

              // 新密码
              TextInput({ placeholder: '新密码（至少6位）', text: this.newPassword })
                .type(InputType.Password)
                .onChange((val: string) => {
                  this.newPassword = val;
                  this.pwdError = '';
                })
                .height(48)
                .backgroundColor(Colors.inputBg)
                .borderRadius(Radius.input)
                .padding({ left: 16 })
                .placeholderColor(Colors.textTertiary)
                .fontSize(Font.body)
                .margin({ top: 12 })

              // 确认新密码
              TextInput({ placeholder: '确认新密码', text: this.confirmNewPassword })
                .type(InputType.Password)
                .onChange((val: string) => {
                  this.confirmNewPassword = val;
                  this.pwdError = '';
                })
                .height(48)
                .backgroundColor(Colors.inputBg)
                .borderRadius(Radius.input)
                .padding({ left: 16 })
                .placeholderColor(Colors.textTertiary)
                .fontSize(Font.body)
                .margin({ top: 12 })

              // 错误提示
              if (this.pwdError.length > 0) {
                Row() {
                  Text('⚠ ')
                    .fontSize(Font.caption)
                    .fontColor(Colors.danger)
                  Text(this.pwdError)
                    .fontSize(Font.caption)
                    .fontColor(Colors.danger)
                }
                .width('100%')
                .padding({ left: 4, top: 10 })
              }

              // 按钮组
              Row() {
                Button('取 消')
                  .height(46)
                  .backgroundColor(Colors.inputBg)
                  .fontColor(Colors.textSecondary)
                  .fontSize(Font.body)
                  .fontWeight(FontWeight.Medium)
                  .borderRadius(Radius.button)
                  .layoutWeight(1)
                  .onClick(() => {
                    this.showPwdDialog = false;
                  })

                Button() {
                  if (this.changingPwd) {
                    LoadingProgress()
                      .width(20)
                      .height(20)
                      .color(Colors.white)
                  } else {
                    Text('确 认')
                      .fontSize(Font.body)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Colors.white)
                  }
                }
                .height(46)
                .backgroundColor(Colors.primary)
                .borderRadius(Radius.button)
                .layoutWeight(1)
                .margin({ left: 12 })
                .enabled(!this.changingPwd)
                .onClick(() => this.handleChangePassword())
              }
              .margin({ top: 24, bottom: 12 })
            }
          }
          .width('86%')
          .padding({ left: 24, right: 24, bottom: 24 })
          .backgroundColor(Colors.white)
          .borderRadius(Radius.dialog)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Colors.overlay)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          if (!this.changingPwd) {
            this.showPwdDialog = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Colors.bg)
  }

  roleLabel(role: string): string {
    if (role === 'president') {
      return '会长';
    }
    if (role === 'vice_president') {
      return '副会长';
    }
    if (role === 'lead') {
      return '部长';
    }
    if (role === 'vice_lead') {
      return '副部长';
    }
    if (role === 'member') {
      return '成员';
    }
    return role || '未分配';
  }

  getFirstChar(name: string): string {
    if (name.length > 0) {
      return name.substring(0, 1);
    }
    return '?';
  }

  maskPhone(phone: string): string {
    if (phone.length === 11) {
      return phone.substring(0, 3) + '****' + phone.substring(7);
    }
    return phone;
  }

  buildPermissionLabels(perms: UserPermissions): string[] {
    const labels: string[] = [];
    if (perms.view_scope === 'all') {
      labels.push('查看全部数据');
    } else if (perms.view_scope === 'dept') {
      labels.push('查看本部门');
    } else if (perms.view_scope === 'self') {
      labels.push('查看本人');
    }
    if (perms.manage_members) {
      labels.push('管理成员');
    }
    if (perms.set_role) {
      labels.push('分配角色');
    }
    if (perms.create_plan) {
      labels.push('创建计划');
    }
    if (perms.create_task) {
      labels.push('创建任务');
    }
    if (perms.update_any_task) {
      labels.push('更新任意任务');
    }
    if (labels.length === 0) {
      labels.push('暂无权限');
    }
    return labels;
  }

  async handleChangePassword(): Promise<void> {
    if (!this.oldPassword) {
      this.pwdError = '请输入当前密码';
      return;
    }
    if (!this.newPassword || this.newPassword.length < 6) {
      this.pwdError = '新密码至少6位';
      return;
    }
    if (this.newPassword !== this.confirmNewPassword) {
      this.pwdError = '两次密码输入不一致';
      return;
    }

    this.changingPwd = true;
    try {
      const req: ChangePasswordRequest = {
        old_password: this.oldPassword,
        new_password: this.newPassword,
      };
      const resp = await this.authApi.changePassword(req);
      if (resp.ok) {
        this.pwdSuccess = true;
      }
    } catch (err) {
      if (err instanceof ApiRequestError) {
        this.pwdError = err.message;
      } else {
        this.pwdError = '修改失败，请重试';
      }
    } finally {
      this.changingPwd = false;
    }
  }

  async handleLogout(): Promise<void> {
    try {
      await this.authApi.logout();
    } catch {
      // ignore
    }
    await this.tokenStore.clearToken();
    this.permStore.clear();
    replaceTo('pages/LoginPage');
  }
}
