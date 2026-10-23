import { PhoneLayout } from './PhoneLayout';
import { TabletLayout } from './TabletLayout';
import { DetailRegion } from '../edit/models/EditSession';
import { RecentPhotoRecord } from '../services/RecentPhotoStore';

@Component
export struct EditorLayout {
  @StorageProp('windowWidth') windowWidth: number = 360;
  onRequestDetailRender: (region: DetailRegion | null) => void = () => {};
  onAddPhoto: () => void = () => {};
  @Prop photos: RecentPhotoRecord[] = [];
  @Prop currentUri: string = '';
  @Prop captureInfo: string = '';
  onSelectPhoto: (uri: string) => void = () => {};
  onRatePhoto: (uri: string, stars: number) => void = () => {};

  build() {
    if (this.windowWidth < 840) {
      PhoneLayout({ onRequestDetailRender: this.onRequestDetailRender });
    } else {
      TabletLayout({ onRequestDetailRender: this.onRequestDetailRender, onAddPhoto: this.onAddPhoto,
        photos: this.photos, currentUri: this.currentUri, captureInfo: this.captureInfo,
        onSelectPhoto: this.onSelectPhoto, onRatePhoto: this.onRatePhoto });
    }
  }
}

