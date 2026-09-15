// 新建任务。创建走 POST /tasks，带 client_token（UUID）防重复提交。
// 负责人/所属课题下拉来自 MemberApi / PlanApi。

import router from '@ohos.router'
import { TaskApi, CreateTaskRequest, PlanRef } from '../api/TaskApi'
import { MemberApi } from '../api/MemberApi'
import { PlanApi } from '../api/PlanApi'
import { MemberBrief } from '../api/AuthApi'
import { flattenPlans } from '../util/PlanTree'
import { genClientToken } from '../util/ClientToken'
import { Color, FontSize, Radius, Space } from '../core/Theme'

@Entry
@Component
struct CreateTaskPage {
  @State title: string = ''
  @State desc: string = ''
  @State ownerId: number = 0
  @State planId: number = 0
  @State dueAt: string = ''
  @State showOwnerPicker: boolean = false
  @State showPlanPicker: boolean = false
  @State members: MemberBrief[] = []
  @State plansFlat: PlanRef[] = []
  @State submitting: boolean = false

  private taskApi: TaskApi = new TaskApi()
  private memberApi: MemberApi = new MemberApi()
  private planApi: PlanApi = new PlanApi()

  aboutToAppear(): void {
    this.loadOptions()
  }

  private async loadOptions(): Promise<void> {
    const membersResp = await this.memberApi.list()
    if (membersResp.ok && membersResp.data) {
      this.members = membersResp.data.items
    }
    const plansResp = await this.planApi.list()
    if (plansResp.ok && plansResp.data) {
      this.plansFlat = flattenPlans(plansResp.data.items)
    }
  }

  private ownerName(): string {
    for (const m of this.members) {
      if (m.id === this.ownerId) return m.name
    }
    return '请选择'
  }

  private planName(): string {
    if (this.planId === 0) return '独立任务'
    for (const p of this.plansFlat) {
      if (p.id === this.planId) return p.title
    }
    return '独立任务'
  }

  private async submit(): Promise<void> {
    if (this.submitting) return
    this.submitting = true
    const data: CreateTaskRequest = {
      title: this.title,
      owner_id: this.ownerId,
      client_token: genClientToken()
    }
    if (this.desc.length > 0) data.desc = this.desc
    if (this.planId !== 0) data.plan_id = this.planId
    if (this.dueAt.length > 0) data.due_at = this.dueAt
    const resp = await this.taskApi.create(data)
    this.submitting = false
    if (resp.ok && resp.data) {
      router.back()
    } else {
      AlertDialog.show({
        title: '创建失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      })
    }
  }

  build() {
    Column() {
      Text('新建任务')
        .fontSize(FontSize.headline).fontWeight(FontWeight.Bold).fontColor(Color.textPrimary)
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.sm })

      Scroll() {
        Column({ space: Space.md }) {
          TextInput({ placeholder: '标题（必填）', text: this.title })
            .onChange((v: string) => {
              this.title = v
            })
            .height(44).backgroundColor(Color.surface).borderRadius(Radius.input)

          TextArea({ placeholder: '描述', text: this.desc })
            .onChange((v: string) => {
              this.desc = v
            })
            .height(100).backgroundColor(Color.surface).borderRadius(Radius.input)

          // 负责人（必填，只能一人）
          Row() {
            Text('负责人').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
            Text(this.ownerName()).fontSize(FontSize.body)
              .fontColor(this.ownerId === 0 ? Color.textTertiary : Color.textPrimary)
              .layoutWeight(1)
              .onClick(() => {
                this.showOwnerPicker = !this.showOwnerPicker
              })
          }
          .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

          if (this.showOwnerPicker) {
            Column() {
              ForEach(this.members, (m: MemberBrief) => {
                Row() {
                  Text(m.name).fontSize(FontSize.body)
                    .fontColor(this.ownerId === m.id ? Color.primary : Color.textPrimary)
                  Blank()
                  Text(m.dept !== null ? m.dept.name : '').fontSize(FontSize.caption).fontColor(Color.textTertiary)
                }
                .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                .onClick(() => {
                  this.ownerId = m.id
                  this.showOwnerPicker = false
                })
              }, (m: MemberBrief) => `${m.id}`)
            }
            .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
          }

          // 所属课题（可空 = 独立任务）
          Row() {
            Text('所属课题').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
            Text(this.planName()).fontSize(FontSize.body)
              .fontColor(this.planId === 0 ? Color.textTertiary : Color.textPrimary)
              .layoutWeight(1)
              .onClick(() => {
                this.showPlanPicker = !this.showPlanPicker
              })
          }
          .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

          if (this.showPlanPicker) {
            Column() {
              Row() {
                Text('独立任务').fontSize(FontSize.body).fontColor(this.planId === 0 ? Color.primary : Color.textPrimary)
              }
              .width('100%').padding({ top: Space.sm, bottom: Space.sm })
              .onClick(() => {
                this.planId = 0
                this.showPlanPicker = false
              })
              ForEach(this.plansFlat, (p: PlanRef) => {
                Text(p.title).fontSize(FontSize.body)
                  .fontColor(this.planId === p.id ? Color.primary : Color.textPrimary)
                  .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                  .onClick(() => {
                    this.planId = p.id
                    this.showPlanPicker = false
                  })
              }, (p: PlanRef) => `${p.id}`)
            }
            .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
          }

          // 截止时间（可空 = 无截止组）
          TextInput({ placeholder: '截止时间（可空，如 2026-09-20T18:00）', text: this.dueAt })
            .onChange((v: string) => {
              this.dueAt = v
            })
            .height(44).backgroundColor(Color.surface).borderRadius(Radius.input)

          Button('提交')
            .width('100%').height(44).backgroundColor(Color.primary)
            .enabled(this.title.length > 0 && this.ownerId !== 0 && !this.submitting)
            .onClick(() => {
              this.submit()
            })
        }
        .width('100%')
        .padding({ left: Space.page, right: Space.page, bottom: Space.xl })
      }
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(Color.canvas)
  }
}
