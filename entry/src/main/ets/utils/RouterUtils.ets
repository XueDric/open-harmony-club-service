/**
 * 路由工具函数
 * 统一处理 router 调用，避免 ArkTS 严格模式下的对象字面量类型问题
 */
import { router } from '@kit.ArkUI';

export function replaceTo(url: string): void {
  const opt: router.RouterOptions = { url: url };
  router.replaceUrl(opt);
}

export function pushTo(url: string): void {
  const opt: router.RouterOptions = { url: url };
  router.pushUrl(opt);
}

export function backPage(): void {
  router.back();
}
