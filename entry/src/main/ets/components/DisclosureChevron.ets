/** Geometric disclosure icon: no font ascent/baseline mismatch with the label. */
@Component
export struct DisclosureChevron {
  @Prop expanded: boolean = false;
  @StorageProp('vividNightMode') private night: boolean = false;

  build() {
    Image(this.night ? $r('app.media.editor_chevron_night') : $r('app.media.editor_chevron'))
      .width(12).height(12).objectFit(ImageFit.Contain)
      .rotate({ angle: this.expanded ? 90 : 0 });
  }
}
