import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { LumixBleCameraCandidate } from './LumixImportPrototype';
import { LumixCameraService, LumixWifiCandidate } from './LumixCameraService';

/** Identity only: credentials, tokens and rotating BLE addresses never enter this record. */
export interface CameraCardHistoryRecord {
  id: string;
  deviceName: string;
  model: string;
  imageKey: string;
  brand: string;
  aliases: string[];
  blePaired: boolean;
  lastUsedAt: number;
  /** Stable identity the body advertises in its BLE manufacturer data (8 hex
   * digits). Absent for Wi-Fi-only and legacy records, which keep the
   * alias-based matching unchanged. */
  btAddress?: string;
}

interface CameraCardWifiObservation {
  candidate: LumixWifiCandidate;
  seenAt: number;
}

/** Successful connections survive radio scans; observations only prove current proximity. */
export class CameraCardRegistry {
  static readonly instance: CameraCardRegistry = new CameraCardRegistry();
  private records: CameraCardHistoryRecord[] = [];
  private ble: LumixBleCameraCandidate[] = [];
  private wifi: CameraCardWifiObservation[] = [];
  private onlineSince: Map<string, number> = new Map<string, number>();
  private previouslyOnline: Set<string> = new Set<string>();
  private connected: LumixBleCameraCandidate | null = null;
  private loaded: boolean = false;
  private loading: Promise<void> | null = null;
  private migrated: boolean = false;
  private writes: Promise<void> = Promise.resolve();

  private cleanName(name: string): string {
    return name.replace(/[\u0000-\u001F\u007F]/g, '').trim();
  }

  private alias(name: string, brand: string): string {
    let normalized = this.cleanName(name).toLowerCase().replace(/[-\s]+/g, '_');
    // Nikon's BLE and AP names sometimes differ only by the brand prefix.
    // Keep the complete model + serial: two bodies of one model remain distinct.
    if (brand === 'Nikon' && normalized.indexOf('nikon_') === 0) normalized = normalized.substring(6);
    // Fujifilm's AP SSID is `FUJIFILM-<model>-<suffix>` while the BLE name is just
    // `<serial><model>`: dropping the vendor prefix lets the Wi-Fi tile and the
    // BLE tile resolve to one card instead of two.
    if (brand === 'FUJIFILM' && normalized.indexOf('fujifilm_') === 0) normalized = normalized.substring(9);
    return normalized;
  }

  /** Normalise an advertised Bluetooth address to 8 uppercase hex digits. */
  private cleanAddress(address: string | undefined): string {
    if (!address) return '';
    return address.replace(/[^0-9A-Fa-f]/g, '').toUpperCase();
  }

  /** Identity for a candidate that is not in the saved list yet. The body's
   * advertised address is preferred because a camera rename changes only the
   * local name; bodies that advertise no address keep the alias form. */
  private identityKey(candidate: LumixBleCameraCandidate): string {
    const brand = candidate.brand || 'Panasonic';
    const address = this.cleanAddress(candidate.btAddress);
    if (address.length > 0) return `${brand}:bt:${address}`;
    return `${brand}:${this.alias(candidate.deviceName || candidate.deviceId, brand)}`;
  }

  /** Match a saved record by advertised address first, then by name alias.
   * The alias path is what every Wi-Fi-only, legacy and non-LUMIX candidate
   * still uses, so their behaviour is unchanged. */
  private find(name: string, brand: string, btAddress?: string): CameraCardHistoryRecord | undefined {
    const address = this.cleanAddress(btAddress);
    if (address.length > 0) {
      const byAddress = this.records.find((record: CameraCardHistoryRecord): boolean =>
        record.brand === brand && this.cleanAddress(record.btAddress) === address);
      if (byAddress) return byAddress;
    }
    const alias = this.alias(name, brand);
    return this.records.find((record: CameraCardHistoryRecord): boolean =>
      record.brand === brand && record.aliases.indexOf(alias) >= 0);
  }

  key(candidate: LumixBleCameraCandidate): string {
    const brand = candidate.brand || 'Panasonic';
    const saved = this.find(candidate.deviceName, brand, candidate.btAddress);
    return saved ? saved.id : this.identityKey(candidate);
  }

  isSaved(candidate: LumixBleCameraCandidate): boolean {
    return this.find(candidate.deviceName, candidate.brand || 'Panasonic', candidate.btAddress) !== undefined;
  }

