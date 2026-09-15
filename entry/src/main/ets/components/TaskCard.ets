/**
 * 任务卡片 TaskCard（白底 · r14 · 内边距 14 · L2 阴影）
 * 标题 + 状态胶囊 + 一行副信息；阻塞原因高亮块在任务详情页单独展示（brief 不含 blocker）。
 */
import router from '@ohos.router'
import { TaskBrief } from '../api/TaskApi'
import { StatusChip } from './StatusChip'
import { Color, FontSize, Radius, Shadow, Space, StatusColor } from '../core/Theme'

@Component
export struct TaskCard {
  @Prop task: TaskBrief
  @Prop subtitle: string = ''

  build() {
    Column() {
      Row() {
        Text(this.task.title)
          .fontSize(FontSize.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.task.is_overdue ? StatusColor.overdue.fg : Color.textPrimary)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        StatusChip({ status: this.task.status, isOverdue: this.task.is_overdue })
          .margin({ left: Space.sm })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(FontSize.caption)
          .fontColor(this.task.is_overdue ? StatusColor.overdue.fg : Color.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: Space.xs })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(Space.card)
    .backgroundColor(Color.surface)
    .borderRadius(Radius.card)
    .shadow(Shadow.card)
    .onClick(() => {
      router.pushUrl({ url: 'pages/TaskDetailPage', params: { task_id: this.task.id } })
    })
  }
}
