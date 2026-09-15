// 课题树。进度 progress.done / progress.total 是服务端递归聚合好的（含整棵子树），
// 客户端直接用，别再自己递归算。顶层用进度条，嵌套层收成数字。
// 接接口后：GET /plans。

import router from '@ohos.router'
import { PlanApi, PlanNode } from '../api/PlanApi'
import { ProgressBar } from '../components/ProgressBar'
import { Color, FontSize, Radius, Space, StatusColor } from '../core/Theme'

@Component
struct PlanTreeNode {
  @Prop node: PlanNode
  @Prop depth: number = 0
  @State expanded: boolean = true

  build() {
    Column() {
      Column() {
        Row() {
          if (this.node.child_count > 0) {
            Text(this.expanded ? '▾' : '▸')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .width(20)
              .onClick(() => {
                this.expanded = !this.expanded
              })
          } else {
            Row().width(20)
          }
          Text(this.node.title)
            .fontSize(this.depth === 0 ? FontSize.subtitle : FontSize.body)
            .fontWeight(this.depth === 0 ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(Color.textPrimary)
            .layoutWeight(1)
            .onClick(() => {
              router.pushUrl({ url: 'pages/PlanDetailPage', params: { plan_id: this.node.id } })
            })
          Text(`${this.node.progress.done}/${this.node.progress.total}`)
            .fontSize(FontSize.caption)
            .fontColor(Color.primary)
        }
        .width('100%')

        if (this.depth === 0) {
          Row() {
            ProgressBar({ done: this.node.progress.done, total: this.node.progress.total })
              .layoutWeight(1)
            Text(`${this.node.child_count} 个子课题`)
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .margin({ left: Space.sm })
          }
          .width('100%')
          .margin({ top: Space.sm })
        }
      }
      .width('100%')
      .padding({ top: Space.md, bottom: Space.md })

      if (this.expanded && this.node.children.length > 0) {
        Column() {
          ForEach(this.node.children, (child: PlanNode) => {
            PlanTreeNode({ node: child, depth: this.depth + 1 })
          }, (child: PlanNode) => `${child.id}`)
        }
        .width('100%')
        .margin({ left: Space.lg })
      }
    }
    .width('100%')
  }
}

@Entry
@Component
struct PlanTreePage {
  @State tree: PlanNode[] = []
  @State loading: boolean = true
  @State errorMsg: string = ''

  private planApi: PlanApi = new PlanApi()

  aboutToAppear(): void {
    this.load()
  }

  private async load(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.planApi.list()
    if (resp.ok && resp.data) {
      this.tree = resp.data.items
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  build() {
    Column() {
      Row() {
        Text('课题')
          .fontSize(FontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.textPrimary)
        Blank()
        Text('新建课题')
          .fontSize(FontSize.body)
          .fontColor(Color.primary)
          .onClick(() => {
            router.pushUrl({ url: 'pages/CreatePlanPage' })
          })
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.md })

      Scroll() {
        Column() {
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
            .padding({ top: Space.xxl, bottom: Space.xl })
          } else {
            Column() {
              ForEach(this.tree, (node: PlanNode) => {
                PlanTreeNode({ node: node, depth: 0 })
              }, (node: PlanNode) => `${node.id}`)
            }
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.lg })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
