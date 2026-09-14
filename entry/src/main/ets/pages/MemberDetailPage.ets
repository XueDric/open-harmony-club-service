// 成员详情页面（B同学负责）
// 点击成员名录里的卡片跳转进来

interface Task {
  id: number;
  title: string;
  status: string;   // todo / doing / blocked / done
  dueAt: string;
}

interface MemberDetail {
  id: number;
  name: string;
  role: string;
  roleLabel: string;
  deptId: number;
  deptName: string;
  status: string;
  joinedAt: string;
  phone: string;
  tasks: Task[];
}

// ====== 假数据 ======
const ROLE_LABEL: Record<string, string> = {
  'president': '会长',
  'vice_president': '副会长',
  'lead': '部长',
  'vice_lead': '副部长',
  'member': '成员',
};

const MEMBER_DETAIL: MemberDetail = {
  id: 1,
  name: '王会长',
  role: 'president',
  roleLabel: '会长',
  deptId: 0,
  deptName: '主席团',
  status: 'active',
  joinedAt: '2026-09-01',
  phone: '138****0000',
  tasks: [
    { id: 101, title: '社团招新总体方案', status: 'doing', dueAt: '2026-09-20' },
    { id: 102, title: '与指导老师沟通', status: 'todo', dueAt: '2026-09-18' },
    { id: 103, title: '第一次全体大会', status: 'todo', dueAt: '2026-09-25' },
  ],
};

const STATUS_LABEL: Record<string, string> = {
  'todo': '待开始',
  'doing': '进行中',
  'blocked': '阻塞',
  'done': '已完成',
};

const STATUS_COLOR: Record<string, string> = {
  'todo': '#999999',
  'doing': '#1E88E5',
  'blocked': '#FB8C00',
  'done': '#43A047',
};

@Component
struct TaskRow {
  task: Task = { id: 0, title: '', status: 'todo', dueAt: '' };

  build() {
    Row() {
      Column() {
        Text(this.task.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)

        Text(`截止 ${this.task.dueAt}`)
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(STATUS_LABEL[this.task.status] || '待开始')
        .fontSize(12)
        .fontColor(STATUS_COLOR[this.task.status])
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .backgroundColor(this.task.status === 'done' ? '#E8F5E9' :
          this.task.status === 'doing' ? '#E3F2FD' :
          this.task.status === 'blocked' ? '#FFF3E0' : '#F5F5F5')
        .borderRadius(4)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .margin({ bottom: 1 })
  }
}

@Component
export default struct MemberDetailPage {
  memberId: number = 0;
  @State member: MemberDetail = MEMBER_DETAIL;
  @State showResetPassword: boolean = false;
  @State showDisableConfirm: boolean = false;

  getAvatarColor(): string {
    switch (this.member.role) {
      case 'president': return '#E53935';
      case 'vice_president': return '#FB8C00';
      case 'lead': return '#1E88E5';
      case 'vice_lead': return '#43A047';
      default: return '#7E57C2';
    }
  }

  build() {
    Scroll() {
      Column() {
        // 顶部个人信息卡
        Column() {
          Text(this.member.name.substring(0, 1))
            .fontSize(36)
            .fontColor(Color.White)
            .width(72)
            .height(72)
            .borderRadius(36)
            .backgroundColor(this.getAvatarColor())
            .textAlign(TextAlign.Center)
            .margin({ bottom: 12 })

          Text(this.member.name)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)

          Text(`${this.member.deptName} · ${this.member.roleLabel}`)
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(24)
        .backgroundColor(Color.White)
        .borderRadius(8)
        .margin({ left: 16, right: 16, top: 16 })

        // 基本信息
        Column() {
          Text('基本信息')
            .fontSize(14)
            .fontColor('#999999')
            .width('100%')
            .padding({ left: 16, top: 12, bottom: 8 })

          Row() {
            Text('手机号')
              .fontSize(14)
              .fontColor('#666666')
              .width(80)
            Text(this.member.phone)
              .fontSize(14)
              .fontColor('#333333')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Divider().color('#F0F0F0').margin({ left: 16 })

          Row() {
            Text('加入时间')
              .fontSize(14)
              .fontColor('#666666')
              .width(80)
            Text(this.member.joinedAt)
              .fontSize(14)
              .fontColor('#333333')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Divider().color('#F0F0F0').margin({ left: 16 })

          Row() {
            Text('状态')
              .fontSize(14)
              .fontColor('#666666')
              .width(80)
            Text(this.member.status === 'active' ? '正常' : this.member.status)
              .fontSize(14)
              .fontColor(this.member.status === 'active' ? '#43A047' : '#E53935')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 12 })
        }
        .width('100%')
        .backgroundColor(Color.White)
        .borderRadius(8)
        .margin({ left: 16, right: 16, top: 12 })

        // 负责的任务
        Column() {
          Row() {
            Text('负责的任务')
              .fontSize(14)
              .fontColor('#999999')

            Blank()

            Text(`${this.member.tasks.length} 项`)
              .fontSize(14)
              .fontColor('#999999')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 8 })

          Column() {
            ForEach(this.member.tasks, (task: Task) => {
              TaskRow({ task: task })
            }, (task: Task) => task.id.toString())

            if (this.member.tasks.length === 0) {
              Text('暂无任务')
                .fontSize(14)
                .fontColor('#999999')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(20)
            }
          }
        }
        .width('100%')
        .backgroundColor(Color.White)
        .borderRadius(8)
        .margin({ left: 16, right: 16, top: 12 })

        // 操作按钮区
        Column() {
          Button('重置密码')
            .type(ButtonType.Normal)
            .backgroundColor('#FFF3E0')
            .fontColor('#FB8C00')
            .width('100%')
            .margin({ bottom: 12 })
            .onClick(() => {
              this.showResetPassword = true;
            })

          Button('移出社团')
            .type(ButtonType.Normal)
            .backgroundColor('#FFEBEE')
            .fontColor('#E53935')
            .width('100%')
            .onClick(() => {
              this.showDisableConfirm = true;
            })
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16, top: 20, bottom: 32 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAFAFA')
    .scrollBar(BarState.Off)
  }
}
