// 首页「我的任务」。服务端已分组，直接渲染，别自己算逾期。
// 接接口后：GET /tasks/mine。

import router from '@ohos.router'
import { TaskApi, MineGroups, TaskBrief } from '../api/TaskApi'
import { TaskCard } from '../components/TaskCard'
import { Color, FontSize, Radius, Shadow, Space, StatusColor } from '../core/Theme'

const EMPTY_MINE_GROUPS: MineGroups = {
  overdue: [], blocked: [], due_today: [], due_week: [], later: [], no_due: [],
  counts: { overdue: 0, blocked: 0, open_total: 0 }
}

@Component
export default struct MyTasksPage {
  @State myTasks: MineGroups = EMPTY_MINE_GROUPS
  @State loading: boolean = true
  @State errorMsg: string = ''

  private taskApi: TaskApi = new TaskApi()

  aboutToAppear(): void {
    this.load()
  }

  private async load(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.taskApi.mine()
    if (resp.ok && resp.data) {
      this.myTasks = resp.data
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  private planLabel(t: TaskBrief): string {
    if (t.plan !== null) {
      return `课题：${t.plan.title}`
    }
    return '独立任务'
  }

  private dueLabel(t: TaskBrief): string {
    if (t.due_at !== null) {
      return `截止：${t.due_at}`
    }
    return '无截止时间'
  }

  private subtitle(t: TaskBrief): string {
    return `${this.planLabel(t)} · ${this.dueLabel(t)}`
  }

  @Builder
  sectionHeader(title: string, hint: string, count: number) {
    Row() {
      Text(title)
        .fontSize(FontSize.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.textPrimary)
      if (hint.length > 0) {
        Text(hint)
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .margin({ left: Space.sm })
      }
      Blank()
      Text(`${count}`)
        .fontSize(FontSize.caption)
        .fontColor(Color.textSecondary)
    }
    .width('100%')
    .padding({ left: Space.xs, right: Space.xs })
  }

  @Builder
  statCell(label: string, value: number, color: string) {
    Column() {
      Text(`${value}`)
        .fontSize(FontSize.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
      Text(label)
        .fontSize(FontSize.caption)
        .fontColor(Color.textSecondary)
        .margin({ top: Space.xs })
    }
    .layoutWeight(1)
  }

  @Builder
  statsBar() {
    Row() {
      this.statCell('逾期', this.myTasks.counts.overdue, StatusColor.overdue.fg)
      this.statCell('阻塞', this.myTasks.counts.blocked, StatusColor.blocked.fg)
      this.statCell('未完成', this.myTasks.counts.open_total, Color.textPrimary)
    }
    .width('100%')
    .padding(Space.card)
    .backgroundColor(Color.surface)
    .borderRadius(Radius.card)
    .shadow(Shadow.card)
  }

  @Builder
  group(title: string, hint: string, tasks: TaskBrief[]) {
    Column() {
      this.sectionHeader(title, hint, tasks.length)
      Column({ space: Space.cardGap }) {
        ForEach(tasks, (t: TaskBrief) => {
          TaskCard({ task: t, subtitle: this.subtitle(t) })
        }, (t: TaskBrief) => `${t.id}`)
      }
      .width('100%')
      .margin({ top: Space.sm })
    }
    .width('100%')
  }

  @Builder
  statusHint() {
    if (this.loading) {
      Row() {
        LoadingProgress().width(28).height(28).color(Color.primary)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: Space.xxl, bottom: Space.xxl })
    } else if (this.errorMsg.length > 0) {
      Column() {
        Text(this.errorMsg)
          .fontSize(FontSize.caption)
          .fontColor(StatusColor.overdue.fg)
          .width('100%')
          .textAlign(TextAlign.Center)
        Button('重试')
          .height(36)
          .backgroundColor(Color.primary)
          .fontColor(Color.surface)
          .margin({ top: Space.sm })
          .onClick(() => {
            this.load()
          })
      }
      .width('100%')
      .padding({ top: Space.xxl })
    }
  }

  build() {
    Column() {
      Row() {
        Text('我的任务')
          .fontSize(FontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.textPrimary)
        Blank()
        Text('课题')
          .fontSize(FontSize.body)
          .fontColor(Color.primary)
          .onClick(() => {
            router.pushUrl({ url: 'pages/PlanTreePage' })
          })
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.md })

      Scroll() {
        Column({ space: Space.section }) {
          this.statusHint()
          this.statsBar()
          this.group('已逾期', '距截止已过，请尽快处理', this.myTasks.overdue)
          this.group('阻塞中', '阻塞项同时也会出现在下面的时间里', this.myTasks.blocked)
          this.group('今天到期', '', this.myTasks.due_today)
          this.group('本周内', `本周内还有 ${this.myTasks.due_week.length} 项`, this.myTasks.due_week)
          this.group('以后', '', this.myTasks.later)
          this.group('无截止时间', '', this.myTasks.no_due)
        }
        .width('100%')
        .padding({ left: Space.page, right: Space.page, bottom: Space.xl })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
