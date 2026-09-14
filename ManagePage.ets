// 管理页面（B同学负责）
// 包含：部门管理、注册口令、招募链接、会长移交等

interface Dept {
  id: number;
  name: string;
  memberCount: number;
}

interface InviteLink {
  id: string;
  deptName: string;
  url: string;
  enabled: boolean;
  createdAt: string;
}

// ====== 假数据 ======
const DEPTS: Dept[] = [
  { id: 0, name: '主席团', memberCount: 3 },
  { id: 1, name: '课题部', memberCount: 4 },
  { id: 2, name: '运营部', memberCount: 3 },
  { id: 3, name: '宣传部', memberCount: 3 },
];

const INVITE_LINKS: InviteLink[] = [
  { id: 'link001', deptName: '课题部', url: 'club.example.com/join/abc123', enabled: true, createdAt: '2026-09-10' },
  { id: 'link002', deptName: '运营部', url: 'club.example.com/join/def456', enabled: true, createdAt: '2026-09-12' },
  { id: 'link003', deptName: '宣传部', url: 'club.example.com/join/ghi789', enabled: false, createdAt: '2026-09-08' },
];

@Component
struct SectionHeader {
  title: string = '';
  actionText: string = '';
  onAction: () => void = () => {};

  build() {
    Row() {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#333333')

      Blank()

      if (this.actionText.length > 0) {
        Text(this.actionText)
          .fontSize(14)
          .fontColor('#1E88E5')
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 20, bottom: 8 })
  }
}

// ====== 部门管理 ======
@Component
struct DeptManageSection {
  @State depts: Dept[] = DEPTS;
  @State showAddDialog: boolean = false;

  build() {
    Column() {
      SectionHeader({
        title: '部门管理',
        actionText: '+ 新建部门',
        onAction: () => {
          this.showAddDialog = true;
        }
      })

      Column() {
        ForEach(this.depts, (dept: Dept) => {
          Row() {
            Column() {
              Text(dept.name)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
              Text(`${dept.memberCount} 人`)
                .fontSize(12)
                .fontColor('#999999')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('编辑')
              .fontSize(14)
              .fontColor('#1E88E5')
              .margin({ right: 16 })

            Text('删除')
              .fontSize(14)
              .fontColor('#E53935')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .margin({ bottom: 1 })
        }, (dept: Dept) => dept.id.toString())
      }
      .backgroundColor(Color.White)
      .borderRadius(8)
      .margin({ left: 16, right: 16 })
    }
    .width('100%')
  }
}

// ====== 注册口令 ======
@Component
struct RegisterConfigSection {
  @State code: string = 'CLUB-2026';
  @State showRotateConfirm: boolean = false;

  build() {
    Column() {
      SectionHeader({ title: '注册口令', actionText: '' })

      Column() {
        Row() {
          Column() {
            Text('当前口令')
              .fontSize(12)
              .fontColor('#999999')
            Text(this.code)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1E88E5')
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('复制')
            .type(ButtonType.Capsule)
            .fontSize(12)
            .height(32)
        }
        .width('100%')
        .padding(16)

        Divider()
          .color('#EEEEEE')

        Row() {
          Button('更换口令')
            .layoutWeight(1)
            .backgroundColor('#F5F5F5')
            .fontColor('#666666')
            .margin({ right: 8 })

          Button('随机轮换')
            .layoutWeight(1)
            .onClick(() => {
              this.showRotateConfirm = true;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      }
      .backgroundColor(Color.White)
      .borderRadius(8)
      .margin({ left: 16, right: 16 })
    }
    .width('100%')
  }
}

// ====== 招募链接 ======
@Component
struct InviteLinkSection {
  @State links: InviteLink[] = INVITE_LINKS;

  toggleEnabled(id: string) {
    const idx = this.links.findIndex(l => l.id === id);
    if (idx >= 0) {
      this.links[idx].enabled = !this.links[idx].enabled;
      this.links = [...this.links];
    }
  }

  build() {
    Column() {
      SectionHeader({
        title: '招募链接',
        actionText: '+ 生成链接',
        onAction: () => {}
      })

      Column() {
        ForEach(this.links, (link: InviteLink) => {
          Column() {
            Row() {
              Text(link.deptName)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)

              Blank()

              Text(link.enabled ? '启用中' : '已停用')
                .fontSize(12)
                .fontColor(link.enabled ? '#43A047' : '#999999')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .backgroundColor(link.enabled ? '#E8F5E9' : '#F5F5F5')
                .borderRadius(4)
            }
            .width('100%')

            Text(link.url)
              .fontSize(12)
              .fontColor('#1E88E5')
              .margin({ top: 6 })

            Row() {
              Text(`创建于 ${link.createdAt}`)
                .fontSize(12)
                .fontColor('#999999')

              Blank()

              Text(link.enabled ? '停用' : '启用')
                .fontSize(12)
                .fontColor(link.enabled ? '#E53935' : '#43A047')
                .onClick(() => {
                  this.toggleEnabled(link.id);
                })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('100%')
          .padding(16)
          .margin({ bottom: 1 })
        }, (link: InviteLink) => link.id)
      }
      .backgroundColor(Color.White)
      .borderRadius(8)
      .margin({ left: 16, right: 16 })
    }
    .width('100%')
  }
}

// ====== 危险操作区 ======
@Component
struct DangerZoneSection {
  @State showTransferConfirm: boolean = false;
  @State showResetPasswordConfirm: boolean = false;

  build() {
    Column() {
      SectionHeader({ title: '危险操作', actionText: '' })

      Column() {
        // 移交会长
        Row() {
          Column() {
            Text('移交会长')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
            Text('将会长权限转让给另一位成员')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('>')
            .fontSize(18)
            .fontColor('#CCCCCC')
        }
        .width('100%')
        .padding(16)
        .onClick(() => {
          this.showTransferConfirm = true;
        })

        Divider().color('#EEEEEE').margin({ left: 16 })

        // 重置密码
        Row() {
          Column() {
            Text('重置成员密码')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
            Text('为成员生成一次性临时密码')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('>')
            .fontSize(18)
            .fontColor('#CCCCCC')
        }
        .width('100%')
        .padding(16)
        .onClick(() => {
          this.showResetPasswordConfirm = true;
        })
      }
      .backgroundColor(Color.White)
      .borderRadius(8)
      .margin({ left: 16, right: 16 })
    }
    .width('100%')
  }
}

@Component
export default struct ManagePage {
  @State currentTab: number = 0;

  build() {
    Column() {
      // 顶部 Tab 切换
      Tabs({ barPosition: BarPosition.Start }) {
        TabContent() {
          Scroll() {
            Column() {
              DeptManageSection()
              RegisterConfigSection()
              InviteLinkSection()
              DangerZoneSection()
            }
          }
          .scrollBar(BarState.Off)
        }
        .tabBar('综合管理')

        TabContent() {
          Column() {
            Text('部门管理（独立页）')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 20 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .tabBar('部门')

        TabContent() {
          Column() {
            Text('成员管理（独立页）')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 20 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .tabBar('成员')
      }
      .onChange((index: number) => {
        this.currentTab = index;
      })
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAFAFA')
  }
}
