import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';

export interface SharePhoto {
  uri: string;
  displayName: string;
}

/** Share Kit grants the receiver access to application file URIs.
 * Stage the original under its real filename, not the home-page thumbnail.
 * Keep staged files after show() resolves: recipients can read them later. */
export class PhotoShareService {
  static async share(context: common.UIAbilityContext, photos: SharePhoto[]): Promise<void> {
    if (photos.length === 0) return;
    const directory = context.cacheDir + '/photo_share_' + Date.now().toString(36);
    await fileIo.mkdir(directory);
    const records: systemShare.SharedRecord[] = [];
    for (let index = 0; index < photos.length; index++) {
      const photo = photos[index];
      const name = photo.displayName.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_') || '图片';
      const itemDirectory = directory + '/' + index.toString();
      await fileIo.mkdir(itemDirectory);
      const path = itemDirectory + '/' + name;
      const source = await fileIo.open(photo.uri, fileIo.OpenMode.READ_ONLY);
      try {
        await fileIo.copyFile(source.fd, path);
      } finally {
        await fileIo.close(source);
      }
      // RAW stays a file; JPEG/PNG/HEIF etc. are declared as images so
      // installed WeChat/QQ and Huawei Share can advertise supported targets.
      const isImage = /\.(jpe?g|png|heic|heif|webp|gif|bmp|tiff?|avif)$/i.test(name);
      records.push({
        utd: isImage ? uniformTypeDescriptor.UniformDataType.IMAGE : uniformTypeDescriptor.UniformDataType.FILE,
        uri: fileUri.getUriFromPath(path),
        title: photo.displayName,
      });
    }
    const data = new systemShare.SharedData(records[0]);
    for (let index = 1; index < records.length; index++) data.addRecord(records[index]);
    const controller = new systemShare.ShareController(data);
    await controller.show(context, { selectionMode: systemShare.SelectionMode.BATCH });
  }
}
