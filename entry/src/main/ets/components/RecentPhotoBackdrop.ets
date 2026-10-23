/**
 * A quiet, full-screen filmstrip behind the workbench.
 *
 * Frames keep their source aspect ratio. Landscape photos use the viewport
 * width as their long edge; portrait photos use the viewport height. The
 * second copy of the four-frame sequence makes the reset invisible when the
 * first copy has scrolled away.
 */
@Component
export struct RecentPhotoBackdrop {
  @Prop imageUris: string[] = [];
  @State private offsetY: number = 0;
  @State private viewportWidth: number = 390;
  @State private viewportHeight: number = 720;
  @State private ratios: number[] = [];
  private scrollTimer: number = -1;

  aboutToAppear(): void {
    this.scrollTimer = setInterval(() => {
      const frameCount = this.imageUris.length;
      if (frameCount === 0 || this.viewportHeight <= 0) return;
      const cycleHeight = this.cycleHeight();
      if (cycleHeight <= 0) return;
      this.offsetY += 0.55;
      while (this.offsetY >= cycleHeight) this.offsetY -= cycleHeight;
    }, 16);
  }

  aboutToDisappear(): void {
    if (this.scrollTimer >= 0) {
      clearInterval(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  private loopUris(): string[] {
    if (this.imageUris.length === 0) return [];
    return this.imageUris.concat(this.imageUris);
  }

  private aspectFor(index: number): number {
    // The first frame is rendered immediately, before onComplete reports its
    // dimensions. A neutral landscape ratio keeps that first layout stable.
    const sourceIndex = this.imageUris.length === 0 ? 0 : index % this.imageUris.length;
    const ratio = this.ratios[sourceIndex];
    return ratio && ratio > 0 ? ratio : 1.5;
  }

  private frameHeightFor(index: number): number {
    const ratio = this.aspectFor(index);
    if (ratio < 1) return Math.max(1, this.viewportHeight);
    return Math.max(1, Math.round(this.viewportWidth / ratio));
  }

  private frameWidthFor(index: number): number {
    const ratio = this.aspectFor(index);
    if (ratio < 1) return Math.max(1, Math.round(this.viewportHeight * ratio));
    return Math.max(1, this.viewportWidth);
  }

  private cycleHeight(): number {
    let total = 0;
    for (let index = 0; index < this.imageUris.length; index++) {
      total += this.frameHeightFor(index);
    }
    return total;
  }

  private updateAspect(index: number, width: number, height: number): void {
    if (width <= 0 || height <= 0 || this.imageUris.length === 0) return;
    const ratio = width / height;
    const next = this.ratios.slice();
    if (next[index] && Math.abs(next[index] - ratio) < 0.01) return;
    next[index] = ratio;
    this.ratios = next;
  }

  build() {
    Stack() {
      Column() {
        ForEach(this.loopUris(), (uri: string, index: number) => {
          Image(uri)
            .width(this.frameWidthFor(index))
            .height(this.frameHeightFor(index))
            .objectFit(ImageFit.Contain)
            .objectRepeat(ImageRepeat.NoRepeat)
            .alignSelf(ItemAlign.Center)
            .onComplete((event) => {
              const count = this.imageUris.length;
              if (event && count > 0) this.updateAspect(index % count, event.width, event.height);
            });
        }, (_uri: string, index: number) => `recent-background-${index}`);
      }
      .width('100%')
      .translate({ y: -this.offsetY })
      .opacity(0.72);
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
    .opacity(this.imageUris.length > 0 ? 1 : 0)
    .onAreaChange((_: Area, area: Area) => {
      const nextWidth = Number(area.width);
      const nextHeight = Number(area.height);
      if (nextWidth > 0 && Math.abs(nextWidth - this.viewportWidth) > 1) {
        this.viewportWidth = nextWidth;
        this.offsetY = 0;
      }
      if (nextHeight > 0 && Math.abs(nextHeight - this.viewportHeight) > 1) {
        this.viewportHeight = nextHeight;
        this.offsetY = 0;
      }
    });
  }
}
