// 课题详情。面包屑 path + 子课题 + 本级任务；progress 仍是递归聚合值，进度条是这一页的主角。
// 接接口后：GET /plans/{id}、DELETE /plans/{id}。

import router from '@ohos.router'
import { PlanApi, PlanDetailResponse, PlanNode } from '../api/PlanApi'
import { TaskBrief, PlanRef } from '../api/TaskApi'
import { StatusChip } from '../components/StatusChip'
import { ProgressBar } from '../components/ProgressBar'
import { Color, FontSize, Radius, Space, StatusColor, statusLabel } from '../core/Theme'

const EMPTY_PLAN_DETAIL: PlanDetailResponse = {
  plan: {
    id: 0,
    title: '',
    owner: null,
    dept: null,
    due_at: null,
    progress: { done: 0, total: 0 },
    task_count: 0,
    child_count: 0,
    created_at: '',
    updated_at: '',
    desc: '',
    parent_id: 0
  },
  path: [],
  children: [],
  tasks: { items: [], total: 0 }
}

interface PlanDetailParams {
  plan_id?: number
}

@Entry
@Component
struct PlanDetailPage {
  @State detail: PlanDetailResponse = EMPTY_PLAN_DETAIL
  @State loading: boolean = true
  @State errorMsg: string = ''

  private planApi: PlanApi = new PlanApi()

  aboutToAppear(): void {
    const p = router.getParams() as PlanDetailParams
    if (p !== undefined && p !== null && p.plan_id !== undefined) {
      this.load(p.plan_id)
    } else {
      this.loading = false
      this.errorMsg = '缺少课题 id'
    }
  }

  private async load(planId: number): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.planApi.detail(planId)
    if (resp.ok && resp.data) {
      this.detail = resp.data
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  private async doDelete(): Promise<void> {
    const resp = await this.planApi.delete_(this.detail.plan.id)
    if (resp.ok) {
      router.back()
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '删除失败' })
    }
  }

  @Builder
  breadcrumb() {
    if (this.detail.path.length > 0) {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.detail.path, (p: PlanRef, index: number) => {
            Row() {
              Text(p.title).fontSize(FontSize.caption).fontColor(Color.primary)
              if (index < this.detail.path.length - 1) {
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
            const p = router.getParams() as PlanDetailParams
            if (p !== undefined && p !== null && p.plan_id !== undefined) {
              this.load(p.plan_id)
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
              Text(this.detail.plan.title)
                .fontSize(FontSize.title).fontWeight(FontWeight.Bold).fontColor(Color.textPrimary).width('100%')
              Text(`负责人：${this.detail.plan.owner?.name ?? '未分配'}`)
                .fontSize(FontSize.caption).fontColor(Color.textSecondary).margin({ top: Space.sm }).width('100%')
              if (this.detail.plan.dept !== null) {
                Text(`部门：${this.detail.plan.dept.name}`)
                  .fontSize(FontSize.caption).fontColor(Color.textSecondary).margin({ top: Space.xs }).width('100%')
              }
              ProgressBar({ done: this.detail.plan.progress.done, total: this.detail.plan.progress.total })
                .margin({ top: Space.md })
              Row() {
                Text(`已完成 ${this.detail.plan.progress.done}/共 ${this.detail.plan.progress.total}`)
                  .fontSize(FontSize.caption).fontColor(Color.primary)
                Blank()
                Text(this.detail.plan.due_at !== null ? `截止 ${this.detail.plan.due_at}` : '无截止')
                  .fontSize(FontSize.caption).fontColor(Color.textTertiary)
              }
              .width('100%')
              .margin({ top: Space.sm })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)

            Column() {
              Text('子课题').fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              ForEach(this.detail.children, (c: PlanNode) => {
                Row() {
                  Text(c.title).fontSize(FontSize.body).fontColor(Color.textPrimary).layoutWeight(1)
                  Text(`${c.progress.done}/${c.progress.total}`).fontSize(FontSize.caption).fontColor(Color.primary)
                }
                .width('100%')
                .padding({ top: Space.sm, bottom: Space.sm })
                .onClick(() => {
                  router.pushUrl({ url: 'pages/PlanDetailPage', params: { plan_id: c.id } })
                })
              }, (c: PlanNode) => `${c.id}`)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)

            Column() {
              Text('本级任务').fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              ForEach(this.detail.tasks.items, (t: TaskBrief) => {
                Row() {
                  Column() {
                    Text(t.title)
                      .fontSize(FontSize.body)
                      .fontColor(t.is_overdue ? StatusColor.overdue.fg : Color.textPrimary)
                    Text(`${t.owner?.name ?? '未分配'} · ${statusLabel(t.status)}`)
                      .fontSize(FontSize.caption).fontColor(Color.textTertiary).margin({ top: Space.xs })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  StatusChip({ status: t.status, isOverdue: t.is_overdue })
                }
                .width('100%')
                .padding({ top: Space.sm, bottom: Space.sm })
                .onClick(() => {
                  router.pushUrl({ url: 'pages/TaskDetailPage', params: { task_id: t.id } })
                })
              }, (t: TaskBrief) => `${t.id}`)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)

            Button('删除课题')
              .width('100%')
              .height(44)
              .backgroundColor(StatusColor.overdue.bg)
              .fontColor(StatusColor.overdue.fg)
              .onClick(() => {
                const hint = this.detail.children.length > 0
                  ? '删除后其子课题将提升到上一级，本级任务保留，确认删除？'
                  : '删除后不可恢复，确认删除？'
                AlertDialog.show({
                  title: '删除课题',
                  message: hint,
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
