import { authentication } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

/** executeRequest 返回的裸响应兜底模型（框架异常时 instanceof 失效）。 */
class RawLoginResponse {
  data?: RawLoginCredential;
}

class RawLoginCredential {
  openID: string = '';
  unionID: string = '';
}

class RawAuthResponse {
  data?: RawAuthCredential;
}

class RawAuthCredential {
  openID?: string;
  unionID?: string;
  nickName?: string;
  avatarUri?: string;
}

/**
 * 华为账号会话：登录取 openID/unionID（服务端用户目录标识），再以
 * profile scope 取头像昵称。会话持久化在 pixelshop_profile，
 * 与日志识别码同一个 preferences 存储。
 */
export class HuaweiAccountService {
  static openId: string = '';
  static unionId: string = '';
  static nickName: string = '';
  static avatarUri: string = '';
  private static loadPromise: Promise<void> | null = null;
  // 请求对象必须以强引用持有到 executeRequest 返回：框架内部用弱引用
  // 记录 request→response 类型的映射，过早释放会导致响应无法构造。
  private static loginRequest: authentication.LoginWithHuaweiIDRequest | null = null;
  private static authRequest: authentication.AuthorizationWithHuaweiIDRequest | null = null;

  static isLoggedIn(): boolean {
    return HuaweiAccountService.openId.length > 0;
  }

  /** 进页/上传前恢复上次会话；幂等，可反复调用。 */
  static ensureLoaded(context: common.Context): Promise<void> {
    if (HuaweiAccountService.loadPromise === null) {
      HuaweiAccountService.loadPromise =
        preferences.getPreferences(context, 'pixelshop_profile')
          .then(async (store: preferences.Preferences) => {
            const openId = await store.get('hwOpenId', '');
            if (typeof openId === 'string' && openId.length > 0) {
              HuaweiAccountService.openId = openId;
              const unionId = await store.get('hwUnionId', '');
              if (typeof unionId === 'string') HuaweiAccountService.unionId = unionId;
              const nickName = await store.get('hwNickname', '');
              if (typeof nickName === 'string') HuaweiAccountService.nickName = nickName;
              const avatarUri = await store.get('hwAvatar', '');
              if (typeof avatarUri === 'string') HuaweiAccountService.avatarUri = avatarUri;
            }
          })
          .catch(() => {
            // 读取失败按未登录处理；下次进页会重新尝试。
          });
    }
    return HuaweiAccountService.loadPromise;
  }

