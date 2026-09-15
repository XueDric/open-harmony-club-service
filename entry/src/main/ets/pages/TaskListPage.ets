// 任务列表。筛选走服务端过滤参数（GET /tasks?status=&dept_id=&owner_id=&plan_id=）。
// 部门/负责人/课题下拉选项来自 DeptApi / MemberApi / PlanApi。

import router from '@ohos.router'
import { TaskApi, TaskBrief, TaskStatus, PlanRef, TaskListParams } from '../api/TaskApi'
import { DeptApi, DeptView } from '../api/DeptApi'
import { MemberApi } from '../api/MemberApi'
import { PlanApi } from '../api/PlanApi'
import { MemberBrief } from '../api/AuthApi'
import { flattenPlans } from '../util/PlanTree'
import { TaskCard } from '../components/TaskCard'
import { Color, FontSize, Radius, Space, StatusColor, statusLabel } from '../core/Theme'

interface StatusFilter {
  label: string;
  value: string;
}

@Entry
@Component
struct TaskListPage {
  @State tasks: TaskBrief[] = []
  @State total: number = 0
  @State loading: boolean = true
  @State errorMsg: string = ''
  @State filterStatus: string = 'all'
  @State filterDept: string = 'all'
  @State filterOwner: string = 'all'
  @State filterPlan: string = 'all'
  @State depts: DeptView[] = []
  @State members: MemberBrief[] = []
  @State plansFlat: PlanRef[] = []

  private taskApi: TaskApi = new TaskApi()
  private deptApi: DeptApi = new DeptApi()
  private memberApi: MemberApi = new MemberApi()
  private planApi: PlanApi = new PlanApi()

  private statusFilters: StatusFilter[] = [
    { label: '全部', value: 'all' },
    { label: '未开始', value: 'todo' },
    { label: '进行中', value: 'doing' },
    { label: '阻塞中', value: 'blocked' },
    { label: '已完成', value: 'done' }
  ]

  aboutToAppear(): void {
    this.loadTasks()
    this.loadOptions()
  }

  private buildParams(): TaskListParams {
    const p: TaskListParams = { page: 1, size: 50 }
    if (this.filterStatus !== 'all') p.status = this.filterStatus as TaskStatus
    if (this.filterDept !== 'all') p.dept_id = Number(this.filterDept)
    if (this.filterOwner !== 'all') p.owner_id = Number(this.filterOwner)
    if (this.filterPlan !== 'all') p.plan_id = Number(this.filterPlan)
    return p
  }

  private async loadTasks(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.taskApi.list(this.buildParams())
    if (resp.ok && resp.data) {
      this.tasks = resp.data.items
      this.total = resp.data.total
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  private async loadOptions(): Promise<void> {
    const deptsResp = await this.deptApi.list()
    if (deptsResp.ok && deptsResp.data) {
      this.depts = deptsResp.data.items
    }
    const membersResp = await this.memberApi.list()
    if (membersResp.ok && membersResp.data) {
      this.members = membersResp.data.items
    }
    const plansResp = await this.planApi.list()
    if (plansResp.ok && plansResp.data) {
      this.plansFlat = flattenPlans(plansResp.data.items)
    }
  }

  private isSelected(kind: string, value: string): boolean {
    if (kind === 'status') return this.filterStatus === value
    if (kind === 'dept') return this.filterDept === value
    if (kind === 'owner') return this.filterOwner === value
    return this.filterPlan === value
  }

  private setFilter(kind: string, value: string): void {
    if (kind === 'status') {
      this.filterStatus = value
    } else if (kind === 'dept') {
      this.filterDept = value
    } else if (kind === 'owner') {
      this.filterOwner = value
    } else {
      this.filterPlan = value
    }
    this.loadTasks()
  }

  @Builder
  filterChip(kind: string, label: string, value: string) {
    Text(label)
      .fontSize(FontSize.caption)
      .fontColor(this.isSelected(kind, value) ? Color.surface : Color.textSecondary)
      .backgroundColor(this.isSelected(kind, value) ? Color.primary : Color.primarySoft)
      .borderRadius(Radius.pill)
      .padding({ left: Space.md, right: Space.md, top: 6, bottom: 6 })
      .onClick(() => {
        this.setFilter(kind, value)
      })
  }

  private subtitle(t: TaskBrief): string {
    return `${t.owner?.name ?? '未分配'} · ${statusLabel(t.status)}`
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
            this.loadTasks()
          })
      }
      .width('100%')
      .padding({ top: Space.xxl })
    } else if (this.tasks.length === 0) {
      Text('没有符合条件的任务')
        .fontSize(FontSize.caption)
        .fontColor(Color.textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: Space.xxl })
    }
  }

  build() {
    Column() {
      Row() {
        Text('任务列表')
          .fontSize(FontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.textPrimary)
        Blank()
        Text('+ 新建')
          .fontSize(FontSize.body)
          .fontColor(Color.surface)
          .backgroundColor(Color.primary)
          .borderRadius(Radius.button)
          .padding({ left: Space.md, right: Space.md, top: 6, bottom: 6 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/CreateTaskPage' })
          })
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.sm })

      Scroll() {
        Row({ space: Space.sm }) {
          ForEach(this.statusFilters, (f: StatusFilter) => {
            this.filterChip('status', f.label, f.value)
          }, (f: StatusFilter) => f.value)
        }
        .padding({ left: Space.page, right: Space.page })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      Scroll() {
        Row({ space: Space.sm }) {
          this.filterChip('dept', '全部', 'all')
          ForEach(this.depts, (d: DeptView) => {
            this.filterChip('dept', d.name, d.id.toString())
          }, (d: DeptView) => `${d.id}`)
        }
        .padding({ left: Space.page, right: Space.page })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: Space.sm })

      Scroll() {
        Row({ space: Space.sm }) {
          this.filterChip('owner', '全部', 'all')
          ForEach(this.members, (m: MemberBrief) => {
            this.filterChip('owner', m.name, m.id.toString())
          }, (m: MemberBrief) => `${m.id}`)
        }
        .padding({ left: Space.page, right: Space.page })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: Space.sm })

      Scroll() {
        Row({ space: Space.sm }) {
          this.filterChip('plan', '全部', 'all')
          ForEach(this.plansFlat, (p: PlanRef) => {
            this.filterChip('plan', p.title, p.id.toString())
          }, (p: PlanRef) => `${p.id}`)
        }
        .padding({ left: Space.page, right: Space.page })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: Space.sm })

      Row() {
        Text(`共 ${this.total} 项`)
          .fontSize(FontSize.caption)
          .fontColor(Color.textSecondary)
        Blank()
        Text('按截止时间排序')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.sm })

      if (this.loading || this.errorMsg.length > 0 || this.tasks.length === 0) {
        this.statusHint()
      }

      List({ space: Space.cardGap }) {
        ForEach(this.tasks, (t: TaskBrief) => {
          ListItem() {
            TaskCard({ task: t, subtitle: this.subtitle(t) })
          }
        }, (t: TaskBrief) => `${t.id}`)
      }
      .layoutWeight(1)
      .padding({ left: Space.page, right: Space.page, bottom: Space.lg })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