  isBlePaired(candidate: LumixBleCameraCandidate): boolean {
    return this.find(candidate.deviceName, candidate.brand || 'Panasonic',
      candidate.btAddress)?.blePaired || false;
  }

  isOnline(candidate: LumixBleCameraCandidate, now: number = Date.now()): boolean {
    if (this.connected && this.key(this.connected) === this.key(candidate)) return true;
    return (candidate.bleLastSeenAt !== undefined && now - candidate.bleLastSeenAt <= 6000) ||
      (candidate.wifiLastSeenAt !== undefined && now - candidate.wifiLastSeenAt <= 12000);
  }

  async load(context: common.UIAbilityContext): Promise<void> {
    if (this.loaded) return;
    if (this.loading) return this.loading;
    this.loading = this.read(context);
    try { await this.loading; } finally { this.loading = null; }
  }

  private async read(context: common.UIAbilityContext): Promise<void> {
    const store = await preferences.getPreferences(context, 'pixelshop_camera_cards');
    const encoded = await store.get('connections_v1', '[]');
    const restored: CameraCardHistoryRecord[] = [];
    if (typeof encoded === 'string') {
      try {
        const parsed = JSON.parse(encoded) as CameraCardHistoryRecord[];
        if (Array.isArray(parsed)) {
          for (const record of parsed) {
            if (!record || typeof record.deviceName !== 'string' || typeof record.brand !== 'string' ||
              typeof record.model !== 'string' || typeof record.imageKey !== 'string' ||
              !Array.isArray(record.aliases)) continue;
            const name = this.cleanName(record.deviceName);
            const aliases = record.aliases.filter((item: string): boolean => typeof item === 'string' && item.length > 0);
            const primary = this.alias(name, record.brand);
            if (primary.length === 0) continue;
            if (aliases.indexOf(primary) < 0) aliases.push(primary);
            // An address-keyed record must keep its id across a restart,
            // otherwise the next load would re-key it back to the name and a
            // rename would split the card again.
            const address = this.cleanAddress(record.btAddress);
            if (restored.some((known: CameraCardHistoryRecord): boolean => known.brand === record.brand &&
              (known.aliases.some((item: string): boolean => aliases.indexOf(item) >= 0) ||
                (address.length > 0 && this.cleanAddress(known.btAddress) === address)))) continue;
            restored.push({ id: address.length > 0 ? `${record.brand}:bt:${address}` : `${record.brand}:${primary}`,
              deviceName: name, model: record.model,
              imageKey: record.imageKey, brand: record.brand, aliases: aliases,
              btAddress: address.length > 0 ? address : undefined,
              blePaired: record.blePaired === true,
              lastUsedAt: Number.isFinite(record.lastUsedAt) ? Math.max(0, record.lastUsedAt) : 0 });
          }
        }
      } catch (_error) { }
    }
    this.records = restored;
    this.migrated = (await store.get('legacy_migrated', false)) === true;
    this.loaded = true;
  }

  /** The old store retained one registered identity, without a last-used timestamp. */
  async migrateLegacy(context: common.UIAbilityContext, candidate: LumixBleCameraCandidate | null): Promise<void> {
    await this.load(context);
    if (this.migrated) return;
    this.migrated = true;
    if (candidate && !this.isSaved(candidate)) this.upsert(candidate, '',
      candidate.brand === 'Panasonic' && LumixCameraService.panasonicRouteForModel(
        `${candidate.model} ${candidate.deviceName}`) !== 'sync' &&
      LumixCameraService.panasonicRouteForModel(
        `${candidate.model} ${candidate.deviceName}`) !== 'lumix_image', 0);
    await this.persist(context);
  }

  async remember(context: common.UIAbilityContext, candidate: LumixBleCameraCandidate,
    wifiSsid: string = '', blePaired: boolean = false, now: number = Date.now()): Promise<void> {
    await this.load(context);
    if (this.cleanName(candidate.deviceName).length === 0) return;
    this.upsert(candidate, wifiSsid, blePaired, now);
    await this.persist(context);
  }