  private static async persist(context: common.Context): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, 'pixelshop_profile');
      await store.put('hwOpenId', HuaweiAccountService.openId);
      await store.put('hwUnionId', HuaweiAccountService.unionId);
      await store.put('hwNickname', HuaweiAccountService.nickName);
      await store.put('hwAvatar', HuaweiAccountService.avatarUri);
      await store.flush();
    } catch (_error) {
      // 持久化失败不影响本次会话使用。
    }
  }

  /** 诊断用：标识 SDK 返回的响应类型。 */
  private static responseKind(response: authentication.AuthenticationResponse): string {
    if (response instanceof authentication.LoginWithHuaweiIDResponse) return 'login';
    if (response instanceof authentication.AuthorizationWithHuaweiIDResponse) return 'authorization';
    if (response instanceof authentication.CancelAuthorizationResponse) return 'cancel';
    return 'unknown';
  }

  /** 裸响应兜底：框架异常时返回的不是类型化响应，但字段可能仍在。 */
  private static rawCredentialText(response: authentication.AuthenticationResponse): string {
    try {
      return JSON.stringify(response);
    } catch (_error) {
      return '<unserializable>';
    }
  }

  /**
   * 拉起华为账号登录。成功返回空串；失败返回用户可读的错误信息。
   * 头像昵称授权失败不阻断登录（仅没有头像昵称）。
   */
  static async login(context: common.Context): Promise<string> {
    try {
      const provider = new authentication.HuaweiIDProvider();
      const controller = new authentication.AuthenticationController(context);
      HuaweiAccountService.loginRequest = provider.createLoginWithHuaweiIDRequest();
      // 无论设备是否已登录华为账号，都尽量拉起账号确认页。
      HuaweiAccountService.loginRequest.forceLogin = true;
      const loginResponse = await controller.executeRequest(HuaweiAccountService.loginRequest);
      let openId = '';
      let unionId = '';
      let diagnostic = '';
      const loginKind = HuaweiAccountService.responseKind(loginResponse);
      if (loginResponse instanceof authentication.LoginWithHuaweiIDResponse &&
        loginResponse.data !== undefined) {
        openId = loginResponse.data.openID;
        unionId = loginResponse.data.unionID;
      } else {
        // 兜底：响应可能是裸数据对象（框架日志 ResponseConstructor 失败时）。
        const rawText = HuaweiAccountService.rawCredentialText(loginResponse);
        try {
          const raw = JSON.parse(rawText) as RawLoginResponse;
          if (raw.data !== undefined && typeof raw.data.openID === 'string' &&
            raw.data.openID.length > 0) {
            openId = raw.data.openID;
            if (typeof raw.data.unionID === 'string') unionId = raw.data.unionID;
          } else {
            diagnostic = 'login=' + loginKind + ' raw=' + rawText.substring(0, 120);
          }
        } catch (_parseError) {
          diagnostic = 'login=' + loginKind + ' raw=' + rawText.substring(0, 120);
        }
      }
      HuaweiAccountService.nickName = '';
      HuaweiAccountService.avatarUri = '';
      // profile + openid 授权：取头像昵称；openID 也可由此兜底。
      let authKind = 'skipped';
      try {
        HuaweiAccountService.authRequest = provider.createAuthorizationWithHuaweiIDRequest();
        HuaweiAccountService.authRequest.scopes = ['profile', 'openid'];
        const authResponse = await controller.executeRequest(HuaweiAccountService.authRequest);
        authKind = HuaweiAccountService.responseKind(authResponse);
        let authNick: string = '';
        let authAvatar: string = '';
        if (authResponse instanceof authentication.AuthorizationWithHuaweiIDResponse &&
          authResponse.data !== undefined) {
          if (openId.length === 0 && authResponse.data.openID !== undefined) {
            openId = authResponse.data.openID;
          }
          if (unionId.length === 0 && authResponse.data.unionID !== undefined) {
            unionId = authResponse.data.unionID;
          }
          if (authResponse.data.nickName !== undefined) authNick = authResponse.data.nickName;
          if (authResponse.data.avatarUri !== undefined) authAvatar = authResponse.data.avatarUri;
        } else {
          const rawAuthText = HuaweiAccountService.rawCredentialText(authResponse);
          try {
            const rawAuth = JSON.parse(rawAuthText) as RawAuthResponse;
            if (rawAuth.data !== undefined) {
              if (openId.length === 0 && typeof rawAuth.data.openID === 'string') {
                openId = rawAuth.data.openID;
              }
              if (unionId.length === 0 && typeof rawAuth.data.unionID === 'string') {
                unionId = rawAuth.data.unionID;
              }
              if (typeof rawAuth.data.nickName === 'string') authNick = rawAuth.data.nickName;
              if (typeof rawAuth.data.avatarUri === 'string') authAvatar = rawAuth.data.avatarUri;
            }
          } catch (_parseError) { }
        }
        HuaweiAccountService.nickName = authNick;
        HuaweiAccountService.avatarUri = authAvatar;
      } catch (_profileError) {
        // 用户拒绝 profile 授权：保留 openID，头像昵称留空。
        authKind = 'error';
      }
      if (openId.length === 0) {
        // 括号内为诊断信息，用于定位问题。
        return '登录未完成，请重试（' + (diagnostic.length > 0 ? diagnostic :
          'login=' + loginKind + ' auth=' + authKind) + '）';
      }
      HuaweiAccountService.openId = openId;
      HuaweiAccountService.unionId = unionId;
      await HuaweiAccountService.persist(context);
      return '';
    } catch (error) {
      const err = error as BusinessError;
      return '登录失败（' + err.code.toString() + '）：' +
        (err.message !== undefined && err.message.length > 0 ? err.message : '请重试');
    } finally {
      HuaweiAccountService.loginRequest = null;
      HuaweiAccountService.authRequest = null;
    }
  }
}
