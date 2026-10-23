/**
 * 掩码栅格化的共享扁平类型。
 *
 * 单独成文件是为了打断循环依赖：MaskRasterCore 与 AutoMaskBrush 都需要
 * MaskWorkerPoint，而 AutoMaskBrush 又被 MaskRasterCore 引用。循环 import 在
 * 主线程可能侥幸能跑，但同一个模块还要在 TaskPool worker VM 里加载，那里会
 * 直接拿到 undefined —— 所以类型放在这条依赖链的末端。
 */

/** 一个落笔点：坐标与半径都是源图归一化空间（0..1 / 短边比例）。 */
export interface MaskWorkerPoint { x: number; y: number; radius: number; hardness: number; }