  private upsert(candidate: LumixBleCameraCandidate, wifiSsid: string, blePaired: boolean, now: number): void {
    const brand = candidate.brand || 'Panasonic';
    const address = this.cleanAddress(candidate.btAddress);
    const existing = this.find(candidate.deviceName, brand, candidate.btAddress) || this.find(wifiSsid, brand);
    const name = existing ? existing.deviceName : this.cleanName(candidate.deviceName);
    const aliases = existing ? existing.aliases.slice() : [];
    for (const item of [candidate.deviceName, wifiSsid]) {
      const normalized = this.alias(item, brand);
      if (normalized.length > 0 && aliases.indexOf(normalized) < 0) aliases.push(normalized);
    }
    // A rename replaces the alias but not the advertised address, so keep the
    // address (and therefore the id) and let the new name become an alias.
    const record: CameraCardHistoryRecord = {
      id: existing ? existing.id : this.identityKey(candidate),
      deviceName: name, brand: brand, model: candidate.model || existing?.model || '',
      imageKey: candidate.imageKey || existing?.imageKey || '', aliases: aliases,
      btAddress: address.length > 0 ? address : existing?.btAddress,
      blePaired: blePaired || existing?.blePaired || false, lastUsedAt: Math.max(now, existing?.lastUsedAt || 0) };
    this.records = this.records.filter((known: CameraCardHistoryRecord): boolean =>
      !(known.brand === brand && (known.aliases.some((item: string): boolean => aliases.indexOf(item) >= 0) ||
        (address.length > 0 && this.cleanAddress(known.btAddress) === address))));
    this.records.push(record);
  }

  async forget(context: common.UIAbilityContext, candidate: LumixBleCameraCandidate): Promise<void> {
    await this.load(context);
    const key = this.key(candidate);
    this.ble = this.ble.filter((known: LumixBleCameraCandidate): boolean => this.key(known) !== key);
    this.wifi = this.wifi.filter((known: CameraCardWifiObservation): boolean =>
      this.key(this.wifiTile(known)) !== key);
    if (this.connected && this.key(this.connected) === key) this.connected = null;
    this.records = this.records.filter((record: CameraCardHistoryRecord): boolean => record.id !== key);
    await this.persist(context);
  }

