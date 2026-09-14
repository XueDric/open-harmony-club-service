// 待分配审批页面（B同学负责）
// 展示 pending 状态的成员，支持多选批量分配部门+角色

interface PendingMember {
  id: number;
  name: string;
  deptHint: string;
  registeredAt: string;
  selected: boolean;
}

interface Dept {
  id: number;
  name: string;
}

// ====== 假数据 ======
const DEPTS: Dept[] = [
  { id: 0, name: '主席团' },
  { id: 1, name: '课题部' },
  { id: 2, name: '运营部' },
  { id: 3, name: '宣传部' },
];

const ROLES: string[] = ['member', 'vice_lead', 'lead', 'vice_president', 'president'];
const ROLE_LABEL: Record<string, string> = {
  'member': '成员',
  'vice_lead': '副部长',
  'lead': '部长',
  'vice_president': '副会长',
  'president': '会长',
};

const PENDING_MEMBERS: PendingMember[] = [
  { id: 101, name: '新同学A', deptHint: '课题部', registeredAt: '2026-09-14 10:30', selected: false },
  { id: 102, name: '新同学B', deptHint: '', registeredAt: '2026-09-14 11:00', selected: false },
  { id: 103, name: '新同学C', deptHint: '运营部', registeredAt: '2026-09-14 14:20', selected: false },
  { id: 104, name: '新同学D', deptHint: '宣传部', registeredAt: '2026-09-14 15:45', selected: false },
  { id: 105, name: '新同学E', deptHint: '', registeredAt: '2026-09-14 16:10', selected: false },
];

@Component
struct PendingMemberCard {
  member: PendingMember = { id: 0, name: '', deptHint: '', registeredAt: '', selected: false };
  onToggle: (id: number) => void = (_id: number) => {};

  build() {
    Row() {
      Checkbox()
        .select(this.member.selected)
        .onChange((checked: boolean) => {
          this.onToggle(this.member.id);
        })
        .width(24)
        .height(24)

      Column() {
        Row() {
          Text(this.member.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)

          if (this.member.deptHint.length > 0) {
            Text(`· 意向: ${this.member.deptHint}`)
              .fontSize(12)
              .fontColor('#FB8C00')
              .margin({ left: 8 })
          }
        }

        Text(`注册于 ${this.member.registeredAt}`)
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      .layoutWeight(1)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
    .margin({ bottom: 8 })
  }
}

@Component
struct AssignBottomBar {
  selectedCount: number = 0;
  onAssign: () => void = () => {};

  build() {
    Row() {
      Text(`已选 ${this.selectedCount} 人`)
        .fontSize(14)
        .fontColor('#666666')

      Button('批量分配')
        .type(ButtonType.Capsule)
        .enabled(this.selectedCount > 0)
        .onClick(() => {
          this.onAssign();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(Color.White)
    .justifyContent(FlexAlign.SpaceBetween)
    .shadow({ radius: 4, color: '#1A000000', offsetY: -2 })
  }
}

@Component
struct AssignDialog {
  show: boolean = false;
  selectedDeptId: number = 1;
  selectedRoleIndex: number = 0;
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};

  build() {
    if (this.show) {
      Column() {
        Column() {
          Text('批量分配')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 16 })

          Text('分配到部门')
            .fontSize(14)
            .fontColor('#666666')
            .width('100%')
            .margin({ bottom: 6 })

          Select([
            { value: DEPTS[0].name },
            { value: DEPTS[1].name },
            { value: DEPTS[2].name },
            { value: DEPTS[3].name },
          ])
            .selected(this.selectedDeptId)
            .value(DEPTS[this.selectedDeptId].name)
            .onSelect((index: number) => {
              this.selectedDeptId = index;
            })
            .width('100%')
            .margin({ bottom: 16 })

          Text('角色')
            .fontSize(14)
            .fontColor('#666666')
            .width('100%')
            .margin({ bottom: 6 })

          Select([
            { value: ROLE_LABEL['member'] },
            { value: ROLE_LABEL['vice_lead'] },
            { value: ROLE_LABEL['lead'] },
            { value: ROLE_LABEL['vice_president'] },
            { value: ROLE_LABEL['president'] },
          ])
            .selected(this.selectedRoleIndex)
            .value(ROLE_LABEL[ROLES[this.selectedRoleIndex]])
            .onSelect((index: number) => {
              this.selectedRoleIndex = index;
            })
            .width('100%')
            .margin({ bottom: 20 })

          Row() {
            Button('取消')
              .type(ButtonType.Normal)
              .backgroundColor('#F5F5F5')
              .fontColor('#666666')
              .layoutWeight(1)
              .onClick(() => {
                this.onCancel();
              })

            Button('确认分配')
              .type(ButtonType.Capsule)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                this.onConfirm();
              })
          }
          .width('100%')
        }
        .width('85%')
        .padding(20)
        .backgroundColor(Color.White)
        .borderRadius(12)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
  }
}

@Component
export default struct PendingApprovalPage {
  @State members: PendingMember[] = PENDING_MEMBERS;
  @State showAssignDialog: boolean = false;

  toggleSelect(id: number): void {
    const idx = this.members.findIndex((m: PendingMember) => m.id === id);
    if (idx >= 0) {
      this.members[idx].selected = !this.members[idx].selected;
      this.members = [...this.members];
    }
  }

  getSelectedCount(): number {
    return this.members.filter((m: PendingMember) => m.selected).length;
  }

  selectAll(): void {
    const allSelected = this.getSelectedCount() === this.members.length;
    this.members.forEach((m: PendingMember) => m.selected = !allSelected);
    this.members = [...this.members];
  }

  build() {
    Column() {
      Row() {
        Text('待审批列表')
          .fontSize(14)
          .fontColor('#666666')

        Blank()

        Text(this.getSelectedCount() === this.members.length ? '取消全选' : '全选')
          .fontSize(14)
          .fontColor('#1E88E5')
          .onClick(() => {
            this.selectAll();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.members.length === 0) {
        Column() {
          Text('🎉')
            .fontSize(48)
            .margin({ bottom: 12 })

          Text('暂无待审批成员')
            .fontSize(14)
            .fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.members, (item: PendingMember) => {
            ListItem() {
              PendingMemberCard({
                member: item,
                onToggle: (id: number) => this.toggleSelect(id)
              })
            }
          }, (item: PendingMember) => item.id.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      if (this.getSelectedCount() > 0) {
        AssignBottomBar({
          selectedCount: this.getSelectedCount(),
          onAssign: () => {
            this.showAssignDialog = true;
          }
        })
      }

      AssignDialog({
        show: this.showAssignDialog,
        onConfirm: () => {
          this.showAssignDialog = false;
          this.members.forEach((m: PendingMember) => m.selected = false);
          this.members = [...this.members];
        },
        onCancel: () => {
          this.showAssignDialog = false;
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAFAFA')
  }
}
