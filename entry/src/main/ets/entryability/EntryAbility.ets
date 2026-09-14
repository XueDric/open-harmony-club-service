import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'club', '%{public}s', 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'club', '%{public}s', 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 主窗口创建完成：加载首页（ArkTS 页面入口在 resources/base/profile/main_pages.json 登记）
    hilog.info(DOMAIN, 'club', '%{public}s', 'EntryAbility onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'club', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(DOMAIN, 'club', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'club', '%{public}s', 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'club', '%{public}s', 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'club', '%{public}s', 'EntryAbility onBackground');
  }
}