  private async persist(context: common.UIAbilityContext): Promise<void> {
    const encoded = JSON.stringify(this.records);
    const migrated = this.migrated;
    const next = this.writes.catch((): void => {}).then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'pixelshop_camera_cards');
      await store.put('connections_v1', encoded);
      await store.put('legacy_migrated', migrated);
      await store.flush();
    });
    this.writes = next;
    await next;
  }

  clearRadioObservations(): void { this.ble = []; this.wifi = []; }

  observeBle(candidate: LumixBleCameraCandidate, now: number = Date.now()): void {
    const key = this.key(candidate);
    this.ble = this.ble.filter((known: LumixBleCameraCandidate): boolean => this.key(known) !== key);
    this.ble.push({ deviceId: candidate.deviceId, deviceName: candidate.deviceName, model: candidate.model,
      imageKey: candidate.imageKey, brand: candidate.brand, rssi: candidate.rssi, connectable: candidate.connectable,
      btAddress: candidate.btAddress,
      lastSeenAt: now, bleLastSeenAt: now });
  }

  replaceWifi(candidates: LumixWifiCandidate[], now: number = Date.now()): void {
    this.wifi = candidates.map((candidate: LumixWifiCandidate): CameraCardWifiObservation =>
      ({ candidate: candidate, seenAt: now }));
  }

  setConnected(candidate: LumixBleCameraCandidate | null): void { this.connected = candidate; }

  hasOtherConnection(candidate: LumixBleCameraCandidate): boolean {
    return this.connected !== null && this.key(this.connected) !== this.key(candidate);
  }

  private wifiTile(observation: CameraCardWifiObservation): LumixBleCameraCandidate {
    const candidate = observation.candidate;
    // Wi-Fi tiles the user may act on without a fresh Bluetooth pairing step.
    // Sony does not pair at all. Nikon has two routes: Bluetooth provisioning,
    // which delivers the Wi-Fi credentials and is started from the
    // pre-connection hint, and the legacy pure-Wi-Fi / WMU-compatible route a
    // body can enter on its own. A Nikon tile therefore stays directly
    // connectable, so an already-provisioned body is not forced back through
    // pairing. The LUMIX Image App line has no radio at all.
    const route = LumixCameraService.panasonicRouteForModel(candidate.model);
    const direct = candidate.brand === 'Nikon' || candidate.brand === 'Sony' ||
      // Fujifilm has no separate registration step before its AP is usable: the
      // SSID/passphrase are read over BLE on demand, so an AP tile is actionable.
      candidate.brand === 'FUJIFILM' ||
      LumixCameraService.isCamCgiRoute(route);
    return { deviceId: '', deviceName: candidate.ssid, model: candidate.model, imageKey: candidate.imageKey,
      brand: candidate.brand || 'Panasonic', rssi: candidate.rssi, connectable: direct,
      lastSeenAt: observation.seenAt, wifiLastSeenAt: observation.seenAt, wifiSsid: candidate.ssid };
  }

  cards(now: number = Date.now()): LumixBleCameraCandidate[] {
    this.ble = this.ble.filter((candidate: LumixBleCameraCandidate): boolean =>
      now - (candidate.bleLastSeenAt || 0) <= 6000);
    this.wifi = this.wifi.filter((observation: CameraCardWifiObservation): boolean => now - observation.seenAt <= 12000);
    const merged: Map<string, LumixBleCameraCandidate> = new Map<string, LumixBleCameraCandidate>();
    for (const record of this.records) merged.set(record.id, { deviceId: '', deviceName: record.deviceName,
      model: record.model, imageKey: record.imageKey, brand: record.brand, rssi: 0, connectable: false,
      btAddress: record.btAddress });
    for (const observation of this.wifi) {
      if (now - observation.seenAt > 12000) continue;
      const tile = this.wifiTile(observation);
      const key = this.key(tile);
      const previous = merged.get(key);
      if (previous) tile.deviceName = previous.deviceName;
      merged.set(key, tile);
    }
    for (const candidate of this.ble) {
      if (now - (candidate.bleLastSeenAt || 0) > 6000) continue;
      const key = this.key(candidate);
      const previous = merged.get(key);
      // A generic LUMIX observation carries no model. Never let it blank a
      // model/imageKey that a saved record or the Wi-Fi scan already supplied.
      const resolvedModel = candidate.model.length > 0 ? candidate.model : (previous?.model || '');
      const resolvedImage = candidate.imageKey.length > 0 ? candidate.imageKey : (previous?.imageKey || '');
      const resolvedName = candidate.deviceName.length > 0 ? candidate.deviceName : (previous?.deviceName || '');
      merged.set(key, { deviceId: candidate.deviceId, deviceName: resolvedName, model: resolvedModel,
        imageKey: resolvedImage, brand: candidate.brand, rssi: candidate.rssi, connectable: candidate.connectable,
        btAddress: candidate.btAddress,
        lastSeenAt: candidate.bleLastSeenAt, bleLastSeenAt: candidate.bleLastSeenAt,
        wifiLastSeenAt: previous?.wifiLastSeenAt, wifiSsid: previous?.wifiSsid });
    }
    if (this.connected && !merged.has(this.key(this.connected))) merged.set(this.key(this.connected), this.connected);
    const currentOnline: Set<string> = new Set<string>();
    const cards: LumixBleCameraCandidate[] = Array.from(merged.values());
    for (const candidate of cards) {
      const key = this.key(candidate);
      if (!this.isOnline(candidate, now)) continue;
      currentOnline.add(key);
      if (!this.previouslyOnline.has(key)) this.onlineSince.set(key, now);
    }
    for (const key of this.onlineSince.keys()) if (!merged.has(key)) this.onlineSince.delete(key);
    this.previouslyOnline = currentOnline;
    return cards.sort((left: LumixBleCameraCandidate, right: LumixBleCameraCandidate): number => {
      const leftOnline = this.isOnline(left, now);
      const rightOnline = this.isOnline(right, now);
      if (leftOnline !== rightOnline) return leftOnline ? -1 : 1;
      if (leftOnline) {
        const seen = (this.onlineSince.get(this.key(right)) || 0) - (this.onlineSince.get(this.key(left)) || 0);
        if (seen !== 0) return seen;
      }
      const used = (this.find(right.deviceName, right.brand || 'Panasonic', right.btAddress)?.lastUsedAt || 0) -
        (this.find(left.deviceName, left.brand || 'Panasonic', left.btAddress)?.lastUsedAt || 0);
      return used !== 0 ? used : this.key(left).localeCompare(this.key(right));
    });
  }
}
