// 任务详情。切到 blocked 必须填原因，否则后端返回 BLOCKER_REQUIRED。
// 状态保存走 PUT /tasks/{id}/status，删除走 DELETE /tasks/{id}。

import router from '@ohos.router'
import { TaskApi, TaskDetail, TaskStatus, PlanRef, UpdateTaskStatusRequest } from '../api/TaskApi'
import { StatusChip } from '../components/StatusChip'
import { Color, FontSize, Radius, Space, StatusColor, statusLabel } from '../core/Theme'

const EMPTY_TASK_DETAIL: TaskDetail = {
  id: 0,
  title: '',
  status: 'todo',
  owner: null,
  dept: null,
  plan: null,
  due_at: null,
  is_overdue: false,
  blocked: false,
  updated_at: '',
  desc: '',
  blocker: null,
  plan_path: [],
  created_by: null,
  created_at: '',
  completed_at: null
}

interface TaskDetailParams {
  task_id?: number
}

@Entry
@Component
struct TaskDetailPage {
  @State detail: TaskDetail = EMPTY_TASK_DETAIL
  @State currentStatus: string = 'todo'
  @State blockerText: string = ''
  @State loading: boolean = true
  @State errorMsg: string = ''

  private taskApi: TaskApi = new TaskApi()
  private statusOptions: string[] = ['todo', 'doing', 'blocked', 'done']

  aboutToAppear(): void {
    const p = router.getParams() as TaskDetailParams
    if (p !== undefined && p !== null && p.task_id !== undefined) {
      this.load(p.task_id)
    } else {
      this.loading = false
      this.errorMsg = '缺少任务 id'
    }
  }

