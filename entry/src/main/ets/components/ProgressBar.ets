/**
 * 进度条 ProgressBar（课题树顶层 / 课题详情）
 * done/total 是服务端递归聚合值，客户端只负责画。
 */
import { Color, StatusColor } from '../core/Theme'

@Component
export struct ProgressBar {
  @Prop done: number
  @Prop total: number

  build() {
    Progress({
      value: this.total > 0 ? this.done : 0,
      total: this.total > 0 ? this.total : 1,
      type: ProgressType.Linear
    })
      .color(Color.primary)
      .backgroundColor(StatusColor.todo.bg)
      .height(6)
      .width('100%')
  }
}
