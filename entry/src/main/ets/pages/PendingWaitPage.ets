/**
 * 等待分配页（美化版）
 * pending 账号登录/注册后跳转至此页面
 * 提示"等待管理员分配" + 可退出登录
 */
import { TokenStore } from '../store/TokenStore';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { AuthApi } from '../api/AuthApi';
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
  static readonly danger: string = '#E84026';
  static readonly white: string = '#FFFFFF';
  static readonly pendingBg: string = '#FFF8E1';
  static readonly pendingBorder: string = '#FFE082';
  static readonly pendingText: string = '#F57F17';
}

class Font {
  static readonly title: number = 22;
  static readonly body: number = 16;
  static readonly subtitle: number = 15;
  static readonly caption: number = 13;
  static readonly small: number = 12;
}

class Radius {
  static readonly card: number = 16;
  static readonly button: number = 12;
}

@Entry
@Component
struct PendingWaitPage {
  @State userName: string = '';
  @State loading: boolean = false;

  private permStore: PermissionStore = PermissionStore.getInstance();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private authApi: AuthApi = new AuthApi();
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.userName = this.permStore.userInfo?.name ?? '新成员';
    // 启动轮询：每 10 秒检查是否已分配
    this.startPolling();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  startPolling(): void {
    this.pollTimer = setInterval(async () => {
      try {
        const resp = await this.authApi.me();
        if (resp.ok && resp.data) {
          const updateData: UpdateData = {
            user: resp.data.member,
            permissions: resp.data.permissions,
          };
          this.permStore.update(updateData);
          if (!this.permStore.isPending) {
            this.stopPolling();
            replaceTo('pages/Index');
          }
        }
      } catch (_) {
        // 静默处理轮询错误
      }
    }, 10000);
  }

  stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  build() {
    Column() {
      // ─── 顶部状态栏占位 ───
      Column()
        .width('100%')
        .height(40)

      Scroll() {
        Column() {
          // ─── 主要卡片 ───
          Column() {
            // 等待图标
            Stack() {
              Circle()
                .width(88)
                .height(88)
                .fill(Colors.pendingBg)
              Text('⏳')
                .fontSize(44)
            }
            .width(88)
            .height(88)
            .margin({ top: 40 })

            // 欢迎文字
            Text(`${this.userName}，你好！`)
              .fontSize(Font.title)
              .fontWeight(FontWeight.Bold)
              .fontColor(Colors.textPrimary)
              .margin({ top: 24 })

            Text('你的账号已成功注册')
              .fontSize(Font.subtitle)
              .fontColor(Colors.textSecondary)
              .margin({ top: 8 })

            // 等待状态标签
            Row() {
              Text('⏳ 等待分配')
                .fontSize(Font.caption)
                .fontColor(Colors.pendingText)
                .fontWeight(FontWeight.Medium)
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            }
            .backgroundColor(Colors.pendingBg)
            .borderRadius(20)
            .padding(2)
            .margin({ top: 20 })

            // 说明卡片
            Column() {
              Text('账号正在等待管理员分配部门与角色')
                .fontSize(Font.body)
                .fontColor(Colors.textPrimary)
                .fontWeight(FontWeight.Medium)
                .textAlign(TextAlign.Center)

              Text('分配完成后你将可以正常使用全部功能')
                .fontSize(Font.caption)
                .fontColor(Colors.textTertiary)
                .textAlign(TextAlign.Center)
                .margin({ top: 8 })
            }
            .width('100%')
            .padding(20)
            .backgroundColor(Colors.bg)
            .borderRadius(Radius.card)
            .margin({ top: 24 })
          }
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 32 })
          .backgroundColor(Colors.card)
          .borderRadius(Radius.card)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 20 })
      }
      .layoutWeight(1)

      // ─── 底部操作区 ───
      Column() {
        Text('系统每 10 秒自动检查状态')
          .fontSize(Font.small)
          .fontColor(Colors.textTertiary)
          .margin({ bottom: 12 })

        Button() {
          if (this.loading) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(Colors.danger)
          } else {
            Text('退出登录')
              .fontSize(Font.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(Colors.danger)
          }
        }
        .width('100%')
        .height(50)
        .backgroundColor(Colors.white)
        .border({ width: 1, color: Colors.danger })
        .borderRadius(Radius.button)
        .enabled(!this.loading)
        .onClick(() => this.handleLogout())
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 40 })
      .backgroundColor(Colors.card)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Colors.bg)
    .alignItems(HorizontalAlign.Center)
  }

  async handleLogout(): Promise<void> {
    this.loading = true;
    try {
      await this.authApi.logout();
    } catch (_) {
      // 即使后端注销失败，也清除本地 token
    }
    this.stopPolling();
    await this.tokenStore.clearToken();
    replaceTo('pages/LoginPage');
  }
}
