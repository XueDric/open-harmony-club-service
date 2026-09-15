// 新建课题 / 子课题。顶层课题必填部门，子课题必填父课题（不存部门，继承根课题）。
// 创建走 POST /plans，带 client_token 防重复提交。

import router from '@ohos.router'
import { PlanApi, CreatePlanRequest } from '../api/PlanApi'
import { MemberApi } from '../api/MemberApi'
import { DeptApi, DeptView } from '../api/DeptApi'
import { MemberBrief } from '../api/AuthApi'
import { PlanRef } from '../api/TaskApi'
import { flattenPlans } from '../util/PlanTree'
import { genClientToken } from '../util/ClientToken'
import { Color, FontSize, Radius, Space } from '../core/Theme'

@Entry
@Component
struct CreatePlanPage {
  @State title: string = ''
  @State desc: string = ''
  @State isTopLevel: boolean = true
  @State ownerId: number = 0
  @State deptId: number = 0
  @State parentId: number = 0
  @State dueAt: string = ''
  @State showOwnerPicker: boolean = false
  @State showDeptPicker: boolean = false
  @State showParentPicker: boolean = false
  @State members: MemberBrief[] = []
  @State depts: DeptView[] = []
  @State plansFlat: PlanRef[] = []
  @State submitting: boolean = false

  private planApi: PlanApi = new PlanApi()
  private memberApi: MemberApi = new MemberApi()
  private deptApi: DeptApi = new DeptApi()

  aboutToAppear(): void {
    this.loadOptions()
  }

  private async loadOptions(): Promise<void> {
    const membersResp = await this.memberApi.list()
    if (membersResp.ok && membersResp.data) {
      this.members = membersResp.data.items
    }
    const deptsResp = await this.deptApi.list()
    if (deptsResp.ok && deptsResp.data) {
      this.depts = deptsResp.data.items
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

  private deptName(): string {
    for (const d of this.depts) {
      if (d.id === this.deptId) return d.name
    }
    return '请选择'
  }

  private parentName(): string {
    for (const p of this.plansFlat) {
      if (p.id === this.parentId) return p.title
    }
    return '请选择'
  }

  private async submit(): Promise<void> {
    if (this.submitting) return
    this.submitting = true
    const data: CreatePlanRequest = {
      title: this.title,
      owner_id: this.ownerId,
      client_token: genClientToken()
    }
    if (this.desc.length > 0) data.desc = this.desc
    if (this.dueAt.length > 0) data.due_at = this.dueAt
    if (this.isTopLevel) {
      data.dept_id = this.deptId
    } else {
      data.parent_id = this.parentId
    }
    const resp = await this.planApi.create(data)
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
      Text('新建课题')
        .fontSize(FontSize.headline).fontWeight(FontWeight.Bold).fontColor(Color.textPrimary)
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.sm })

      Scroll() {
        Column({ space: Space.md }) {
          Row({ space: Space.sm }) {
            Text('顶层课题')
              .fontSize(FontSize.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isTopLevel ? Color.surface : Color.textSecondary)
              .backgroundColor(this.isTopLevel ? Color.primary : Color.primarySoft)
              .borderRadius(Radius.button)
              .padding({ left: Space.lg, right: Space.lg, top: 9, bottom: 9 })
              .onClick(() => {
                this.isTopLevel = true
                this.parentId = 0
              })
            Text('子课题')
              .fontSize(FontSize.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isTopLevel ? Color.textSecondary : Color.surface)
              .backgroundColor(this.isTopLevel ? Color.primarySoft : Color.primary)
              .borderRadius(Radius.button)
              .padding({ left: Space.lg, right: Space.lg, top: 9, bottom: 9 })
              .onClick(() => {
                this.isTopLevel = false
                this.deptId = 0
              })
          }
          .width('100%')

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

          // 负责人（必填，任意层级课题都要有人负责）
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

          if (this.isTopLevel) {
            // 顶层课题：部门（必填）
            Row() {
              Text('部门').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
              Text(this.deptName()).fontSize(FontSize.body)
                .fontColor(this.deptId === 0 ? Color.textTertiary : Color.textPrimary)
                .layoutWeight(1)
                .onClick(() => {
                  this.showDeptPicker = !this.showDeptPicker
                })
            }
            .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

            if (this.showDeptPicker) {
              Column() {
                ForEach(this.depts, (d: DeptView) => {
                  Text(d.name).fontSize(FontSize.body)
                    .fontColor(this.deptId === d.id ? Color.primary : Color.textPrimary)
                    .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                    .onClick(() => {
                      this.deptId = d.id
                      this.showDeptPicker = false
                    })
                }, (d: DeptView) => `${d.id}`)
              }
              .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
            }
          } else {
            // 子课题：父课题（必填）
            Row() {
              Text('父课题').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
              Text(this.parentName()).fontSize(FontSize.body)
                .fontColor(this.parentId === 0 ? Color.textTertiary : Color.textPrimary)
                .layoutWeight(1)
                .onClick(() => {
                  this.showParentPicker = !this.showParentPicker
                })
            }
            .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

            if (this.showParentPicker) {
              Column() {
                ForEach(this.plansFlat, (p: PlanRef) => {
                  Text(p.title).fontSize(FontSize.body)
                    .fontColor(this.parentId === p.id ? Color.primary : Color.textPrimary)
                    .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                    .onClick(() => {
                      this.parentId = p.id
                      this.showParentPicker = false
                    })
                }, (p: PlanRef) => `${p.id}`)
              }
              .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
            }
          }

          // 截止时间（可空）
          TextInput({ placeholder: '截止时间（可空，如 2026-10-01T18:00）', text: this.dueAt })
            .onChange((v: string) => {
              this.dueAt = v
            })
            .height(44).backgroundColor(Color.surface).borderRadius(Radius.input)

          Button('提交')
            .width('100%').height(44).backgroundColor(Color.primary)
            .enabled(this.title.length > 0 && this.ownerId !== 0 && (this.isTopLevel ? this.deptId !== 0 : this.parentId !== 0) && !this.submitting)
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
