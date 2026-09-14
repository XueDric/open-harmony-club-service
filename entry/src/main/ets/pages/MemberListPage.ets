// 成员名录页面（B同学负责）
// 按 4 个部门分组展示成员，点击卡片进入成员详情

interface Member {
  id: number;
  name: string;
  role: string;
  deptId: number;
  deptName: string;
  status: string;
  joinedAt: string;
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

const MEMBERS: Member[] = [
  { id: 1, name: '王会长', role: 'president', deptId: 0, deptName: '主席团', status: 'active', joinedAt: '2026-09-01' },
  { id: 2, name: '李副会长', role: 'vice_president', deptId: 0, deptName: '主席团', status: 'active', joinedAt: '2026-09-01' },
  { id: 3, name: '张副会长', role: 'vice_president', deptId: 0, deptName: '主席团', status: 'active', joinedAt: '2026-09-01' },
  { id: 4, name: '赵部长', role: 'lead', deptId: 1, deptName: '课题部', status: 'active', joinedAt: '2026-09-02' },
  { id: 5, name: '孙副部长', role: 'vice_lead', deptId: 1, deptName: '课题部', status: 'active', joinedAt: '2026-09-02' },
  { id: 6, name: '周小明', role: 'member', deptId: 1, deptName: '课题部', status: 'active', joinedAt: '2026-09-03' },
  { id: 7, name: '吴小红', role: 'member', deptId: 1, deptName: '课题部', status: 'active', joinedAt: '2026-09-03' },
  { id: 8, name: '郑部长', role: 'lead', deptId: 2, deptName: '运营部', status: 'active', joinedAt: '2026-09-02' },
  { id: 9, name: '钱副部长', role: 'vice_lead', deptId: 2, deptName: '运营部', status: 'active', joinedAt: '2026-09-02' },
  { id: 10, name: '冯小刚', role: 'member', deptId: 2, deptName: '运营部', status: 'active', joinedAt: '2026-09-04' },
  { id: 11, name: '陈部长', role: 'lead', deptId: 3, deptName: '宣传部', status: 'active', joinedAt: '2026-09-02' },
  { id: 12, name: '褚副部长', role: 'vice_lead', deptId: 3, deptName: '宣传部', status: 'active', joinedAt: '2026-09-02' },
  { id: 13, name: '卫小美', role: 'member', deptId: 3, deptName: '宣传部', status: 'active', joinedAt: '2026-09-05' },
];

const ROLE_MAP: Record<string, string> = {
  'president': '会长',
  'vice_president': '副会长',
  'lead': '部长',
  'vice_lead': '副部长',
  'member': '成员',
};

@Component
struct MemberCard {
  member: Member = { id: 0, name: '', role: 'member', deptId: 0, deptName: '', status: 'active', joinedAt: '' };
  onCardClick: () => void = () => {};

  build() {
    Row() {
      Text(this.member.name.substring(0, 1))
        .fontSize(20)
        .fontColor(Color.White)
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(this.getAvatarColor())
        .textAlign(TextAlign.Center)

      Column() {
        Text(this.member.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)

        Text(this.getRoleName())
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(8)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.onCardClick();
    })
  }

  getRoleName(): string {
    return ROLE_MAP[this.member.role] || '成员';
  }

  getAvatarColor(): string {
    switch (this.member.role) {
      case 'president': return '#E53935';
      case 'vice_president': return '#FB8C00';
      case 'lead': return '#1E88E5';
      case 'vice_lead': return '#43A047';
      default: return '#7E57C2';
    }
  }
}

@Component
struct DeptSection {
  deptName: string = '';
  members: Member[] = [];
  onMemberClick: (memberId: number) => void = (_id: number) => {};

  build() {
    Column() {
      Text(this.deptName)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#333333')
        .width('100%')
        .padding({ left: 4, top: 8, bottom: 4 })

      ForEach(this.members, (item: Member) => {
        MemberCard({
          member: item,
          onCardClick: () => this.onMemberClick(item.id)
        })
      }, (item: Member) => item.id.toString())
    }
    .width('100%')
  }
}

@Component
export default struct MemberListPage {
  onMemberClick: (memberId: number) => void = (_id: number) => {};
  @State members: Member[] = MEMBERS;

  getMembersByDept(deptId: number): Member[] {
    return this.members.filter((m: Member) => m.deptId === deptId);
  }

  build() {
    Column() {
      Row() {
        Text('🔍  搜索成员')
          .fontSize(14)
          .fontColor('#999999')
          .width('100%')
          .padding(12)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      List({ space: 8 }) {
        ForEach(DEPTS, (dept: Dept) => {
          ListItem() {
            DeptSection({
              deptName: dept.name,
              members: this.getMembersByDept(dept.id),
              onMemberClick: (id: number) => this.onMemberClick(id)
            })
          }
        }, (dept: Dept) => dept.id.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 4, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAFAFA')
  }
}