  private async load(taskId: number): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.taskApi.detail(taskId)
    if (resp.ok && resp.data) {
      this.detail = resp.data
      this.currentStatus = resp.data.status
      this.blockerText = resp.data.blocker ?? ''
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  private switchStatus(s: string): void {
    this.currentStatus = s
    if (s !== 'blocked') {
      this.blockerText = ''
    }
  }

  private async save(): Promise<void> {
    const data: UpdateTaskStatusRequest = { status: this.currentStatus as TaskStatus }
    if (this.currentStatus === 'blocked') {
      data.blocker = this.blockerText
    }
    const resp = await this.taskApi.updateStatus(this.detail.id, data)
    if (resp.ok && resp.data) {
      this.detail = resp.data
      this.currentStatus = resp.data.status
      this.blockerText = resp.data.blocker ?? ''
      AlertDialog.show({ message: '已保存' })
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '保存失败' })
    }
  }

  private async doDelete(): Promise<void> {
    const resp = await this.taskApi.delete_(this.detail.id)
    if (resp.ok) {
      router.back()
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '删除失败' })
    }
  }

  @Builder
  breadcrumb() {
    if (this.detail.plan_path.length > 0) {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.detail.plan_path, (p: PlanRef, index: number) => {
            Row() {
              Text(p.title).fontSize(FontSize.caption).fontColor(Color.primary)
              if (index < this.detail.plan_path.length - 1) {
                Text('›').fontSize(FontSize.caption).fontColor(Color.textTertiary).margin({ left: 6 })
              }
            }
          }, (p: PlanRef) => `${p.id}`)
        }
        .padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xs })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
  }

  @Builder
  statusButton(s: string) {
    Text(statusLabel(s))
      .fontSize(FontSize.body)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.currentStatus === s ? Color.surface : Color.textSecondary)
      .backgroundColor(this.currentStatus === s ? Color.primary : Color.primarySoft)
      .borderRadius(Radius.button)
      .padding({ left: Space.lg, right: Space.lg, top: 10, bottom: 10 })
      .onClick(() => {
        this.switchStatus(s)
      })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(FontSize.caption).fontColor(Color.textTertiary).width(72)
      Text(value).fontSize(FontSize.body).fontColor(Color.textPrimary).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: Space.xs, bottom: Space.xs })
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
            const p = router.getParams() as TaskDetailParams
            if (p !== undefined && p !== null && p.task_id !== undefined) {
              this.load(p.task_id)
            }
          })
      }
      .width('100%')
      .padding({ top: Space.xxl })
    }
  }

  build() {
    Column() {
      this.breadcrumb()

      if (this.loading || this.errorMsg.length > 0) {
        this.statusHint()
      } else {
        Scroll() {
          Column({ space: Space.md }) {
            Column() {
              Row() {
                Text(this.detail.title)
                  .fontSize(FontSize.title)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.textPrimary)
                  .layoutWeight(1)
                StatusChip({ status: this.currentStatus, isOverdue: this.detail.is_overdue })
                  .margin({ left: Space.sm })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)

            if (this.detail.is_overdue) {
              Text('已逾期 · 该判断由服务端算出，客户端不重算')
                .fontSize(FontSize.caption)
                .fontColor(StatusColor.overdue.fg)
                .width('100%')
                .padding(Space.md)
                .backgroundColor(StatusColor.overdue.bg)
                .borderRadius(Radius.input)
            }

            Column() {
              this.infoRow('负责人', this.detail.owner?.name ?? '未分配')
              if (this.detail.dept !== null) {
                this.infoRow('部门', this.detail.dept.name)
              }
              this.infoRow('所属课题', this.detail.plan !== null ? this.detail.plan.title : '独立任务')
              this.infoRow('截止时间', this.detail.due_at !== null ? this.detail.due_at : '无')
              this.infoRow('创建人', this.detail.created_by?.name ?? '未分配')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)

            if (this.currentStatus === 'blocked' && this.blockerText.length > 0) {
              Column() {
                Text('阻塞原因')
                  .fontSize(FontSize.caption)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(StatusColor.blocked.fg)
                  .width('100%')
                Text(this.blockerText)
                  .fontSize(FontSize.body)
                  .fontColor(Color.textPrimary)
                  .width('100%')
                  .margin({ top: Space.xs })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(Space.md)
              .backgroundColor(StatusColor.blocked.bg)
              .borderRadius(Radius.input)
            }

            Column() {
              Text('描述').fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              Text(this.detail.desc).fontSize(FontSize.body).fontColor(Color.textPrimary).width('100%').margin({ top: Space.xs })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)

            Column() {
              Text('更新状态').fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              Row({ space: Space.sm }) {
                ForEach(this.statusOptions, (s: string) => {
                  this.statusButton(s)
                }, (s: string) => s)
              }
              .width('100%')
              .margin({ top: Space.sm })

              if (this.currentStatus === 'blocked') {
                TextInput({ placeholder: '阻塞原因（必填）', text: this.blockerText })
                  .onChange((v: string) => {
                    this.blockerText = v
                  })
                  .height(44)
                  .backgroundColor(Color.surface)
                  .borderRadius(Radius.input)
                  .margin({ top: Space.sm })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)

            Button('保存修改')
              .width('100%')
              .height(44)
              .backgroundColor(Color.primary)
              .enabled(this.currentStatus !== 'blocked' || this.blockerText.length > 0)
              .onClick(() => {
                this.save()
              })

            Row({ space: Space.sm }) {
              Button('加入系统日历')
                .layoutWeight(1)
                .height(44)
                .backgroundColor(Color.primarySoft)
                .fontColor(Color.primary)
                .onClick(() => {
                  if (this.detail.due_at !== null && this.detail.status !== 'done') {
                    AlertDialog.show({ message: '已加入系统日历（骨架阶段暂未真正写入）' })
                  } else {
                    AlertDialog.show({ message: '该任务无截止时间或已完成，无需加入日历' })
                  }
                })
              Button('删除任务')
                .layoutWeight(1)
                .height(44)
                .backgroundColor(StatusColor.overdue.bg)
                .fontColor(StatusColor.overdue.fg)
                .onClick(() => {
                  AlertDialog.show({
                    title: '删除任务',
                    message: '删除后不可恢复，确认删除？',
                    primaryButton: {
                      value: '取消',
                      action: () => {}
                    },
                    secondaryButton: {
                      value: '删除',
                      action: () => {
                        this.doDelete()
                      }
                    }
                  })
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: Space.page, right: Space.page, bottom: Space.xl })
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
