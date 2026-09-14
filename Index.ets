import MemberListPage from './MemberListPage';
import MemberDetailPage from './MemberDetailPage';
import PendingApprovalPage from './PendingApprovalPage';
import ManagePage from './ManagePage';

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State showDetail: boolean = false;
  @State selectedMemberId: number = 0;

  build() {
    if (this.showDetail) {
      Column() {
        // 顶部返回栏
        Row() {
          Text('← 返回')
            .fontSize(16)
            .fontColor('#1E88E5')
            .onClick(() => {
              this.showDetail = false;
            })

          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        MemberDetailPage({ memberId: this.selectedMemberId })
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
    } else {
      Navigation() {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() {
            MemberListPage({ onMemberClick: (id: number) => {
              this.selectedMemberId = id;
              this.showDetail = true;
            }})
          }
          .tabBar('成员名录')

          TabContent() {
            PendingApprovalPage()
          }
          .tabBar('待分配')

          TabContent() {
            ManagePage()
          }
          .tabBar('管理')
        }
        .onChange((index: number) => {
          this.currentIndex = index;
        })
      }
      .title('社团管家')
      .titleMode(NavigationTitleMode.Mini)
    }
  }
}
